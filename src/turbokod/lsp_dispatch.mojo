"""High-level LSP wiring: state machine, didOpen/didChange tracking,
definition requests + responses, diagnostics.

``LspManager`` owns one LSP server (right now: ``mojo-lsp-server`` for
``.mojo`` files). It:

* spawns the server on demand and drives the ``initialize`` →
  ``initialized`` handshake asynchronously (no blocking the UI loop);
* tracks which documents have been ``didOpen``'d, with a per-doc version
  counter, and bumps a ``didChange`` (full-document sync) just before
  every ``textDocument/definition`` so the server sees the buffer's
  current state;
* parses ``textDocument/publishDiagnostics`` notifications and parks
  them keyed by URI so the host can drain per-buffer in ``lsp_tick``;
* lets the host poll a single ``tick`` per frame, returning one
  ``DefinitionResolved`` when the matching response arrives.

Limitations on purpose: no semantic tokens yet, no cancellation, no
concurrent definition requests (a fresh request shadows the previous
one's id). Add when needed.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call

from .json import (
    JsonValue, encode_json, json_array, json_int, json_object, json_str,
    parse_json,
)
from .file_io import basename, read_file, stat_file, write_file
from .lsp import (
    LSP_NOTIFICATION, LSP_RESPONSE, LspClient, LspIncoming, LspProcess,
    json_null_v, lsp_initialize_params,
)
from .posix import getcwd_path, getenv_value, monotonic_ms, realpath, which


fn _lsp_debug_log(line: String):
    """Append ``line`` (plus a trailing newline) to ``/tmp/turbokod-lsp.log``
    when that file already exists, or when ``TURBOKOD_LSP_LOG`` is set.
    No-op otherwise — ``touch /tmp/turbokod-lsp.log`` to enable, delete
    the file to disable.

    Read-modify-write — same trade-off as ``spell._append_to_file``. Opt-in
    debug aid only; not on the hot path unless the trigger is flipped.
    """
    var path = String("/tmp/turbokod-lsp.log")
    var info = stat_file(path)
    if not info.ok \
            and len(getenv_value(String("TURBOKOD_LSP_LOG")).as_bytes()) == 0:
        return
    var existing = String("")
    if info.ok:
        try:
            existing = read_file(path)
        except:
            existing = String("")
    if len(existing.as_bytes()) > 0:
        var eb = existing.as_bytes()
        if eb[len(eb) - 1] != 0x0A:
            existing = existing + String("\n")
    # Prefix each line with monotonic ms so the gap between
    # ``→ request_completion`` and ``← completion response`` is
    # readable by eye. The clock's absolute value is unspecified — only
    # differences are meaningful — but that's exactly what we want for
    # latency analysis.
    var stamp = String("[") + String(monotonic_ms()) + String("] ")
    _ = write_file(path, existing + stamp + line + String("\n"))


# --- State -----------------------------------------------------------------

comptime _STATE_NOT_STARTED  = UInt8(0)
comptime _STATE_INITIALIZING = UInt8(1)
comptime _STATE_READY        = UInt8(2)
comptime _STATE_FAILED       = UInt8(3)


@fieldwise_init
struct DefinitionResolved(ImplicitlyCopyable, Movable):
    """A definition response that resolved to a concrete file location."""
    var path: String
    var line: Int        # 0-based, like ``Editor.cursor_row``
    var character: Int   # 0-based byte offset on that line


@fieldwise_init
struct SymbolItem(ImplicitlyCopyable, Movable):
    """One entry in a ``textDocument/documentSymbol`` response.

    ``kind`` is the raw LSP ``SymbolKind`` integer (1=File, 5=Class,
    6=Method, 12=Function, 13=Variable, 14=Constant, 23=Struct, …);
    consumers can map it to a short label or icon. ``container`` is
    populated when the server returns hierarchical ``DocumentSymbol``
    results — parent names joined with ``" > "`` so the user can tell
    nested methods apart.
    """
    var name: String
    var kind: Int
    var container: String
    var line: Int
    var character: Int


@fieldwise_init
struct CompletionItem(ImplicitlyCopyable, Movable):
    """One entry in a ``textDocument/completion`` response.

    ``label`` is what we display in the popup; ``insert_text`` is what
    actually gets typed into the buffer when the user accepts (often
    equal to ``label`` but for snippet servers may differ, and we still
    fall back to ``label`` when only that is provided). ``kind`` is
    the raw LSP ``CompletionItemKind`` integer (1=Text, 2=Method,
    3=Function, 5=Field, 6=Variable, 7=Class, 14=Keyword, 21=Constant,
    22=Struct, 25=TypeParameter, …); consumers map it to a short icon.
    ``detail`` is the server-supplied type / signature hint shown on
    the highlighted row when the popup is wide enough. ``sort_text``
    is the LSP ``sortText`` field used to order items in the popup —
    when the server omits it we copy the label so sortText-bearing
    entries can still sort cleanly against label-only ones.

    ``has_range`` flips True when the server supplied a ``textEdit``
    (TextEdit or InsertReplaceEdit) — in that case the editor must
    replace exactly ``[range_start_char, range_end_char)`` on
    ``range_start_line`` rather than walking back through word
    codepoints. This matters when ``newText`` covers a span that
    crosses non-word punctuation (e.g. template path completions
    where ``reviews/re`` should be replaced wholesale with
    ``reviews/reviews__tags.html``, not just the trailing ``re``).
    """
    var label: String
    var insert_text: String
    var kind: Int
    var detail: String
    var sort_text: String
    var has_range: Bool
    var range_start_line: Int
    var range_start_char: Int
    var range_end_line: Int
    var range_end_char: Int


# LSP DiagnosticSeverity. Spec values; use the ``DIAG_SEVERITY_*`` names
# at call sites instead of bare ints so the priority order is obvious.
comptime DIAG_SEVERITY_ERROR   = Int(1)
comptime DIAG_SEVERITY_WARNING = Int(2)
comptime DIAG_SEVERITY_INFO    = Int(3)
comptime DIAG_SEVERITY_HINT    = Int(4)


@fieldwise_init
struct Diagnostic(ImplicitlyCopyable, Movable):
    """One ``textDocument/publishDiagnostics`` entry, normalized to
    buffer-relative coordinates the editor can paint directly.

    ``start_row`` / ``start_col`` and ``end_row`` / ``end_col`` are
    0-based, like ``Editor.cursor_row``. ``severity`` is the LSP
    integer (1=Error, 2=Warning, 3=Info, 4=Hint) — keep it as the raw
    int so unknown future severities don't get silently dropped.
    ``source`` is the diagnostic-producing tool ("pyright", "rustc",
    "ruff", …) or empty when the server didn't supply one.
    """
    var start_row: Int
    var start_col: Int
    var end_row: Int
    var end_col: Int
    var severity: Int
    var message: String
    var source: String


struct _DiagnosticBucket(Copyable, Movable):
    """Latest published diagnostic set for one URI.

    The server publishes the *complete* current state every time, so we
    overwrite (not append) on each notification. ``consumed`` flips True
    after the host calls ``take_diagnostics_for(path)`` so a buffer's
    diagnostics aren't re-applied every frame — but the latest list
    stays parked so a *new* editor opened against the same file (e.g.
    a reload after an external edit) can pull the cached set without
    waiting for a fresh publish.
    """
    var path: String
    var diags: List[Diagnostic]
    var consumed: Bool

    fn __init__(
        out self, var path: String, var diags: List[Diagnostic],
        consumed: Bool,
    ):
        self.path = path^
        self.diags = diags^
        self.consumed = consumed

    fn __copyinit__(out self, copy: Self):
        self.path = copy.path
        self.diags = copy.diags.copy()
        self.consumed = copy.consumed


struct LspManager(Copyable, Movable):
    """One LSP server's worth of state plus the transport (``LspClient``).

    The client is held by-value; before ``start`` it's a default-constructed
    sentinel with ``pid == -1`` and ``alive == False``, which the framer
    code treats as inert. Replacing ``self.client`` with a freshly spawned
    one on ``start`` is the single transition into ``_STATE_INITIALIZING``.
    """

    var client: LspClient
    var state: UInt8
    var failure_reason: String

    var _init_id: Int
    var _inflight_def_id: Int
    var _inflight_word: String       # surfaced via status_summary() while pending
    var _last_empty: Bool            # latched when a response had no location
    # Word from a definition request whose response *just* arrived empty.
    # One-shot: ``take_empty_word()`` returns it and clears, so the host
    # can chain a fallback (e.g. open the docs entry for that word) on
    # the same frame the empty response lands. Distinct from the latched
    # ``_last_empty`` flag, which persists across frames so the status
    # bar can keep showing "no definition found" until the next request.
    var _empty_word: String
    var _inflight_symbol_id: Int
    var _resolved_symbols: List[SymbolItem]  # parked between tick() and consume_symbols()
    var _has_resolved_symbols: Bool          # distinguishes "no result yet" from "empty list"
    var _symbols_empty: Bool                 # latched when the last response was empty
    # Pending ``textDocument/completion`` request state. ``_completion_path``
    # / ``_completion_row`` / ``_completion_col`` are echoed back via
    # ``pending_completion_*`` accessors so the host can drop a stale
    # response when the cursor has moved (or the user has switched
    # buffers) by the time it lands. ``_completion_manual`` records
    # whether the request was a user-invoked Ctrl+Space (vs. the as-you-
    # type auto-trigger) so the host can decide whether an empty
    # response should surface a ``<no completion found>`` message.
    var _inflight_completion_id: Int
    var _completion_path: String
    var _completion_row: Int
    var _completion_col: Int
    var _completion_manual: Bool
    var _resolved_completions: List[CompletionItem]
    var _has_resolved_completions: Bool
    var _root_uri: String
    var _language_id: String
    var _argv: List[String]      # captured argv from start_with for the info dialog
    # Rolling capture of the server's stderr. Drained every tick (and one
    # last time after the child reaps) so the info window can show *why*
    # a server died — many language servers print a Python traceback /
    # ``error: unrecognized option`` line to stderr before exiting, and
    # without surfacing that the user sees only an indefinite "starting…"
    # state. Capped at 16 KB to bound memory; once full, new bytes are
    # dropped (the head usually has the most useful diagnostic line).
    var _stderr_log: String

    # Per-document tracking for didOpen / didChange.
    var _doc_paths: List[String]      # absolute paths
    var _doc_versions: List[Int]

    # Queued ``(path, text)`` pairs waiting for ``initialized`` to land.
    var _pending_open_paths: List[String]
    var _pending_open_texts: List[String]

    # Latest published diagnostics keyed by URI-resolved path. The list
    # holds at most one bucket per path — a fresh publishDiagnostics
    # overwrites the prior bucket's list and resets ``consumed``.
    var _diagnostic_buckets: List[_DiagnosticBucket]

    fn __init__(out self):
        self.client = LspClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self._init_id = 0
        self._inflight_def_id = 0
        self._inflight_word = String("")
        self._last_empty = False
        self._empty_word = String("")
        self._inflight_symbol_id = 0
        self._resolved_symbols = List[SymbolItem]()
        self._has_resolved_symbols = False
        self._symbols_empty = False
        self._inflight_completion_id = 0
        self._completion_path = String("")
        self._completion_row = 0
        self._completion_col = 0
        self._completion_manual = False
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
        self._root_uri = String("")
        self._language_id = String("")
        self._argv = List[String]()
        self._doc_paths = List[String]()
        self._doc_versions = List[Int]()
        self._pending_open_paths = List[String]()
        self._pending_open_texts = List[String]()
        self._diagnostic_buckets = List[_DiagnosticBucket]()
        self._stderr_log = String("")

    fn __copyinit__(out self, copy: Self):
        # Honest copying would duplicate child PID + pipe FD ownership,
        # which leaks. We only declare ``Copyable`` so we can stash
        # managers in ``List[LspManager]``; the list is grown via ``^``
        # transfer and indexed through references in the methods that
        # mutate, so this branch never runs for a live manager. If it
        # ever does fire, it produces a fresh NOT_STARTED sibling — bad
        # but recoverable, rather than corrupting the original's state.
        self.client = LspClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self._init_id = 0
        self._inflight_def_id = 0
        self._inflight_word = String("")
        self._last_empty = False
        self._empty_word = String("")
        self._inflight_symbol_id = 0
        self._resolved_symbols = List[SymbolItem]()
        self._has_resolved_symbols = False
        self._symbols_empty = False
        self._inflight_completion_id = 0
        self._completion_path = String("")
        self._completion_row = 0
        self._completion_col = 0
        self._completion_manual = False
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
        self._root_uri = String("")
        self._language_id = String("")
        self._argv = List[String]()
        self._doc_paths = List[String]()
        self._doc_versions = List[Int]()
        self._pending_open_paths = List[String]()
        self._pending_open_texts = List[String]()
        self._diagnostic_buckets = List[_DiagnosticBucket]()
        self._stderr_log = String("")

    fn is_active(self) -> Bool:
        return self.state == _STATE_READY \
            or self.state == _STATE_INITIALIZING

    fn is_ready(self) -> Bool:
        return self.state == _STATE_READY

    fn is_failed(self) -> Bool:
        return self.state == _STATE_FAILED

    fn is_initializing(self) -> Bool:
        return self.state == _STATE_INITIALIZING

    fn is_not_started(self) -> Bool:
        return self.state == _STATE_NOT_STARTED

    fn inflight_word(self) -> String:
        return self._inflight_word

    fn last_empty(self) -> Bool:
        return self._last_empty

    fn take_empty_word(mut self) -> String:
        """One-shot consume of the just-resolved-empty word, or empty
        string when no fresh empty response is parked. Subsequent calls
        return empty until the next empty response lands. ``_last_empty``
        is *not* reset here — that flag persists across frames so the
        status bar can keep showing "no definition found" until the
        user retries; the host clears it via ``clear_empty()`` once it
        has handled the empty response another way (e.g. opened docs).
        """
        var word = self._empty_word^
        self._empty_word = String("")
        return word^

    fn clear_empty(mut self):
        """Drop the latched ``_last_empty`` flag. Host calls this after
        successfully handling an empty response some other way so the
        status bar stops claiming "no definition found"."""
        self._last_empty = False

    fn inflight_symbols(self) -> Bool:
        return self._inflight_symbol_id != 0

    fn symbols_empty(self) -> Bool:
        return self._symbols_empty

    fn language_id(self) -> String:
        return self._language_id

    fn argv(self) -> List[String]:
        return self._argv.copy()

    fn root_uri(self) -> String:
        return self._root_uri

    fn captured_stderr(self) -> String:
        """Everything we've drained from the server's stderr since spawn,
        capped at 16 KB. Surfaced in the info window so the user can see
        what the server printed before exiting / hanging."""
        return self._stderr_log

    # --- diagnostics -------------------------------------------------------

    fn has_unconsumed_diagnostics_for(self, path: String) -> Bool:
        """True iff a fresh publishDiagnostics for ``path`` has landed
        since the last ``take_diagnostics_for`` call. Lets the host
        avoid re-running the apply path every frame for buffers whose
        diagnostic set is unchanged."""
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path \
                    and not self._diagnostic_buckets[k].consumed:
                return True
        return False

    fn take_diagnostics_for(mut self, path: String) -> List[Diagnostic]:
        """Return the latest published diagnostic list for ``path`` and
        mark the bucket consumed so the host doesn't re-apply on every
        frame. Returns an empty list when nothing has been published
        for ``path`` (or it was already consumed). The bucket itself
        stays around so a re-opened buffer can pull it via
        ``peek_diagnostics_for`` without waiting for a fresh publish."""
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                if self._diagnostic_buckets[k].consumed:
                    return List[Diagnostic]()
                var out = self._diagnostic_buckets[k].diags.copy()
                self._diagnostic_buckets[k].consumed = True
                return out^
        return List[Diagnostic]()

    fn peek_diagnostics_for(self, path: String) -> List[Diagnostic]:
        """Return the latest published diagnostic list for ``path``
        without flipping the consumed flag. Used when a fresh editor
        opens against an already-published path so it picks up the
        cached set without round-tripping the server."""
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                return self._diagnostic_buckets[k].diags.copy()
        return List[Diagnostic]()

    # --- lifecycle ---------------------------------------------------------

    fn start_with(
        mut self, language_id: String, argv: List[String], root_path: String,
    ):
        """Generic spawn: ``argv`` is the server command, ``language_id``
        is what we tag every ``didOpen``'d document with.

        Idempotent on a second call after a successful start. On failure
        latches to FAILED so we don't keep retrying every frame. Callers
        that want a multi-binary fallback (e.g. ``start_python``) should
        check ``which()`` themselves before calling and only invoke this
        once they've picked an actually-installed binary.
        """
        if self.state != _STATE_NOT_STARTED:
            return
        self._language_id = language_id
        self._argv = argv.copy()
        # Always give the server a workspace root: a project dir if the
        # host has one open, otherwise the editor's own cwd. Pyright and
        # friends key module resolution off ``rootUri``/``workspaceFolders``
        # and the child's cwd; leaving any of them blank causes silent
        # "module not found" failures on first didOpen.
        var resolved_root = root_path \
            if len(root_path.as_bytes()) > 0 else getcwd_path()
        self._root_uri = _path_to_uri(resolved_root) \
            if len(resolved_root.as_bytes()) > 0 else String("")
        try:
            self.client = LspClient.spawn(argv, resolved_root)
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("spawn failed: ") + String(e)
            return
        # Enable wire trace if /tmp/turbokod-lsp.log already exists (debug aid).
        var trace_path_str = String("/tmp/turbokod-lsp-wire-") \
            + language_id + String(".log")
        var trace_info = stat_file(String("/tmp/turbokod-lsp.log"))
        if trace_info.ok:
            var trace_path = trace_path_str + String("\0")
            var tfd = external_call["creat", Int32](
                trace_path.unsafe_ptr(), Int32(0o644),
            )
            if Int(tfd) >= 0:
                self.client.process.trace_fd = tfd
                var hdr = String("session start argv:")
                for k in range(len(argv)):
                    hdr = hdr + String(" ") + argv[k]
                self.client.process.trace(hdr)
        try:
            var ws_name = basename(resolved_root) \
                if len(resolved_root.as_bytes()) > 0 else String("")
            self._init_id = self.client.send_request(
                String("initialize"),
                lsp_initialize_params(self._root_uri, ws_name),
            )
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("initialize failed: ") + String(e)
            return
        self.state = _STATE_INITIALIZING

    fn start_mojo(mut self, root_path: String, include_dirs: List[String]):
        """Spawn ``mojo-lsp-server``. ``include_dirs`` map to ``-I <dir>``
        CLI flags — without these the server can't resolve project
        imports and every Cmd+click comes back empty."""
        var argv = List[String]()
        argv.append(String("mojo-lsp-server"))
        for i in range(len(include_dirs)):
            argv.append(String("-I"))
            argv.append(include_dirs[i])
        self.start_with(String("mojo"), argv, root_path)

    fn start_python(mut self, root_path: String) -> Bool:
        """Try the available Python LSP servers in priority order.

        Returns True if a candidate was found and a spawn was attempted
        (success vs. FAILED is then exposed via ``is_ready``/``is_failed``
        like any other server). Returns False when no candidate is on
        ``$PATH`` so callers can keep the manager NOT_STARTED and skip
        the LSP-related status messages — there's no point spamming
        "still starting up" if the user never installed a server.

        Order: ``ty server`` → ``pyright-langserver --stdio`` →
        ``basedpyright-langserver --stdio`` → ``pylsp``. ty (from Astral)
        is much faster than pyright at the cost of being less
        full-featured, so we prefer it; pyright/basedpyright/pylsp are
        the fallbacks for users who haven't installed ty yet.
        """
        if self.state != _STATE_NOT_STARTED:
            return True
        # ``ty server`` is Astral's fast type-checker LSP — preferred
        # default. Falls through to pyright et al. if ty isn't on PATH.
        if len(which(String("ty")).as_bytes()) > 0:
            var argv = List[String]()
            argv.append(String("ty"))
            argv.append(String("server"))
            self.start_with(String("python"), argv, root_path)
            return True
        if len(which(String("pyright-langserver")).as_bytes()) > 0:
            var argv = List[String]()
            argv.append(String("pyright-langserver"))
            argv.append(String("--stdio"))
            self.start_with(String("python"), argv, root_path)
            return True
        if len(which(String("basedpyright-langserver")).as_bytes()) > 0:
            var argv = List[String]()
            argv.append(String("basedpyright-langserver"))
            argv.append(String("--stdio"))
            self.start_with(String("python"), argv, root_path)
            return True
        if len(which(String("pylsp")).as_bytes()) > 0:
            var argv = List[String]()
            argv.append(String("pylsp"))
            self.start_with(String("python"), argv, root_path)
            return True
        return False

    fn shutdown(mut self):
        """Best-effort: terminate the child if alive. Idempotent."""
        if self.state == _STATE_NOT_STARTED:
            return
        self.client.terminate()
        self.state = _STATE_NOT_STARTED

    # --- document lifecycle -----------------------------------------------

    fn notify_opened(mut self, path: String, var text: String):
        """Tell the server about a newly opened editor for ``path``.

        Queues until the server is READY. A second open of the same path
        bumps the version and resends as didChange (unusual but harmless —
        keeps the server's view consistent if a window is closed and the
        same file reopened).
        """
        if self.state == _STATE_FAILED or self.state == _STATE_NOT_STARTED:
            return
        if self.state == _STATE_INITIALIZING:
            self._pending_open_paths.append(path)
            self._pending_open_texts.append(text^)
            return
        self._send_open_or_change(path, text^)

    fn notify_changed(mut self, path: String, var text: String):
        """Send a didChange for ``path`` carrying the latest buffer
        text. No-op when the server isn't READY — for INITIALIZING the
        pending didOpen will eventually deliver some snapshot, and the
        next post-READY tick will resend the *current* text via this
        path, so the server's view converges to the live buffer
        regardless of timing."""
        if self.state != _STATE_READY:
            return
        self._send_open_or_change(path, text^)

    fn request_definition(
        mut self, path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        """Ask the server for the definition at ``(line, character)``.

        Pre-flights with a didOpen (or didChange, if already open) so the
        server's view of the file matches what's on screen at click time.
        Returns False when the server isn't ready yet — caller may want to
        log it; we don't queue (a stale click is rarely useful by the time
        the server warms up).

        ``word`` is informational only — surfaced via ``inflight_word()``
        so the host can show "looking up X..." in a status bar.
        """
        if self.state != _STATE_READY:
            return False
        _lsp_debug_log(
            String("→ request_definition lang=") + self._language_id
            + String(" path=") + path
            + String(" line=") + String(line)
            + String(" character=") + String(character)
            + String(" word=") + word
            + String(" text_len=") + String(len(text.as_bytes())),
        )
        self._send_open_or_change(path, text^)
        var params = json_object()
        var doc = json_object()
        doc.put(String("uri"), json_str(_path_to_uri(path)))
        params.put(String("textDocument"), doc)
        var pos = json_object()
        pos.put(String("line"), json_int(line))
        pos.put(String("character"), json_int(character))
        params.put(String("position"), pos)
        try:
            self._inflight_def_id = self.client.send_request(
                String("textDocument/definition"), params,
            )
        except:
            self._inflight_def_id = 0
            return False
        self._inflight_word = word^
        self._last_empty = False
        return True

    fn request_document_symbols(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Ask the server for ``textDocument/documentSymbol`` on ``path``.

        Like ``request_definition``, this pre-flights with a didOpen/didChange
        so the server's view matches the buffer. Returns False if the server
        isn't ready (or a send fails); the caller can retry once the LSP is
        in the READY state. A fresh request shadows any earlier in-flight
        symbol id — there's no concurrent symbol lookup model here.
        """
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        var doc = json_object()
        doc.put(String("uri"), json_str(_path_to_uri(path)))
        params.put(String("textDocument"), doc)
        try:
            self._inflight_symbol_id = self.client.send_request(
                String("textDocument/documentSymbol"), params,
            )
        except:
            self._inflight_symbol_id = 0
            return False
        self._has_resolved_symbols = False
        self._resolved_symbols = List[SymbolItem]()
        self._symbols_empty = False
        return True

    fn has_pending_symbols(self) -> Bool:
        """True iff a parsed symbol response is parked, ready for ``take``."""
        return self._has_resolved_symbols

    fn take_symbols(mut self) -> List[SymbolItem]:
        """Move the parked symbol list out of the manager.

        Pair with ``has_pending_symbols()`` — calling this when nothing is
        parked just hands back an empty list. The flag is cleared either
        way so a subsequent call returns empty.
        """
        var out = self._resolved_symbols^
        self._resolved_symbols = List[SymbolItem]()
        self._has_resolved_symbols = False
        return out^

    fn request_completion(
        mut self, path: String, line: Int, character: Int,
        var text: String, manual: Bool = False,
    ) -> Bool:
        """Ask the server for ``textDocument/completion`` at
        ``(line, character)``.

        Like ``request_definition``, pre-flights with didOpen/didChange
        so the server's view matches the buffer at request time. Returns
        False when the server isn't ready (caller can simply skip — a
        completion request that arrives late is not useful). A fresh
        request shadows any earlier in-flight completion id — no
        concurrent completion model.

        The request coordinates are echoed back through
        ``pending_completion_*`` so the host can verify the cursor
        hasn't moved by the time the response arrives. ``manual`` is
        echoed via ``pending_completion_manual()`` so the host can
        decide whether an empty response should surface a user-visible
        ``<no completion found>`` message.
        """
        if self.state != _STATE_READY:
            return False
        _lsp_debug_log(
            String("→ request_completion lang=") + self._language_id
            + String(" path=") + path
            + String(" line=") + String(line)
            + String(" character=") + String(character),
        )
        self._send_open_or_change(path, text^)
        var params = json_object()
        var doc = json_object()
        doc.put(String("uri"), json_str(_path_to_uri(path)))
        params.put(String("textDocument"), doc)
        var pos = json_object()
        pos.put(String("line"), json_int(line))
        pos.put(String("character"), json_int(character))
        params.put(String("position"), pos)
        # ``CompletionContext.triggerKind`` 1 = Invoked (manual / Ctrl+Space).
        # Most servers ignore the field but pyright/pylsp use it to suppress
        # auto-import suggestions when the user explicitly invoked.
        var ctx = json_object()
        ctx.put(String("triggerKind"), json_int(1))
        params.put(String("context"), ctx^)
        # If a previous completion is still in flight, tell the server
        # to stop computing it via ``$/cancelRequest``. Without this
        # the server keeps a worker pinned on a stale prefix and our
        # fresh request queues behind it — felt as laggy "type two
        # chars, wait for the first response to land before the popup
        # updates" behavior. The cancel is a notification (no
        # response), so it costs us nothing on the read side. We
        # already shadow the old id below, so the response (cancelled
        # or not) is dropped on arrival.
        if self._inflight_completion_id != 0:
            var cancel_params = json_object()
            cancel_params.put(
                String("id"), json_int(self._inflight_completion_id),
            )
            try:
                self.client.send_notification(
                    String("$/cancelRequest"), cancel_params,
                )
            except:
                pass
        try:
            self._inflight_completion_id = self.client.send_request(
                String("textDocument/completion"), params,
            )
        except:
            self._inflight_completion_id = 0
            return False
        self._completion_path = path
        self._completion_row = line
        self._completion_col = character
        self._completion_manual = manual
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
        return True

    fn cancel_completion(mut self):
        """Cancel any in-flight completion request.

        Sends ``$/cancelRequest`` so the server can drop work it has
        already started, and zeroes ``_inflight_completion_id`` so a
        late response — if one slips in before the cancel propagates —
        is ignored by the response handler instead of being parked
        for the host. Also clears any parked-but-unconsumed completion
        list (the user dismissed the popup; that list is irrelevant).
        No-op when nothing is in flight."""
        if self._inflight_completion_id == 0 \
                and not self._has_resolved_completions:
            return
        if self._inflight_completion_id != 0:
            _lsp_debug_log(
                String("→ cancel_completion id=")
                + String(self._inflight_completion_id)
                + String(" lang=") + self._language_id,
            )
            var cancel_params = json_object()
            cancel_params.put(
                String("id"), json_int(self._inflight_completion_id),
            )
            try:
                self.client.send_notification(
                    String("$/cancelRequest"), cancel_params,
                )
            except:
                pass
            self._inflight_completion_id = 0
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False

    fn has_pending_completions(self) -> Bool:
        """True iff a parsed completion response is parked for ``take``."""
        return self._has_resolved_completions

    fn pending_completion_path(self) -> String:
        return self._completion_path

    fn pending_completion_row(self) -> Int:
        return self._completion_row

    fn pending_completion_col(self) -> Int:
        return self._completion_col

    fn pending_completion_manual(self) -> Bool:
        """Echo the ``manual`` flag of the most recent completion
        request. True when the user explicitly invoked completion
        (Ctrl+Space), False for the as-you-type auto-trigger."""
        return self._completion_manual

    fn take_completions(mut self) -> List[CompletionItem]:
        """Move the parked completion list out of the manager.

        Pair with ``has_pending_completions()``. The flag is cleared
        either way so a subsequent call returns empty.
        """
        var out = self._resolved_completions^
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
        return out^

    # --- frame-tick driver -------------------------------------------------

    fn tick(mut self) -> Optional[DefinitionResolved]:
        """Drive the state machine one step.

        Drains every framed message currently available, advancing the
        handshake on ``initialize`` responses, surfacing the first
        ``DefinitionResolved`` from the in-flight request id, and
        parking ``textDocument/publishDiagnostics`` payloads on the
        per-URI bucket list. Other notifications (window/logMessage,
        $/progress, …) are silently dropped — this layer doesn't model
        them yet.
        """
        if self.state == _STATE_NOT_STARTED or self.state == _STATE_FAILED:
            return Optional[DefinitionResolved]()
        # Continue draining any outbound bytes that the previous
        # ``write_message`` couldn't push in one shot (server stopped
        # reading stdin mid-frame). Without this a backlog never
        # flushes until the next ``write_message`` call, which may be
        # far enough in the future that the server has already given
        # up.
        self.client.process.pump_writes()
        # If the outbound queue overflowed, the server isn't draining
        # its stdin and we've lost framing alignment — there's no
        # recovery short of restarting. Latch FAILED so the host
        # surfaces the state and stops sending more.
        if self.client.process.write_overflowed():
            self.state = _STATE_FAILED
            self.failure_reason = String(
                "outbound queue overflowed (server not reading stdin)",
            )
            _lsp_debug_log(
                String("✗ lsp ") + self._language_id
                + String(" outbound overflow; ")
                + String("failure_reason=") + self.failure_reason,
            )
            return Optional[DefinitionResolved]()
        # Capture anything the server has written to stderr since the
        # last tick — useful diagnostic context for the info window even
        # while alive, and the *only* clue we have when the server dies
        # mid-handshake (no JSON-RPC response coming, just a Python
        # traceback or "error: unrecognized option" on stderr).
        self._absorb_stderr()
        # Crash-detection: if the child has exited while we still
        # consider the session live, latch FAILED with whatever stderr
        # carried. Without this the manager stays in INITIALIZING
        # forever and the user sees an indefinite "starting…" with no
        # explanation. Mirror of the DAP manager's crash-detect.
        if self.client.process.try_reap():
            # One last drain — between the previous absorb and the
            # reap the child may have flushed its final stderr line.
            self._absorb_stderr()
            self.state = _STATE_FAILED
            var why = String("server exited")
            var first = _first_nonempty_line(self._stderr_log)
            if len(first.as_bytes()) > 0:
                why = why + String(": ") + first
            self.failure_reason = why^
            _lsp_debug_log(
                String("✗ lsp ") + self._language_id
                + String(" exited; failure_reason=") + self.failure_reason,
            )
            return Optional[DefinitionResolved]()
        var resolved = Optional[DefinitionResolved]()
        var i = 0
        while i < 16:
            i += 1
            var maybe: Optional[LspIncoming]
            try:
                maybe = self.client.poll(Int32(0))
            except:
                return resolved
            if not maybe:
                return resolved
            var msg = maybe.value()
            if msg.kind == LSP_NOTIFICATION:
                if msg.method and msg.params:
                    var method = msg.method.value()
                    if method == String("textDocument/publishDiagnostics"):
                        self._on_publish_diagnostics(msg.params.value())
                continue
            if msg.kind != LSP_RESPONSE:
                continue
            if not msg.id:
                continue
            var id = msg.id.value()
            if self.state == _STATE_INITIALIZING and id == self._init_id:
                self._on_initialize_response(msg)
                continue
            if id == self._inflight_def_id:
                var loc = Optional[DefinitionResolved]()
                var result_dump = String("<no result>")
                var error_dump = String("<no error>")
                if msg.result:
                    result_dump = encode_json(msg.result.value())
                    loc = _parse_definition_result(msg.result.value())
                if msg.error:
                    error_dump = encode_json(msg.error.value())
                _lsp_debug_log(
                    String("← definition response id=") + String(id)
                    + String(" word=") + self._inflight_word
                    + String(" result=") + result_dump
                    + String(" error=") + error_dump,
                )
                if loc:
                    resolved = loc
                    self._last_empty = False
                    self._empty_word = String("")
                else:
                    # Server replied (with null / empty array / parseable but
                    # missing fields). Surface this so the user sees the
                    # difference between "still waiting" and "no result".
                    self._last_empty = True
                    # Stash the word so the host can chain a fallback
                    # (e.g. opening the docs entry for that word) on the
                    # same tick. ``_inflight_word`` is about to be
                    # cleared below, so capture it first.
                    self._empty_word = self._inflight_word
                self._inflight_def_id = 0
                self._inflight_word = String("")
                continue
            if id == self._inflight_symbol_id:
                var items = List[SymbolItem]()
                if msg.result:
                    items = _parse_symbols_result(msg.result.value())
                self._resolved_symbols = items^
                self._has_resolved_symbols = True
                self._symbols_empty = (len(self._resolved_symbols) == 0)
                self._inflight_symbol_id = 0
            if id == self._inflight_completion_id:
                var comps = List[CompletionItem]()
                if msg.result:
                    comps = _parse_completion_result(msg.result.value())
                _lsp_debug_log(
                    String("← completion response id=") + String(id)
                    + String(" lang=") + self._language_id
                    + String(" count=") + String(len(comps)),
                )
                self._resolved_completions = comps^
                self._has_resolved_completions = True
                self._inflight_completion_id = 0
        return resolved

    # --- internals ---------------------------------------------------------

    fn _absorb_stderr(mut self):
        """Drain whatever's available on the server's stderr pipe and
        append it to the rolling capture. Bounded at 16 KB so a chatty
        server can't blow up our memory; once at the cap, new bytes are
        dropped (the head usually has the actionable diagnostic)."""
        var chunk = self.client.process.drain_stderr()
        if len(chunk.as_bytes()) == 0:
            return
        comptime CAP: Int = 16 * 1024
        var have = len(self._stderr_log.as_bytes())
        if have >= CAP:
            return
        var room = CAP - have
        var cb = chunk.as_bytes()
        if len(cb) <= room:
            self._stderr_log = self._stderr_log + chunk
        else:
            self._stderr_log = self._stderr_log + String(StringSlice(
                ptr=cb.unsafe_ptr(), length=room,
            ))

    fn _on_publish_diagnostics(mut self, params: JsonValue):
        """Replace (not merge) the bucket for the published URI. The
        spec is clear: ``publishDiagnostics`` is the *current* set, not
        an incremental update — empty array means "all clear."""
        if not params.is_object():
            return
        var uri_opt = params.object_get(String("uri"))
        var diags_opt = params.object_get(String("diagnostics"))
        if not uri_opt or not diags_opt:
            return
        if not uri_opt.value().is_string():
            return
        if not diags_opt.value().is_array():
            return
        var path = _uri_to_path(uri_opt.value().as_str())
        if len(path.as_bytes()) == 0:
            return
        var diags = _parse_diagnostics_array(diags_opt.value())
        _lsp_debug_log(
            String("← publishDiagnostics lang=") + self._language_id
            + String(" path=") + path
            + String(" count=") + String(len(diags)),
        )
        # Replace existing bucket if any; else append.
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                self._diagnostic_buckets[k].diags = diags^
                self._diagnostic_buckets[k].consumed = False
                return
        self._diagnostic_buckets.append(
            _DiagnosticBucket(path, diags^, False),
        )

    fn _on_initialize_response(mut self, msg: LspIncoming):
        # Spec: send the ``initialized`` notification before any other request,
        # then we're free to didOpen / definition / etc.
        try:
            self.client.send_notification(
                String("initialized"), json_object(),
            )
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("initialized failed: ") + String(e)
            return
        self.state = _STATE_READY
        # Drain the queue of opens that arrived before we were ready.
        var paths = self._pending_open_paths^
        var texts = self._pending_open_texts^
        self._pending_open_paths = List[String]()
        self._pending_open_texts = List[String]()
        for k in range(len(paths)):
            self._send_open_or_change(paths[k], texts[k])

    fn _send_open_or_change(mut self, path: String, var text: String):
        var idx = -1
        for k in range(len(self._doc_paths)):
            if self._doc_paths[k] == path:
                idx = k
                break
        if idx < 0:
            self._doc_paths.append(path)
            self._doc_versions.append(1)
            self._send_did_open(path, text^)
        else:
            var version = self._doc_versions[idx] + 1
            self._doc_versions[idx] = version
            self._send_did_change(path, version, text^)

    fn _send_did_open(mut self, path: String, var text: String):
        _lsp_debug_log(
            String("→ didOpen lang=") + self._language_id
            + String(" path=") + path
            + String(" uri=") + _path_to_uri(path)
            + String(" text_len=") + String(len(text.as_bytes())),
        )
        var params = json_object()
        var doc = json_object()
        doc.put(String("uri"), json_str(_path_to_uri(path)))
        doc.put(String("languageId"), json_str(self._language_id))
        doc.put(String("version"), json_int(1))
        doc.put(String("text"), json_str(text^))
        params.put(String("textDocument"), doc)
        try:
            self.client.send_notification(
                String("textDocument/didOpen"), params,
            )
        except:
            pass

    fn _send_did_change(mut self, path: String, version: Int, var text: String):
        _lsp_debug_log(
            String("→ didChange lang=") + self._language_id
            + String(" path=") + path
            + String(" uri=") + _path_to_uri(path)
            + String(" version=") + String(version)
            + String(" text_len=") + String(len(text.as_bytes())),
        )
        var params = json_object()
        var doc = json_object()
        doc.put(String("uri"), json_str(_path_to_uri(path)))
        doc.put(String("version"), json_int(version))
        params.put(String("textDocument"), doc)
        var changes = json_array()
        var change = json_object()
        # Full-document sync: a single change with no ``range``.
        change.put(String("text"), json_str(text^))
        changes.append(change)
        params.put(String("contentChanges"), changes)
        try:
            self.client.send_notification(
                String("textDocument/didChange"), params,
            )
        except:
            pass


