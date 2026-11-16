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
from .json import (
    JsonValue, json_array, json_get_string, json_object, json_str,
)
from .lsp import (
    LSP_NOTIFICATION, LSP_REQUEST, LSP_RESPONSE, LspClient, LspIncoming,
    file_uri_to_path, json_rpc_id,
)
from .capped_text import CappedText


# Bound on the messages one pump moves; the manager's own tick loop has
# the same guard against a runaway server.
comptime _PUMP_MAX = 256
# Cap on an inbox nobody is draining (an occluded window doesn't tick):
# beyond it the oldest messages go. Diagnostics are republished on the
# next edit, and a reply that old has long been given up on.
comptime _INBOX_MAX = 4096
comptime _STDERR_CAP = 16 * 1024


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
        return json_get_string(params, String("uri"))
    # Every lookup reads in place: ``object_get`` would copy the whole
    # ``edit`` (every file's edits) just to read one key.
    if method == String("workspace/configuration"):
        var ii = params.object_index(String("items"))
        if ii < 0 or params.obj_v[ii].value.array_len() == 0:
            return String("")
        return json_get_string(
            params.obj_v[ii].value.arr_v[0], String("scopeUri"),
        )
    if method == String("workspace/applyEdit"):
        var ei = params.object_index(String("edit"))
        if ei < 0:
            return String("")
        ref edit = params.obj_v[ei].value
        var ci = edit.object_index(String("changes"))
        if ci >= 0 and edit.obj_v[ci].value.object_len() > 0:
            return edit.obj_v[ci].value.obj_v[0].key
        var di = edit.object_index(String("documentChanges"))
        if di >= 0 and edit.obj_v[di].value.array_len() > 0:
            return _text_document_uri(edit.obj_v[di].value.arr_v[0])
    return String("")


def _text_document_uri(obj: JsonValue) -> String:
    """``obj.textDocument.uri``, or ``""`` — read in place (a didOpen's
    ``textDocument`` carries the whole file)."""
    var ti = obj.object_index(String("textDocument"))
    if ti < 0:
        return String("")
    return json_get_string(obj.obj_v[ti].value, String("uri"))


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


@fieldwise_init
struct _Queued(Copyable, Movable):
    """One inbox entry. ``replay`` marks a message another session answers
    (the recipient applies it but must not reply). ``msg`` is emptied as
    it is taken."""
    var msg: Optional[LspIncoming]
    var replay: Bool


struct _Session(Copyable, Movable):
    """A session on the channel: its root and its inbox, a FIFO read from
    ``head`` so taking a message is O(1) (``pop(0)`` shifted the whole
    inbox per message)."""
    var id: Int
    var root: String
    var inbox: List[_Queued]
    var head: Int

    def __init__(out self, id: Int, root: String):
        self.id = id
        self.root = root
        self.inbox = List[_Queued]()
        self.head = 0

    def pending(self) -> Int:
        return len(self.inbox) - self.head

    def push(mut self, var msg: LspIncoming, replay: Bool):
        if self.pending() >= _INBOX_MAX:
            # Full (nobody is draining it): the oldest goes.
            _ = self.inbox[self.head].msg.take()
            self.head += 1
        if self.head >= 64 and self.head * 2 >= len(self.inbox):
            # Compact: move the live tail down, once per inbox's worth of
            # dropped messages.
            var live = List[_Queued](capacity=self.pending() + 1)
            for k in range(self.head, len(self.inbox)):
                live.append(
                    _Queued(self.inbox[k].msg.take(), self.inbox[k].replay),
                )
            self.inbox = live^
            self.head = 0
        self.inbox.append(_Queued(Optional[LspIncoming](msg^), replay))

    def take(mut self, mut replay: Bool) -> Optional[LspIncoming]:
        replay = False
        if self.head >= len(self.inbox):
            return Optional[LspIncoming]()
        replay = self.inbox[self.head].replay
        var msg = self.inbox[self.head].msg.take()
        self.head += 1
        if self.head == len(self.inbox):
            self.inbox.clear()
            self.head = 0
        return Optional[LspIncoming](msg^)


