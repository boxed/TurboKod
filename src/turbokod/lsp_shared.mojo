"""One language server process shared by every window that wants it.

The native app builds one ``Desktop`` per project window, and each used to
spawn its own servers: three Python projects open meant three copies of the
server, each holding its own interpreter, stdlib stubs and caches. A server
that speaks LSP multi-root (``workspace.workspaceFolders.changeNotifications``)
can serve them all from one process, with each project a workspace folder.

The split:

* ``LspChannel`` owns the process and the wire. It hands out request ids,
  remembers which session issued each, and sorts everything the server
  sends into a per-session inbox: responses by id, diagnostics by which
  session has the file open (then by workspace root), capability
  registrations and ``*/refresh`` to every session (answered once),
  ``workspace/workspaceFolders`` answered here from all the roots.
* ``LspManager`` (``lsp_dispatch.mojo``) stays one per window and keeps all
  of its per-window state — documents, in-flight request slots, diagnostics
  buckets. It is a *session* on a channel: it sends through it and reads its
  own inbox, so nothing it does can consume another window's reply.
* ``LspPool`` maps a server's identity (language + argv) to its live
  channel. The host makes one and gives it to every window's ``Desktop``
  (``Desktop.lsp_pool``); without one — the terminal frontends, tests —
  every manager keeps a private transport, exactly as before.

The second window to want a server joins instead of spawning: once the
channel has the ``initialize`` result it adds the window's root with
``workspace/didChangeWorkspaceFolders`` and the session reuses that result.
A server that can't change folders makes the joiner fall back to its own
process. The last session out runs the normal ``shutdown`` / ``exit``
handshake; the others just remove their folder and close their documents.

Like ``Desktop``, channels and the pool live in ``malloc``-ed storage
addressed by an ``Int`` (Mojo has no module-level mutable globals, and every
``Desktop`` must reach the same instance). Everything runs on the host's one
UI thread, so there is no locking.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.sys import size_of

from .file_io import basename
from .json import JsonValue, json_array, json_object, json_str
from .lsp import (
    LSP_NOTIFICATION, LSP_REQUEST, LSP_RESPONSE, LspClient, LspIncoming,
)


# Bound on the messages one pump moves; the manager's own tick loop has
# the same guard against a runaway server.
comptime _PUMP_MAX = 256
# Cap on an inbox nobody is draining (an occluded window doesn't tick):
# beyond it the oldest messages go. Diagnostics are republished on the
# next edit, and a reply that old has long been given up on.
comptime _INBOX_MAX = 4096
comptime _STDERR_CAP = 16 * 1024


def _json_id_string(v: JsonValue) -> String:
    if v.is_string():
        return v.as_str()
    if v.is_int():
        return String(v.as_int())
    return String("")


def _str_at(v: JsonValue, key: String) -> String:
    if not v.is_object():
        return String("")
    var x = v.object_get(key)
    if x and x.value().is_string():
        return x.value().as_str()
    return String("")


def _uri_under(uri: String, root: String) -> Bool:
    """True when ``uri`` is ``root`` or inside it (a path-segment prefix,
    so ``file:///a/b`` doesn't claim ``file:///a/bc/x.py``)."""
    if len(root.as_bytes()) == 0:
        return False
    if uri == root:
        return True
    return uri.startswith(root + String("/"))


def _first_uri_of(method: String, params: JsonValue) -> String:
    """The document a server message is about, for routing it to the
    window that owns that document. ``""`` when it names none."""
    if method == String("textDocument/publishDiagnostics") \
            or method == String("window/showDocument"):
        return _str_at(params, String("uri"))
    if method == String("workspace/configuration"):
        var items = params.object_get(String("items")) \
            if params.is_object() else Optional[JsonValue]()
        if items and items.value().is_array() and items.value().array_len() > 0:
            return _str_at(items.value().array_at(0), String("scopeUri"))
        return String("")
    if method == String("workspace/applyEdit"):
        var edit = params.object_get(String("edit")) \
            if params.is_object() else Optional[JsonValue]()
        if not edit or not edit.value().is_object():
            return String("")
        var changes = edit.value().object_get(String("changes"))
        if changes and changes.value().is_object() \
                and changes.value().object_len() > 0:
            return changes.value().object_key_at(0)
        var dcs = edit.value().object_get(String("documentChanges"))
        if dcs and dcs.value().is_array() and dcs.value().array_len() > 0:
            var td = dcs.value().array_at(0).object_get(String("textDocument"))
            if td:
                return _str_at(td.value(), String("uri"))
    return String("")


def _mentions_path(text: String, path: String) -> Bool:
    """True when ``path`` occurs in ``text`` as a whole path: not followed
    by more of a file name, so ``/p/app`` isn't found in ``/p/app2``."""
    var tb = text.as_bytes()
    var plen = len(path.as_bytes())
    if plen == 0:
        return False
    var start = 0
    while True:
        var at = text.find(path, start)
        if at < 0:
            return False
        var end = at + plen
        if end >= len(tb):
            return True
        var c = tb[end]
        var name_char = (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) \
            or (c >= 0x61 and c <= 0x7A) or c == 0x5F or c == 0x2D or c == 0x2E
        # A trailing ``.`` ends a sentence unless more name follows it.
        if c == 0x2E and (end + 1 >= len(tb) or tb[end + 1] == 0x20):
            name_char = False
        if not name_char:
            return True
        start = at + 1


def _broadcast(method: String) -> Bool:
    """Notifications every session should see: logs and progress."""
    return method == String("$/progress") \
        or method == String("window/logMessage") \
        or method == String("$/logTrace") \
        or method == String("telemetry/event")


def _replayed_request(method: String) -> Bool:
    """Server requests that change state *every* session holds — the
    capability set, staleness of document features. Each session applies
    them; only one answers."""
    return method == String("client/registerCapability") \
        or method == String("client/unregisterCapability") \
        or method.startswith(String("workspace/")) \
        and method.endswith(String("/refresh"))


struct LspChannel(Movable):
    """A server process plus the routing that lets several sessions share
    it. See the module docstring."""

    var client: LspClient
    var key: String
    # Live sessions, parallel lists. ``_inbox_replay[i][k]`` marks a message
    # another session answers (the recipient applies it but must not reply).
    var _session_ids: List[Int]
    var _session_roots: List[String]
    var _inbox: List[List[LspIncoming]]
    var _inbox_replay: List[List[Bool]]
    var _next_session: Int
    # Outstanding requests: id → issuing session.
    var _req_ids: List[String]
    var _req_owner: List[Int]
    # The ``initialize`` exchange, done once per process.
    var _init_id: String
    var init_result: Optional[LspIncoming]
    var _initialized_sent: Bool
    # Every capability (un)registration so far, replayed to later joiners.
    var _registrations: List[LspIncoming]
    # Document URI → open count, so two sessions opening the same file
    # (a file shown in two project windows) don't double-``didOpen`` it.
    var _open_uris: List[String]
    var _open_counts: List[Int]
    var _open_owner: List[Int]
    var stderr_log: String
    # Latched once the child is reaped, so every session notices the
    # death, not just whichever one's tick happened to reap it.
    var dead: Bool
    # The session that last sent the server anything — the window the user
    # is working in. Where a message naming no document goes.
    var _last_active: Int

    def __init__(out self, var client: LspClient, key: String):
        self.client = client^
        self.key = key
        self._session_ids = List[Int]()
        self._session_roots = List[String]()
        self._inbox = List[List[LspIncoming]]()
        self._inbox_replay = List[List[Bool]]()
        self._next_session = 1
        self._req_ids = List[String]()
        self._req_owner = List[Int]()
        self._init_id = String("")
        self.init_result = Optional[LspIncoming]()
        self._initialized_sent = False
        self._registrations = List[LspIncoming]()
        self._open_uris = List[String]()
        self._open_counts = List[Int]()
        self._open_owner = List[Int]()
        self.stderr_log = String("")
        self.dead = False
        self._last_active = 0

    # --- sessions ----------------------------------------------------------

    def join(mut self, root_uri: String) -> Int:
        var sid = self._next_session
        self._next_session += 1
        self._session_ids.append(sid)
        self._session_roots.append(root_uri)
        self._inbox.append(List[LspIncoming]())
        self._inbox_replay.append(List[Bool]())
        return sid

    def leave(mut self, sid: Int) -> Int:
        """Drop session ``sid`` and everything addressed to it. Returns how
        many sessions remain."""
        var i = self._index_of(sid)
        if i >= 0:
            _ = self._session_ids.pop(i)
            _ = self._session_roots.pop(i)
            _ = self._inbox.pop(i)
            _ = self._inbox_replay.pop(i)
        var k = 0
        while k < len(self._req_ids):
            if self._req_owner[k] == sid:
                _ = self._req_ids.pop(k)
                _ = self._req_owner.pop(k)
            else:
                k += 1
        return len(self._session_ids)

    def session_count(self) -> Int:
        return len(self._session_ids)

    def roots(self) -> List[String]:
        return self._session_roots.copy()

    def _index_of(self, sid: Int) -> Int:
        for i in range(len(self._session_ids)):
            if self._session_ids[i] == sid:
                return i
        return -1

    def supports_folder_changes(self) -> Bool:
        """Whether the server said it accepts
        ``workspace/didChangeWorkspaceFolders`` — the condition for a
        second session to join rather than spawn."""
        if not self.init_result:
            return False
        var res = self.init_result.value().result.copy()
        if not res or not res.value().is_object():
            return False
        var caps = res.value().object_get(String("capabilities"))
        if not caps or not caps.value().is_object():
            return False
        var ws = caps.value().object_get(String("workspace"))
        if not ws or not ws.value().is_object():
            return False
        var wf = ws.value().object_get(String("workspaceFolders"))
        if not wf or not wf.value().is_object():
            return False
        var cn = wf.value().object_get(String("changeNotifications"))
        if not cn:
            return False
        # ``boolean | string``: a string is a registration id, i.e. yes.
        if cn.value().is_string():
            return len(cn.value().as_str().as_bytes()) > 0
        return cn.value().is_bool() and cn.value().as_bool()

    def registrations(self) -> List[LspIncoming]:
        return self._registrations.copy()

    def change_folders(mut self, added: String, removed: String) raises:
        """Tell the server a root was added and/or removed (``""`` = none)."""
        var event = json_object()
        var add = json_array()
        if len(added.as_bytes()) > 0:
            add.append(_folder(added))
        var rem = json_array()
        if len(removed.as_bytes()) > 0:
            rem.append(_folder(removed))
        event.put(String("added"), add)
        event.put(String("removed"), rem)
        var params = json_object()
        params.put(String("event"), event)
        self.client.send_notification(
            String("workspace/didChangeWorkspaceFolders"), params,
        )

    # --- outbound ----------------------------------------------------------

    def send_request(
        mut self, sid: Int, method: String, params: JsonValue,
    ) raises -> String:
        var id = self.client.send_request(method, params)
        self._last_active = sid
        if method == String("initialize"):
            self._init_id = id
        self._req_ids.append(id)
        self._req_owner.append(sid)
        return id^

    def send_notification(
        mut self, sid: Int, method: String, params: JsonValue,
    ) raises:
        self._last_active = sid
        if method == String("initialized"):
            # Once per process: a joiner replays the cached initialize
            # result through the same code path, which sends this again.
            if self._initialized_sent:
                return
            self._initialized_sent = True
        elif method == String("textDocument/didOpen"):
            var uri = _str_at(
                params.object_get(String("textDocument")).value(), String("uri"),
            ) if params.is_object() and params.object_has(
                String("textDocument"),
            ) else String("")
            var k = self._open_index(uri)
            if k >= 0:
                self._open_counts[k] += 1
                return
            self._open_uris.append(uri)
            self._open_counts.append(1)
            self._open_owner.append(sid)
        elif method == String("textDocument/didClose"):
            var uri = _str_at(
                params.object_get(String("textDocument")).value(), String("uri"),
            ) if params.is_object() and params.object_has(
                String("textDocument"),
            ) else String("")
            var k = self._open_index(uri)
            if k >= 0:
                self._open_counts[k] -= 1
                if self._open_counts[k] > 0:
                    if self._open_owner[k] == sid:
                        self._open_owner[k] = self._other_session(sid)
                    return
                _ = self._open_uris.pop(k)
                _ = self._open_counts.pop(k)
                _ = self._open_owner.pop(k)
        self.client.send_notification(method, params)

    def _open_index(self, uri: String) -> Int:
        if len(uri.as_bytes()) == 0:
            return -1
        for k in range(len(self._open_uris)):
            if self._open_uris[k] == uri:
                return k
        return -1

    def _other_session(self, sid: Int) -> Int:
        for i in range(len(self._session_ids)):
            if self._session_ids[i] != sid:
                return self._session_ids[i]
        return sid

    # --- inbound -----------------------------------------------------------

    def drain_stderr(mut self):
        var chunk = self.client.process.drain_stderr()
        if len(chunk.as_bytes()) == 0:
            return
        if len(self.stderr_log.as_bytes()) + len(chunk.as_bytes()) <= _STDERR_CAP:
            self.stderr_log = self.stderr_log + chunk

    def check_alive(mut self) -> Bool:
        """False once the child has exited (latched)."""
        if self.dead:
            return False
        if self.client.process.try_reap():
            self.drain_stderr()
            self.dead = True
            return False
        return True

    def pop(mut self, sid: Int) raises -> Tuple[Optional[LspIncoming], Bool]:
        """The next message for session ``sid`` and whether it is a replay
        (apply, don't answer). Reads whatever the server has sent first."""
        self.pump()
        var i = self._index_of(sid)
        if i < 0 or len(self._inbox[i]) == 0:
            return (Optional[LspIncoming](), False)
        var msg = self._inbox[i].pop(0)
        var replay = self._inbox_replay[i].pop(0)
        return (Optional[LspIncoming](msg^), replay)

    def pump(mut self) raises:
        """Move everything the server has sent into the inboxes."""
        for _ in range(_PUMP_MAX):
            var maybe = self.client.poll(Int32(0))
            if not maybe:
                return
            self._route(maybe.value().copy())

    def _route(mut self, var msg: LspIncoming) raises:
        if len(self._session_ids) == 0:
            return
        if msg.kind == LSP_RESPONSE:
            if not msg.id:
                return
            var id = _json_id_string(msg.id.value())
            if id == self._init_id and not self.init_result:
                # Kept even if the session that asked has since left: the
                # sessions waiting to join need it either way.
                self.init_result = Optional[LspIncoming](msg.copy())
            for k in range(len(self._req_ids)):
                if self._req_ids[k] == id:
                    var owner = self._req_owner[k]
                    _ = self._req_ids.pop(k)
                    _ = self._req_owner.pop(k)
                    self._deliver(owner, msg^, False)
                    return
            return   # a reply to a session that has left
        var method = msg.method.value() if msg.method else String("")
        var params = msg.params.value().copy() if msg.params else json_object()
        if msg.kind == LSP_REQUEST:
            if method == String("workspace/workspaceFolders"):
                # Only the channel knows every root.
                var folders = json_array()
                for i in range(len(self._session_roots)):
                    folders.append(_folder(self._session_roots[i]))
                self.client.send_response(msg.id.value().copy(), folders)
                return
            if _replayed_request(method):
                if method.startswith(String("client/")):
                    self._registrations.append(msg.copy())
                var first = self._session_ids[0]
                for i in range(len(self._session_ids)):
                    var sid = self._session_ids[i]
                    self._deliver(sid, msg.copy(), sid != first)
                return
            if method == String("window/showMessageRequest"):
                # Needs exactly one answer: the window it names, else the
                # one the user is working in.
                var named = self._session_named_in(
                    _str_at(params, String("message")),
                )
                self._deliver(
                    named if named >= 0 else self._active_session(), msg^, False,
                )
                return
            self._deliver(self._owner_of(_first_uri_of(method, params)), msg^, False)
            return
        if method == String("window/showMessage"):
            # A pop-up: to the window whose project it names, else to every
            # window on this server — a duplicate beats a missed error.
            var named = self._session_named_in(_str_at(params, String("message")))
            if named >= 0:
                self._deliver(named, msg^, False)
                return
            for i in range(len(self._session_ids)):
                self._deliver(self._session_ids[i], msg.copy(), False)
            return
        if _broadcast(method):
            for i in range(len(self._session_ids)):
                self._deliver(self._session_ids[i], msg.copy(), False)
            return
        self._deliver(self._owner_of(_first_uri_of(method, params)), msg^, False)

    def _owner_of(self, uri: String) -> Int:
        """The session a document belongs to: whoever has it open, else the
        one whose root holds it (the innermost, for nested roots), else the
        one the user is working in."""
        var k = self._open_index(uri)
        if k >= 0 and self._index_of(self._open_owner[k]) >= 0:
            return self._open_owner[k]
        var best = -1
        var best_len = -1
        for i in range(len(self._session_roots)):
            var root = self._session_roots[i]
            if _uri_under(uri, root) and len(root.as_bytes()) > best_len:
                best = self._session_ids[i]
                best_len = len(root.as_bytes())
        if best >= 0:
            return best
        return self._active_session()

    def _active_session(self) -> Int:
        """The last session to talk to the server, if it's still here."""
        if self._index_of(self._last_active) >= 0:
            return self._last_active
        return self._session_ids[0]

    def _session_named_in(self, text: String) -> Int:
        """The session whose project directory ``text`` mentions (the
        innermost, for nested roots), or -1. Servers name the project a
        message is about by path — "invalid config in <root>/pyproject.toml"
        — since a pop-up has no document field."""
        var best = -1
        var best_len = -1
        for i in range(len(self._session_roots)):
            var root = self._session_roots[i]
            if not root.startswith(String("file://")):
                continue
            var path = String(root[byte=7:])
            var plen = len(path.as_bytes())
            if plen <= best_len or not _mentions_path(text, path):
                continue
            best = self._session_ids[i]
            best_len = plen
        return best

    def _deliver(mut self, sid: Int, var msg: LspIncoming, replay: Bool):
        var i = self._index_of(sid)
        if i < 0:
            return
        if len(self._inbox[i]) >= _INBOX_MAX:
            _ = self._inbox[i].pop(0)
            _ = self._inbox_replay[i].pop(0)
        self._inbox[i].append(msg^)
        self._inbox_replay[i].append(replay)


def _folder(root_uri: String) -> JsonValue:
    var f = json_object()
    f.put(String("uri"), json_str(root_uri))
    var name = basename(String(root_uri[byte=7:])) \
        if root_uri.startswith(String("file://")) else basename(root_uri)
    f.put(String("name"), json_str(name))
    return f^


def server_key(language_id: String, argv: List[String]) -> String:
    """What makes two servers interchangeable: same language, same command.
    (A per-project binary — a venv-local server — differs in argv, so it
    is never shared, which is right: it sees that project's packages.)"""
    var key = language_id
    for i in range(len(argv)):
        key = key + String("\x00") + argv[i]
    return key^


struct LspPool(Movable):
    """Live shareable channels by ``server_key``. One per process, made by
    the host (``tk_lsp_pool_new``) and handed to every window's Desktop."""

    var _keys: List[String]
    var _channels: List[Int]

    def __init__(out self):
        self._keys = List[String]()
        self._channels = List[Int]()

    def find(self, key: String) -> Int:
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                return self._channels[i]
        return 0

    def add(mut self, key: String, channel: Int):
        self.forget(channel)
        for i in range(len(self._keys)):
            if self._keys[i] == key:
                self._channels[i] = channel
                return
        self._keys.append(key)
        self._channels.append(channel)

    def forget(mut self, channel: Int):
        """Stop offering ``channel`` to new sessions (it is closing, or a
        restart replaced it)."""
        var i = 0
        while i < len(self._channels):
            if self._channels[i] == channel:
                _ = self._keys.pop(i)
                _ = self._channels.pop(i)
            else:
                i += 1

    def channel_count(self) -> Int:
        return len(self._channels)


def channel_at(addr: Int) -> Pointer[LspChannel, MutUntrackedOrigin]:
    return Pointer[LspChannel, MutUntrackedOrigin](unsafe_from_address=addr)


def pool_at(addr: Int) -> Pointer[LspPool, MutUntrackedOrigin]:
    return Pointer[LspPool, MutUntrackedOrigin](unsafe_from_address=addr)


def new_channel(var client: LspClient, key: String) -> Int:
    var addr = external_call["malloc", Int](size_of[LspChannel]())
    if addr == 0:
        return 0
    channel_at(addr).unsafe_write(LspChannel(client^, key))
    return addr


def free_channel(addr: Int):
    """Destroy and free a channel whose process is already terminated."""
    if addr == 0:
        return
    channel_at(addr).unsafe_deinit_pointee()
    _ = external_call["free", Int](addr)


def new_pool() -> Int:
    var addr = external_call["malloc", Int](size_of[LspPool]())
    if addr == 0:
        return 0
    pool_at(addr).unsafe_write(LspPool())
    return addr


def free_pool(addr: Int):
    if addr == 0:
        return
    pool_at(addr).unsafe_deinit_pointee()
    _ = external_call["free", Int](addr)