# --- response parsing ------------------------------------------------------


fn _parse_definition_result(v: JsonValue) -> Optional[DefinitionResolved]:
    """``textDocument/definition`` can return null, a single Location, or
    an array of Location/LocationLink. Pick the first usable hit."""
    if v.is_null():
        return Optional[DefinitionResolved]()
    if v.is_array():
        if v.array_len() == 0:
            return Optional[DefinitionResolved]()
        return _parse_one_definition(v.array_at(0))
    if v.is_object():
        return _parse_one_definition(v)
    return Optional[DefinitionResolved]()


fn _parse_one_definition(v: JsonValue) -> Optional[DefinitionResolved]:
    if not v.is_object():
        return Optional[DefinitionResolved]()
    # LocationLink: ``targetUri`` + ``targetSelectionRange`` (preferred) or
    # ``targetRange``. Plain Location: ``uri`` + ``range``.
    var uri_opt = v.object_get(String("uri"))
    var range_opt = v.object_get(String("range"))
    if not uri_opt:
        uri_opt = v.object_get(String("targetUri"))
    if not range_opt:
        range_opt = v.object_get(String("targetSelectionRange"))
    if not range_opt:
        range_opt = v.object_get(String("targetRange"))
    if not uri_opt or not range_opt:
        return Optional[DefinitionResolved]()
    if not uri_opt.value().is_string():
        return Optional[DefinitionResolved]()
    var uri = uri_opt.value().as_str()
    var path = _uri_to_path(uri)
    if len(path.as_bytes()) == 0:
        return Optional[DefinitionResolved]()
    var rng = range_opt.value()
    var start_opt = rng.object_get(String("start"))
    if not start_opt:
        return Optional[DefinitionResolved]()
    var start = start_opt.value()
    var line_opt = start.object_get(String("line"))
    var char_opt = start.object_get(String("character"))
    if not line_opt or not char_opt:
        return Optional[DefinitionResolved]()
    if not line_opt.value().is_int() or not char_opt.value().is_int():
        return Optional[DefinitionResolved]()
    return Optional[DefinitionResolved](DefinitionResolved(
        path, line_opt.value().as_int(), char_opt.value().as_int(),
    ))