@fieldwise_init
struct _OpenUri(Copyable, Movable):
    """A document some session has open: how many have, and which one
    diagnostics for it go to."""
    var uri: String
    var count: Int
    var owner: Int


@fieldwise_init
struct _Outstanding(Copyable, Movable):
    """A request in flight and the session that issued it."""
    var id: String
    var owner: Int


struct LspChannel(Movable):
    """A server process plus the routing that lets several sessions share
    it. See the module docstring."""

    var client: LspClient
    var key: String
    var _sessions: List[_Session]
    var _next_session: Int
    var _requests: List[_Outstanding]
    # The ``initialize`` exchange, done once per process.
    var _init_id: String
    var init_result: Optional[LspIncoming]
    var _initialized_sent: Bool
    # Every capability (un)registration so far, replayed to later joiners.
    var _registrations: List[LspIncoming]
    # Document URI → open count, so two sessions opening the same file
    # (a file shown in two project windows) don't double-``didOpen`` it.
    var _open: List[_OpenUri]
    var stderr_log: CappedText
    # Latched once the child is reaped, so every session notices the
    # death, not just whichever one's tick happened to reap it.
    var dead: Bool
    # The session that last sent the server anything — the window the user
    # is working in. Where a message naming no document goes.
    var _last_active: Int

    def __init__(out self, var client: LspClient, key: String):
        self.client = client^
        self.key = key
        self._sessions = List[_Session]()
        self._next_session = 1
        self._requests = List[_Outstanding]()
        self._init_id = String("")
        self.init_result = Optional[LspIncoming]()
        self._initialized_sent = False
        self._registrations = List[LspIncoming]()
        self._open = List[_OpenUri]()
        # Keeps the start of the log: the reason a server failed to come
        # up is in its first lines.
        self.stderr_log = CappedText(_STDERR_CAP, keep_tail=False)
        self.dead = False
        self._last_active = 0

    # --- sessions ----------------------------------------------------------

    def join(mut self, root_uri: String) -> Int:
        var sid = self._next_session
        self._next_session += 1
        self._sessions.append(_Session(sid, root_uri))
        return sid

    def leave(mut self, sid: Int) -> Int:
        """Drop session ``sid`` and everything addressed to it. Returns how
        many sessions remain."""
        var i = self._index_of(sid)
        if i >= 0:
            _ = self._sessions.pop(i)
        var k = 0
        while k < len(self._requests):
            if self._requests[k].owner == sid:
                _ = self._requests.pop(k)
            else:
                k += 1
        return len(self._sessions)

    def session_count(self) -> Int:
        return len(self._sessions)

    def roots(self) -> List[String]:
        var out = List[String](capacity=len(self._sessions))
        for i in range(len(self._sessions)):
            out.append(self._sessions[i].root)
        return out^

    def _index_of(self, sid: Int) -> Int:
        for i in range(len(self._sessions)):
            if self._sessions[i].id == sid:
                return i
        return -1

    def supports_folder_changes(self) -> Bool:
        """Whether the server said it accepts
        ``workspace/didChangeWorkspaceFolders`` — the condition for a
        second session to join rather than spawn. Read in place: the
        initialize result is the server's whole capability set."""
        if not self.init_result or not self.init_result.value().result:
            return False
        ref res = self.init_result.value().result.value()
        var ci = res.object_index(String("capabilities"))
        if ci < 0:
            return False
        ref caps = res.obj_v[ci].value
        var wi = caps.object_index(String("workspace"))
        if wi < 0:
            return False
        ref ws = caps.obj_v[wi].value
        var fi = ws.object_index(String("workspaceFolders"))
        if fi < 0:
            return False
        ref wf = ws.obj_v[fi].value
        var ni = wf.object_index(String("changeNotifications"))
        if ni < 0:
            return False
        ref cn = wf.obj_v[ni].value
        # ``boolean | string``: a string is a registration id, i.e. yes.
        if cn.is_string():
            return len(cn.str_v.as_bytes()) > 0
        return cn.is_bool() and cn.as_bool()

    def registrations(self) -> List[LspIncoming]:
        return self._registrations.copy()

    def change_folders(mut self, added: String, removed: String) raises:
        """Tell the server a root was added and/or removed (``""`` = none)."""
        var event = json_object()
        var add = json_array()
        if len(added.as_bytes()) > 0:
            add.append_owned(workspace_folder(added))
        var rem = json_array()
        if len(removed.as_bytes()) > 0:
            rem.append_owned(workspace_folder(removed))
        event.put_owned(String("added"), add^)
        event.put_owned(String("removed"), rem^)
        var params = json_object()
        params.put_owned(String("event"), event^)
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
        self._requests.append(_Outstanding(id, sid))
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
            var uri = _text_document_uri(params)
            var k = self._open_index(uri)
            if k >= 0:
                self._open[k].count += 1
                return
            self._open.append(_OpenUri(uri, 1, sid))
        elif method == String("textDocument/didClose"):
            var uri = _text_document_uri(params)
            var k = self._open_index(uri)
            if k >= 0:
                self._open[k].count -= 1
                if self._open[k].count > 0:
                    if self._open[k].owner == sid:
                        self._open[k].owner = self._other_session(sid)
                    return
                _ = self._open.pop(k)
        self.client.send_notification(method, params)

    def _open_index(self, uri: String) -> Int:
        if len(uri.as_bytes()) == 0:
            return -1
        for k in range(len(self._open)):
            if self._open[k].uri == uri:
                return k
        return -1

    def _other_session(self, sid: Int) -> Int:
        for i in range(len(self._sessions)):
            if self._sessions[i].id != sid:
                return self._sessions[i].id
        return sid

    # --- inbound -----------------------------------------------------------

    def drain_stderr(mut self):
        if self.stderr_log.full():
            # Still drained, so the server never blocks on a full pipe.
            _ = self.client.process.drain_stderr()
            return
        self.stderr_log.append(self.client.process.drain_stderr())

    def check_alive(mut self) -> Bool:
        """False once the child has exited (latched)."""
        if self.dead:
            return False
        if self.client.process.try_reap():
            self.drain_stderr()
            self.dead = True
            return False
        return True

    def pop(
        mut self, sid: Int, mut replay: Bool,
    ) raises -> Optional[LspIncoming]:
        """The next message for session ``sid``; ``replay`` says whether it
        is a replay (apply, don't answer). Reads what the server has sent
        once the inbox runs dry — pumping per message re-polled the pipe
        for every one already queued. The message moves out — a tuple
        return would make the caller deep-copy it."""
        replay = False
        var i = self._index_of(sid)
        if i < 0:
            return Optional[LspIncoming]()
        if self._sessions[i].pending() == 0:
            self.pump()
            # ``pump`` only appends to inboxes, so ``i`` still names ours.
        return self._sessions[i].take(replay)

    def pump(mut self) raises:
        """Move everything the server has sent into the inboxes."""
        for _ in range(_PUMP_MAX):
            var maybe = self.client.poll(Int32(0))
            if not maybe:
                return
            self._route(maybe.take())

    def _route(mut self, var msg: LspIncoming) raises:
        if len(self._sessions) == 0:
            return
        if msg.kind == LSP_RESPONSE:
            if not msg.id:
                return
            var id = json_rpc_id(msg.id.value())
            if id == self._init_id and not self.init_result:
                # Kept even if the session that asked has since left: the
                # sessions waiting to join need it either way.
                self.init_result = Optional[LspIncoming](msg.copy())
            for k in range(len(self._requests)):
                if self._requests[k].id == id:
                    var owner = self._requests[k].owner
                    _ = self._requests.pop(k)
                    self._deliver(owner, msg^, False)
                    return
            return   # a reply to a session that has left
        var method = msg.method.value() if msg.method else String("")
        # Routing reads two fields; borrowed, not a copy of the params (a
        # whole diagnostics payload) per message.
        var message = String("")
        var first_uri = String("")
        if msg.params:
            ref params = msg.params.value()
            message = json_get_string(params, String("message"))
            first_uri = _first_uri_of(method, params)
        if msg.kind == LSP_REQUEST:
            if method == String("workspace/workspaceFolders"):
                # Only the channel knows every root.
                var folders = json_array()
                for i in range(len(self._sessions)):
                    folders.append_owned(workspace_folder(self._sessions[i].root))
                self.client.send_response(msg.id.value(), folders)
                return
            if _replayed_request(method):
                if method.startswith(String("client/")):
                    self._registrations.append(msg.copy())
                var first = self._sessions[0].id
                for i in range(len(self._sessions)):
                    var sid = self._sessions[i].id
                    self._deliver(sid, msg.copy(), sid != first)
                return
            if method == String("window/showMessageRequest"):
                # Needs exactly one answer: the window it names, else the
                # one the user is working in.
                var named = self._session_named_in(message)
                self._deliver(
                    named if named >= 0 else self._active_session(), msg^, False,
                )
                return
            self._deliver(self._owner_of(first_uri), msg^, False)
            return
        if method == String("window/showMessage"):
            # A pop-up: to the window whose project it names, else to every
            # window on this server — a duplicate beats a missed error.
            var named = self._session_named_in(message)
            if named >= 0:
                self._deliver(named, msg^, False)
                return
            for i in range(len(self._sessions)):
                self._deliver(self._sessions[i].id, msg.copy(), False)
            return
        if _broadcast(method):
            for i in range(len(self._sessions)):
                self._deliver(self._sessions[i].id, msg.copy(), False)
            return
        self._deliver(self._owner_of(first_uri), msg^, False)

    def _owner_of(self, uri: String) -> Int:
        """The session a document belongs to: whoever has it open, else the
        one whose root holds it (the innermost, for nested roots), else the
        one the user is working in."""
        var k = self._open_index(uri)
        if k >= 0 and self._index_of(self._open[k].owner) >= 0:
            return self._open[k].owner
        var best = -1
        var best_len = -1
        for i in range(len(self._sessions)):
            ref root = self._sessions[i].root
            if _uri_under(uri, root) and len(root.as_bytes()) > best_len:
                best = self._sessions[i].id
                best_len = len(root.as_bytes())
        if best >= 0:
            return best
        return self._active_session()

    def _active_session(self) -> Int:
        """The last session to talk to the server, if it's still here."""
        if self._index_of(self._last_active) >= 0:
            return self._last_active
        return self._sessions[0].id

    def _session_named_in(self, text: String) -> Int:
        """The session whose project directory ``text`` mentions (the
        innermost, for nested roots), or -1. Servers name the project a
        message is about by path — "invalid config in <root>/pyproject.toml"
        — since a pop-up has no document field."""
        var best = -1
        var best_len = -1
        for i in range(len(self._sessions)):
            ref root = self._sessions[i].root
            if not root.startswith(String("file://")):
                continue
            var path = String(root[byte=7:])
            var plen = len(path.as_bytes())
            if plen <= best_len or not _mentions_path(text, path):
                continue
            best = self._sessions[i].id
            best_len = plen
        return best

    def _deliver(mut self, sid: Int, var msg: LspIncoming, replay: Bool):
        var i = self._index_of(sid)
        if i < 0:
            return
        self._sessions[i].push(msg^, replay)


def workspace_folder(root_uri: String) -> JsonValue:
    """The LSP ``WorkspaceFolder`` for ``root_uri``: ``{uri, name}``, the
    name being the root directory's (percent-decoded) basename."""
    var f = json_object()
    f.put_owned(String("uri"), json_str(root_uri))
    f.put_owned(String("name"), json_str(basename(file_uri_to_path(root_uri))))
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
