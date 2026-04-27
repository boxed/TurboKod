"""High-level LSP wiring: state machine, didOpen/didChange tracking,
definition requests + responses.

``LspManager`` owns one LSP server (right now: ``mojo-lsp-server`` for
``.mojo`` files). It:

* spawns the server on demand and drives the ``initialize`` →
  ``initialized`` handshake asynchronously (no blocking the UI loop);
* tracks which documents have been ``didOpen``'d, with a per-doc version
  counter, and bumps a ``didChange`` (full-document sync) just before
  every ``textDocument/definition`` so the server sees the buffer's
  current state;
* lets the host poll a single ``tick`` per frame, returning one
  ``DefinitionResolved`` when the matching response arrives.

Limitations on purpose: no semantic tokens yet, no diagnostics yet, no
cancellation, no concurrent definition requests (a fresh request shadows
the previous one's id). Add when needed.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .json import (
    JsonValue, encode_json, json_array, json_int, json_object, json_str,
    parse_json,
)
from .lsp import (
    LSP_RESPONSE, LspClient, LspIncoming, LspProcess,
    json_null_v, lsp_initialize_params,
)
from .posix import realpath, which


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


struct LspManager(Movable):
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
    var _inflight_symbol_id: Int
    var _resolved_symbols: List[SymbolItem]  # parked between tick() and consume_symbols()
    var _has_resolved_symbols: Bool          # distinguishes "no result yet" from "empty list"
    var _symbols_empty: Bool                 # latched when the last response was empty
    var _root_uri: String
    var _language_id: String

    # Per-document tracking for didOpen / didChange.
    var _doc_paths: List[String]      # absolute paths
    var _doc_versions: List[Int]

    # Queued ``(path, text)`` pairs waiting for ``initialized`` to land.
    var _pending_open_paths: List[String]
    var _pending_open_texts: List[String]

    fn __init__(out self):
        self.client = LspClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self._init_id = 0
        self._inflight_def_id = 0
        self._inflight_word = String("")
        self._last_empty = False
        self._inflight_symbol_id = 0
        self._resolved_symbols = List[SymbolItem]()
        self._has_resolved_symbols = False
        self._symbols_empty = False
        self._root_uri = String("")
        self._language_id = String("")
        self._doc_paths = List[String]()
        self._doc_versions = List[Int]()
        self._pending_open_paths = List[String]()
        self._pending_open_texts = List[String]()

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

    fn inflight_symbols(self) -> Bool:
        return self._inflight_symbol_id != 0

    fn symbols_empty(self) -> Bool:
        return self._symbols_empty

    fn language_id(self) -> String:
        return self._language_id

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
        self._root_uri = _path_to_uri(root_path) if len(root_path.as_bytes()) > 0 else String("")
        try:
            self.client = LspClient.spawn(argv)
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("spawn failed: ") + String(e)
            return
        try:
            self._init_id = self.client.send_request(
                String("initialize"), lsp_initialize_params(self._root_uri),
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

        Order: ``pyright-langserver --stdio`` → ``basedpyright-langserver
        --stdio`` → ``pylsp``. Pyright is the de-facto modern default;
        basedpyright is the community fork; pylsp covers older setups.
        """
        if self.state != _STATE_NOT_STARTED:
            return True
        # ``pyright-langserver --stdio`` is what the official VS Code /
        # Neovim integrations use; mirror that wire-up.
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

    # --- frame-tick driver -------------------------------------------------

    fn tick(mut self) -> Optional[DefinitionResolved]:
        """Drive the state machine one step.

        Drains every framed message currently available, advancing the
        handshake on ``initialize`` responses and surfacing the first
        ``DefinitionResolved`` from the in-flight request id. Other
        messages (publishDiagnostics notifications, log messages, etc.)
        are silently dropped — this layer doesn't model them yet.
        """
        if self.state == _STATE_NOT_STARTED or self.state == _STATE_FAILED:
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
                if msg.result:
                    loc = _parse_definition_result(msg.result.value())
                if loc:
                    resolved = loc
                    self._last_empty = False
                else:
                    # Server replied (with null / empty array / parseable but
                    # missing fields). Surface this so the user sees the
                    # difference between "still waiting" and "no result".
                    self._last_empty = True
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
        return resolved

    # --- internals ---------------------------------------------------------

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