# --- symbol parsing --------------------------------------------------------


fn _parse_symbols_result(v: JsonValue) -> List[SymbolItem]:
    """``textDocument/documentSymbol`` returns ``DocumentSymbol[]`` (the
    hierarchical form, with ``range`` / ``selectionRange`` / ``children``)
    or the legacy flat ``SymbolInformation[]`` (with ``location`` and
    ``containerName``). Accept either, flatten any hierarchy with parent
    names joined by ``" > "``.
    """
    var out = List[SymbolItem]()
    if not v.is_array():
        return out^
    if v.array_len() == 0:
        return out^
    var first = v.array_at(0)
    if first.is_object() and first.object_has(String("location")):
        # Flat SymbolInformation[].
        for i in range(v.array_len()):
            _parse_symbol_information(v.array_at(i), out)
    else:
        # Hierarchical DocumentSymbol[].
        for i in range(v.array_len()):
            _parse_document_symbol(v.array_at(i), String(""), out)
    return out^


fn _parse_document_symbol(
    v: JsonValue, container: String, mut out: List[SymbolItem],
):
    if not v.is_object():
        return
    var name_opt = v.object_get(String("name"))
    var kind_opt = v.object_get(String("kind"))
    var sel_opt = v.object_get(String("selectionRange"))
    if not sel_opt:
        sel_opt = v.object_get(String("range"))
    if not name_opt or not sel_opt:
        return
    if not name_opt.value().is_string():
        return
    var name = name_opt.value().as_str()
    var kind = 0
    if kind_opt and kind_opt.value().is_int():
        kind = kind_opt.value().as_int()
    var pos = _start_pos_of(sel_opt.value())
    if pos[0] >= 0:
        out.append(SymbolItem(name, kind, container, pos[0], pos[1]))
    var children_opt = v.object_get(String("children"))
    if children_opt and children_opt.value().is_array():
        var sub_container: String
        if len(container.as_bytes()) == 0:
            sub_container = name
        else:
            sub_container = container + String(" > ") + name
        var children = children_opt.value()
        for i in range(children.array_len()):
            _parse_document_symbol(children.array_at(i), sub_container, out)


fn _parse_symbol_information(v: JsonValue, mut out: List[SymbolItem]):
    if not v.is_object():
        return
    var name_opt = v.object_get(String("name"))
    var kind_opt = v.object_get(String("kind"))
    var loc_opt = v.object_get(String("location"))
    var cont_opt = v.object_get(String("containerName"))
    if not name_opt or not loc_opt:
        return
    if not name_opt.value().is_string():
        return
    var name = name_opt.value().as_str()
    var kind = 0
    if kind_opt and kind_opt.value().is_int():
        kind = kind_opt.value().as_int()
    var container = String("")
    if cont_opt and cont_opt.value().is_string():
        container = cont_opt.value().as_str()
    var range_opt = loc_opt.value().object_get(String("range"))
    if not range_opt:
        return
    var pos = _start_pos_of(range_opt.value())
    if pos[0] < 0:
        return
    out.append(SymbolItem(name, kind, container, pos[0], pos[1]))


fn _parse_completion_result(v: JsonValue) -> List[CompletionItem]:
    """``textDocument/completion`` returns either ``CompletionItem[]``
    directly, or a ``CompletionList`` object whose ``items`` field holds
    the array. Accept either, skip malformed entries.

    Snippet items (``insertTextFormat == 2``) are downgraded to plain
    text inserts here — we don't render placeholders, so a snippet
    body with ``${1:arg}`` markers would look like garbage when
    inserted verbatim. ``label`` falls back as the inserted text in
    that case (already what the user sees in the popup).

    Items are reordered by ``sortText`` (falling back to ``label`` when
    the server omits it, per LSP spec) so the popup respects the
    server's preferred order rather than the wire order. Stable insertion
    sort — ties keep the server's original relative order.
    """
    var out = List[CompletionItem]()
    var arr: JsonValue
    if v.is_array():
        arr = v
    elif v.is_object():
        var items_opt = v.object_get(String("items"))
        if not items_opt or not items_opt.value().is_array():
            return out^
        arr = items_opt.value()
    else:
        return out^
    var n = arr.array_len()
    for i in range(n):
        var entry = arr.array_at(i)
        if not entry.is_object():
            continue
        var label_opt = entry.object_get(String("label"))
        if not label_opt or not label_opt.value().is_string():
            continue
        var label = label_opt.value().as_str()
        var kind = 0
        var kind_opt = entry.object_get(String("kind"))
        if kind_opt and kind_opt.value().is_int():
            kind = kind_opt.value().as_int()
        var detail = String("")
        var detail_opt = entry.object_get(String("detail"))
        if detail_opt and detail_opt.value().is_string():
            detail = detail_opt.value().as_str()
        var insert_text = label
        var has_range = False
        var rs_line = 0
        var rs_char = 0
        var re_line = 0
        var re_char = 0
        var fmt = 1
        var fmt_opt = entry.object_get(String("insertTextFormat"))
        if fmt_opt and fmt_opt.value().is_int():
            fmt = fmt_opt.value().as_int()
        if fmt != 2:
            # Per LSP spec, when ``textEdit`` is provided the value of
            # ``insertText`` is ignored — textEdit is authoritative for
            # both the text to insert and the range to replace. Fall
            # back to ``insertText`` only when textEdit is absent, and
            # fall back to the label only when both are absent.
            var got_te = False
            var te_opt = entry.object_get(String("textEdit"))
            if te_opt and te_opt.value().is_object():
                var te = te_opt.value()
                var nt_opt = te.object_get(String("newText"))
                if nt_opt and nt_opt.value().is_string():
                    insert_text = nt_opt.value().as_str()
                    got_te = True
                # ``TextEdit`` carries ``range``; ``InsertReplaceEdit``
                # carries ``insert`` and ``replace`` — prefer ``replace``
                # so accepting overwrites existing text rather than
                # leaving a suffix behind the cursor.
                var rng_obj_opt = te.object_get(String("range"))
                if not rng_obj_opt:
                    rng_obj_opt = te.object_get(String("replace"))
                if rng_obj_opt and rng_obj_opt.value().is_object():
                    var rng_obj = rng_obj_opt.value()
                    var s_opt = rng_obj.object_get(String("start"))
                    var e_opt = rng_obj.object_get(String("end"))
                    if s_opt and e_opt \
                            and s_opt.value().is_object() \
                            and e_opt.value().is_object():
                        var sl_opt = s_opt.value().object_get(String("line"))
                        var sc_opt = s_opt.value().object_get(String("character"))
                        var el_opt = e_opt.value().object_get(String("line"))
                        var ec_opt = e_opt.value().object_get(String("character"))
                        if sl_opt and sc_opt and el_opt and ec_opt \
                                and sl_opt.value().is_int() \
                                and sc_opt.value().is_int() \
                                and el_opt.value().is_int() \
                                and ec_opt.value().is_int():
                            rs_line = sl_opt.value().as_int()
                            rs_char = sc_opt.value().as_int()
                            re_line = el_opt.value().as_int()
                            re_char = ec_opt.value().as_int()
                            has_range = True
            if not got_te:
                var it_opt = entry.object_get(String("insertText"))
                if it_opt and it_opt.value().is_string():
                    insert_text = it_opt.value().as_str()
        var sort_text = label
        var sort_opt = entry.object_get(String("sortText"))
        if sort_opt and sort_opt.value().is_string():
            sort_text = sort_opt.value().as_str()
        out.append(CompletionItem(
            label, insert_text, kind, detail, sort_text,
            has_range, rs_line, rs_char, re_line, re_char,
        ))
    # Stable insertion sort by sort_text — typical completion lists are
    # under ~200 items so quadratic worst-case is fine here.
    var m = len(out)
    for i in range(1, m):
        var j = i
        while j > 0 and out[j].sort_text < out[j - 1].sort_text:
            var tmp = out[j]
            out[j] = out[j - 1]
            out[j - 1] = tmp
            j -= 1
    return out^


fn _parse_diagnostics_array(v: JsonValue) -> List[Diagnostic]:
    """Parse the ``diagnostics`` array of a ``publishDiagnostics``
    notification into normalized buffer-relative entries. Skips
    malformed entries (missing range/severity is not fatal — the
    spec actually allows omitting severity, in which case we default
    to ``DIAG_SEVERITY_INFO`` so the diagnostic still surfaces)."""
    var out = List[Diagnostic]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var entry = v.array_at(i)
        if not entry.is_object():
            continue
        var range_opt = entry.object_get(String("range"))
        if not range_opt:
            continue
        var rng = range_opt.value()
        var start_opt = rng.object_get(String("start"))
        var end_opt = rng.object_get(String("end"))
        if not start_opt or not end_opt:
            continue
        var sl_opt = start_opt.value().object_get(String("line"))
        var sc_opt = start_opt.value().object_get(String("character"))
        var el_opt = end_opt.value().object_get(String("line"))
        var ec_opt = end_opt.value().object_get(String("character"))
        if not sl_opt or not sc_opt or not el_opt or not ec_opt:
            continue
        if not sl_opt.value().is_int() or not sc_opt.value().is_int() \
                or not el_opt.value().is_int() \
                or not ec_opt.value().is_int():
            continue
        var severity = DIAG_SEVERITY_INFO
        var sev_opt = entry.object_get(String("severity"))
        if sev_opt and sev_opt.value().is_int():
            severity = sev_opt.value().as_int()
        var message = String("")
        var msg_opt = entry.object_get(String("message"))
        if msg_opt and msg_opt.value().is_string():
            message = msg_opt.value().as_str()
        var source = String("")
        var src_opt = entry.object_get(String("source"))
        if src_opt and src_opt.value().is_string():
            source = src_opt.value().as_str()
        out.append(Diagnostic(
            sl_opt.value().as_int(), sc_opt.value().as_int(),
            el_opt.value().as_int(), ec_opt.value().as_int(),
            severity, message^, source^,
        ))
    return out^


fn _start_pos_of(rng: JsonValue) -> Tuple[Int, Int]:
    """Extract ``(line, character)`` from a Range's ``start``. Returns
    ``(-1, -1)`` when the shape doesn't match — caller filters those out."""
    if not rng.is_object():
        return (-1, -1)
    var start_opt = rng.object_get(String("start"))
    if not start_opt:
        return (-1, -1)
    var start = start_opt.value()
    var line_opt = start.object_get(String("line"))
    var char_opt = start.object_get(String("character"))
    if not line_opt or not char_opt:
        return (-1, -1)
    if not line_opt.value().is_int() or not char_opt.value().is_int():
        return (-1, -1)
    return (line_opt.value().as_int(), char_opt.value().as_int())


# --- URI <-> path ----------------------------------------------------------


fn _first_nonempty_line(s: String) -> String:
    """Return the first line of ``s`` that has at least one non-whitespace
    byte. Lets the FAILED state row in the LSP info window show a punchy
    one-liner from a multi-line stderr blob (the full thing is rendered
    in a dedicated block below)."""
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            var seg = String(StringSlice(
                ptr=b.unsafe_ptr() + start, length=i - start,
            ))
            var trimmed = _trim_trailing_newline(seg)
            var tb = trimmed.as_bytes()
            var has_text = False
            for k in range(len(tb)):
                if tb[k] != 0x20 and tb[k] != 0x09 \
                        and tb[k] != 0x0D and tb[k] != 0x0A:
                    has_text = True
                    break
            if has_text:
                return trimmed^
            start = i + 1
    if start < len(b):
        return _trim_trailing_newline(String(StringSlice(
            ptr=b.unsafe_ptr() + start, length=len(b) - start,
        )))
    return String("")


fn _trim_trailing_newline(s: String) -> String:
    """Drop trailing ``\\r``/``\\n`` so a one-line failure_reason from a
    stderr blob doesn't end with a dangling newline that confuses the
    info-window join."""
    var b = s.as_bytes()
    var end = len(b)
    while end > 0 and (b[end - 1] == 0x0A or b[end - 1] == 0x0D):
        end -= 1
    if end == len(b):
        return s
    return String(StringSlice(ptr=b.unsafe_ptr(), length=end))


fn _path_to_uri(path: String) -> String:
    """``/abs/path`` → ``file:///abs/path``. Resolves through realpath when
    possible so the server sees the same canonical form across calls."""
    var resolved = realpath(path)
    var p = resolved if len(resolved.as_bytes()) > 0 else path
    var b = p.as_bytes()
    if len(b) > 0 and b[0] == 0x2F:
        return String("file://") + p
    # Relative path: best-effort; the server may still find it via rootUri.
    return String("file://") + p


fn _uri_to_path(uri: String) -> String:
    """Strip the ``file://`` scheme. (We deliberately don't URL-decode
    yet — typical mojo-lsp-server responses send unencoded ASCII paths,
    and adding a decoder is more risk than reward right now.)"""
    var prefix = String("file://")
    var pb = prefix.as_bytes()
    var ub = uri.as_bytes()
    if len(ub) < len(pb):
        return uri
    for i in range(len(pb)):
        if ub[i] != pb[i]:
            return uri
    return String(StringSlice(
        ptr=ub.unsafe_ptr() + len(pb), length=len(ub) - len(pb),
    ))
