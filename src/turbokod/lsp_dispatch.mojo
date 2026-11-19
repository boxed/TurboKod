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

Limitations on purpose: no semantic tokens (the TextMate highlighter
owns coloring), and no concurrent definition requests (a fresh request
shadows the previous one's id).
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call

from .json import (
    encode_json, json_array, json_bool, json_float, json_get_bool, json_get_int,
    json_get_string, json_int, json_null, json_object, json_str, JsonValue,
    parse_json, take_json,
)
from .file_io import basename, join_path, parent_path, read_file, stat_file
from .lsp_position import (
    LineTable, POS_UTF8, encoding_from_name, encoding_name,
)
from .lsp_shared import (
    channel_at, free_channel, new_channel, pool_at, server_key,
    workspace_folder,
)
from .capped_text import CappedText
from .lsp import (
    LSP_NOTIFICATION, LSP_REQUEST, LSP_RESPONSE, LspClient, LspIncoming,
    LspProcess, file_uri_to_path, json_rpc_id, lsp_initialize_params,
)
from .posix import (
    debug_log_path, getcwd_path, getenv_value, monotonic_ms, realpath,
    realpath_or_self, sleep_ms,
)
from .string_utils import (
    percent_encode_uri_path, same_text, strip_trailing_newlines,
)
from .highlight import Highlight
from .colors import Attr, BLACK, EDITOR_BG, WHITE


def _lsp_debug_enabled() -> Bool:
    """True when ``turbokod-lsp.log`` exists in ``debug_log_path``
    (``$TMPDIR``) or ``TURBOKOD_LSP_LOG`` is set — ``touch
    "$TMPDIR/turbokod-lsp.log"`` to enable, delete the file to disable.
    A ``stat`` + ``getenv``: ``LspManager._logging`` caches it, so a
    keystroke's requests don't each pay for the check (or for building
    a line nobody writes)."""
    if stat_file(debug_log_path(String("turbokod-lsp.log"))).ok:
        return True
    return len(getenv_value(String("TURBOKOD_LSP_LOG")).as_bytes()) > 0


def _lsp_debug_log(line: String):
    """``_lsp_debug_write`` when logging is enabled — for a caller with no
    ``LspManager._logging`` cache to ask."""
    if _lsp_debug_enabled():
        _lsp_debug_write(line)


def _lsp_debug_write(line: String):
    """Append ``line`` (plus a trailing newline) to ``turbokod-lsp.log``.
    Callers check ``LspManager._logging`` (or ``_lsp_debug_enabled``)
    first.

    Opens with ``O_APPEND`` and writes one line per call so cost stays
    O(line) regardless of how large the log has grown. The previous
    read-modify-write was O(N) per call, i.e. O(N²) over a session —
    enabling debug logging on a busy LSP session would itself add
    multi-second latency to completion responses.
    """
    var path = debug_log_path(String("turbokod-lsp.log"))
    # Prefix each line with monotonic ms so the gap between
    # ``→ request_completion`` and ``← completion response`` is
    # readable by eye. The clock's absolute value is unspecified — only
    # differences are meaningful — but that's exactly what we want for
    # latency analysis.
    var stamp = String("[") + String(monotonic_ms()) + String("] ")
    var full = stamp + line + String("\n")
    var path_nul = path + String("\0")
    var fd = external_call["tk_debug_log_open", Int32](
        path_nul.unsafe_ptr(),
    )
    if fd < 0:
        return
    var bytes = full.as_bytes()
    _ = external_call["write", Int](
        fd, bytes.unsafe_ptr(), len(bytes),
    )
    _ = external_call["close", Int32](fd)


# How often ``LspManager._logging`` re-checks whether logging is enabled.
comptime _LOG_RECHECK_MS = 1000


# --- State -----------------------------------------------------------------

comptime _STATE_NOT_STARTED  = UInt8(0)
comptime _STATE_INITIALIZING = UInt8(1)
comptime _STATE_READY        = UInt8(2)
comptime _STATE_FAILED       = UInt8(3)

# How long to keep showing the "analyzing edits…" spinner waiting for
# a ``publishDiagnostics`` that may never come. See
# ``diagnostics_inflight_ms_for`` for the rationale — servers that
# don't push diagnostics for the current buffer would otherwise spin
# the indicator forever. 8 seconds covers a slow first-time
# rust-analyzer / pyright cold start with a fresh cache, but stops
# short of "user wonders if it's broken." Cheap to bump if needed.
comptime _DIAG_INFLIGHT_TIMEOUT_MS = 8000
# Cap on each of the server's stderr and protocol-log captures.
comptime _LOG_CAP = 16 * 1024

# How many outstanding (request id → document URI) pairs to remember for
# response position-remapping. Comfortably above the realistic number of
# concurrently in-flight requests (~25 distinct kinds); the bound only
# exists so a server that never answers can't grow the list forever.
comptime _REQ_URI_RING = 64

# A server that has sent nothing at all since a request went out this long
# ago is reported as not responding (the status bar says so, and Find
# Symbol stops asking it). Long enough that a slow answer on a quiet
# server isn't one: anything that slow is worth saying anyway, and the
# report clears with the next message.
comptime _UNRESPONSIVE_MS = 10_000
# Bound on the unanswered requests remembered for that.
comptime _AWAITED_MAX = 64

# Bounds on the shutdown handshake. It is a *poll* state machine
# (``begin_shutdown`` / ``shutdown_poll`` / ``finish_shutdown``) rather than a
# blocking wait, because closing a window must be instant: the host retires
# the manager and drains it off the runloop while the window is already gone.
# ``shutdown`` is the blocking wrapper, kept for the terminal frontend (which
# has no "later" — the process is exiting) and for tests.
#
# The budgets are wall-clock deadlines, not iteration counts, so they mean the
# same thing however often the host polls: a server answers ``shutdown`` in
# single-digit ms, and a wedged one gets SIGTERM once these elapse.
comptime _SHUTDOWN_POLL_MS = 10
comptime _SHUTDOWN_RESPONSE_MS = 300
comptime _SHUTDOWN_EXIT_MS = 200

# Stages of the close handshake. ``IDLE`` means no close is in progress;
# ``DONE`` means the transport can be torn down (the child exited, or its
# budget ran out and it has SIGTERM coming).
comptime _CLOSE_IDLE           = UInt8(0)
comptime _CLOSE_AWAIT_RESPONSE = UInt8(1)
comptime _CLOSE_AWAIT_EXIT     = UInt8(2)
comptime _CLOSE_DONE           = UInt8(3)

# How long to wait for the ``codeAction/resolve`` fan-out before publishing
# the actions that did resolve. The quick-fix menu shows "Loading fixes…"
# until then, so this is a UI-latency budget: long enough for a cold
# rust-analyzer to answer, short enough that a server which accepts a
# resolve and never replies doesn't leave the menu stuck.
comptime _CA_RESOLVE_TIMEOUT_MS = 2000


@fieldwise_init
struct DefinitionResolved(ImplicitlyCopyable, Movable):
    """A definition response that resolved to a concrete file location."""
    var path: String
    var line: Int        # 0-based, like ``Editor.cursor_row``
    var character: Int   # 0-based byte offset on that line


comptime _LIBPROBE_TIMEOUT_MS = 10_000


@fieldwise_init
struct _IdText(Copyable, Movable):
    """A request id (or a path) and the string that goes with it: a pull
    diagnostic's path, a request's document URI, a queued open's text."""
    var key: String
    var text: String


@fieldwise_init
struct _Awaited(Copyable, Movable):
    """A request the server still owes an answer, and when it went out."""
    var id: String
    var sent_ms: Int


@fieldwise_init
struct _InflightProbe(Copyable, Movable):
    var id: String
    var word: String
    var tag: Int
    var sent_ms: Int


@fieldwise_init
struct LibraryProbe(ImplicitlyCopyable, Movable):
    """A library-word probe's answer: where ``word`` is defined (None
    when the server found nothing), and the ``tag`` it was sent with."""
    var word: String
    var location: Optional[DefinitionResolved]
    var tag: Int
    var answered: Bool
    """False when the server never answered (``_LIBPROBE_TIMEOUT_MS``),
    which says nothing about the word."""


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
struct WorkspaceSymbolItem(ImplicitlyCopyable, Movable):
    """One entry in a ``workspace/symbol`` response. Unlike
    ``SymbolItem`` (used for ``textDocument/documentSymbol``), each
    item carries its own ``path`` because the response can span
    every file in the workspace. ``line`` / ``character`` are
    0-based to match the LSP wire form."""
    var name: String
    var kind: Int
    var container: String
    var path: String
    var line: Int
    var character: Int


@fieldwise_init
struct TextEditEntry(ImplicitlyCopyable, Movable):
    """One LSP ``TextEdit`` applied at an absolute buffer position.

    Used for ``CompletionItem.additional_text_edits`` — typically the
    auto-import line that an "import X" completion adds at the top of
    the file alongside the primary insertion. The range is half-open
    ``[start, end)`` in 0-based ``(line, character)`` coordinates;
    ``new_text`` may contain ``\\n`` to introduce new lines. Per the
    LSP spec these edits must not overlap with each other or with the
    primary edit, so applying them in descending order of position is
    safe — earlier positions are unaffected by later applications."""
    var start_line: Int
    var start_char: Int
    var end_line: Int
    var end_char: Int
    var new_text: String


struct CompletionItem(Copyable, Movable):
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

    ``additional_text_edits`` carries the LSP ``additionalTextEdits``
    field — auxiliary edits applied alongside the primary insert. The
    canonical use is auto-imports: a completion for ``foo_func`` may
    ship an additional edit that inserts ``from bar import foo_func\\n``
    at the top of the file. Empty for the common case. The presence of
    a ``List`` field is what forces a hand-rolled ``__copyinit__`` here
    (and prevents ``@fieldwise_init`` synthesis) — same trade-off as
    ``_DiagnosticBucket``.
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
    var additional_text_edits: List[TextEditEntry]
    # Raw JSON of the server's opaque ``data`` field, echoed verbatim in
    # ``completionItem/resolve`` (the server keys the resolve off it).
    # Empty when the item carried no ``data``.
    var data: String
    # True once the item has been through ``completionItem/resolve`` (or
    # never needed it). Gates the prefetch so we don't re-resolve the
    # same highlighted item every tick.
    var resolved: Bool

    def __init__(
        out self, var label: String, var insert_text: String, kind: Int,
        var detail: String, var sort_text: String, has_range: Bool,
        range_start_line: Int, range_start_char: Int,
        range_end_line: Int, range_end_char: Int,
        var additional_text_edits: List[TextEditEntry],
        var data: String = String(""), resolved: Bool = False,
    ):
        self.label = label^
        self.insert_text = insert_text^
        self.kind = kind
        self.detail = detail^
        self.sort_text = sort_text^
        self.has_range = has_range
        self.range_start_line = range_start_line
        self.range_start_char = range_start_char
        self.range_end_line = range_end_line
        self.range_end_char = range_end_char
        self.additional_text_edits = additional_text_edits^
        self.data = data^
        self.resolved = resolved


# LSP DiagnosticSeverity. Spec values; use the ``DIAG_SEVERITY_*`` names
# at call sites instead of bare ints so the priority order is obvious.
comptime DIAG_SEVERITY_ERROR   = Int(1)
comptime DIAG_SEVERITY_WARNING = Int(2)
comptime DIAG_SEVERITY_INFO    = Int(3)
comptime DIAG_SEVERITY_HINT    = Int(4)


struct Diagnostic(ImplicitlyCopyable, Movable):
    """One ``textDocument/publishDiagnostics`` entry, normalized to
    buffer-relative coordinates the editor can paint directly.

    ``start_row`` / ``start_col`` and ``end_row`` / ``end_col`` are
    0-based, like ``Editor.cursor_row``. ``severity`` is the LSP
    integer (1=Error, 2=Warning, 3=Info, 4=Hint) — keep it as the raw
    int so unknown future severities don't get silently dropped.
    ``source`` is the diagnostic-producing tool ("pyright", "rustc",
    "ruff", …) or empty when the server didn't supply one.
    ``code`` is the rule identifier ("unresolved-reference",
    "unused-import", ...) — kept as a String because LSP allows it to
    be either a string or an integer, and we just round-trip whatever
    came in. Echoed back in ``textDocument/codeAction`` requests:
    ty/ruff/pyright key fix lookups off this field, and a request
    without it gets ``result: null`` instead of the matching quickfix.
    Empty when the server didn't supply one — the 7-arg ``__init__``
    is the legacy form many tests still use and defaults ``code`` to
    empty since code-actions aren't exercised against synthetic
    diagnostics.
    """
    var start_row: Int
    var start_col: Int
    var end_row: Int
    var end_col: Int
    var severity: Int
    var message: String
    var source: String
    var code: String

    def __init__(
        out self, start_row: Int, start_col: Int, end_row: Int, end_col: Int,
        severity: Int, var message: String, var source: String,
    ):
        self.start_row = start_row
        self.start_col = start_col
        self.end_row = end_row
        self.end_col = end_col
        self.severity = severity
        self.message = message^
        self.source = source^
        self.code = String("")

    def __init__(
        out self, start_row: Int, start_col: Int, end_row: Int, end_col: Int,
        severity: Int, var message: String, var source: String,
        var code: String,
    ):
        self.start_row = start_row
        self.start_col = start_col
        self.end_row = end_row
        self.end_col = end_col
        self.severity = severity
        self.message = message^
        self.source = source^
        self.code = code^


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

    def __init__(
        out self, var path: String, var diags: List[Diagnostic],
        consumed: Bool,
    ):
        self.path = path^
        self.diags = diags^
        self.consumed = consumed


struct CodeActionFileEdit(Copyable, Movable):
    """One file's worth of edits inside a ``CodeAction``'s WorkspaceEdit.

    LSP's WorkspaceEdit groups edits per URI via the ``changes`` map
    (``{uri: TextEdit[]}``). We normalize that into a flat list of
    ``CodeActionFileEdit`` — one per file — so the host can iterate
    without re-walking the JSON. Hand-rolled ``__copyinit__`` because
    the nested ``List`` blocks ``ImplicitlyCopyable``.
    """
    var uri: String
    var edits: List[TextEditEntry]

    def __init__(out self, var uri: String, var edits: List[TextEditEntry]):
        self.uri = uri^
        self.edits = edits^


struct CodeAction(Copyable, Movable):
    """One entry in a ``textDocument/codeAction`` response.

    The LSP spec allows the server to return either ``Command``s (an
    opaque server-side action) or ``CodeAction`` literals carrying an
    inline ``WorkspaceEdit``. We only model the literal form — that's
    what every server we care about (ty, pyright, ruff, rust-analyzer)
    returns when the client advertises ``codeActionLiteralSupport``,
    and it's what lets us apply the fix locally without a round-trip.

    ``title`` is the label to render in the quick-fix popup.
    ``kind`` is the LSP ``CodeActionKind`` string ("quickfix",
    "refactor", "source.organizeImports", …) — kept as raw text so
    future server kinds don't get silently dropped. ``is_preferred``
    flags the entry as the recommended fix, which is what we'll bind
    to "press Enter to accept" once UI lands. ``file_edits`` carries
    the per-file edit groups extracted from the ``WorkspaceEdit.changes``
    map; an empty list means the action carried only a ``Command`` or
    a WorkspaceEdit we refused because it also creates/renames/deletes
    files, and the host should skip / ignore the entry (or resolve it
    first, if ``data`` is set).
    """
    var title: String
    var kind: String
    var is_preferred: Bool
    var file_edits: List[CodeActionFileEdit]
    # When the action carries a ``Command`` (instead of, or in addition to,
    # an inline edit), ``command`` is its id and ``command_args`` the raw
    # ``arguments`` array — sent via ``workspace/executeCommand`` when the
    # action has no directly-applicable ``file_edits``.
    var command: String
    var command_args: Optional[JsonValue]
    # The action exactly as the server sent it, kept so we can hand it back
    # in a ``codeAction/resolve`` request — the spec's params for that
    # request *are* a CodeAction, not just its ``data`` field, and servers
    # (rust-analyzer) reject a synthesized one. Set only when the action
    # arrived with no inline ``edit``: an action we can already apply needs
    # no round-trip, and holding the raw JSON for every action would keep
    # the whole response alive for as long as the menu is open.
    var unresolved: Optional[JsonValue]

    def __init__(
        out self, var title: String, var kind: String, is_preferred: Bool,
        var file_edits: List[CodeActionFileEdit],
        var command: String = String(""),
        var command_args: Optional[JsonValue] = Optional[JsonValue](),
        var unresolved: Optional[JsonValue] = Optional[JsonValue](),
    ):
        self.title = title^
        self.kind = kind^
        self.is_preferred = is_preferred
        self.file_edits = file_edits^
        self.command = command^
        self.command_args = command_args^
        self.unresolved = unresolved^


def _json_at_path(
    v: JsonValue, keys: List[String], i: Int,
) -> Optional[JsonValue]:
    """A copy of the value at ``v.keys[i].keys[i+1]…``, or empty when a
    step is absent or not an object. Only the leaf is copied."""
    if i == len(keys):
        return v.copy()
    if not v.is_object():
        return None
    var k = v.object_index(keys[i])
    if k < 0:
        return None
    return _json_at_path(v.obj_v[k].value, keys, i + 1)


struct _PositionRemapper(Copyable, Movable):
    """Rewrites every ``Position.character`` in a JSON payload between the
    editor's byte columns and the negotiated wire encoding.

    Why a blanket JSON walk rather than a conversion at each of the ~16
    position-building sites and ~30 result-parsing sites: LSP nests
    Positions inside a *lot* of shapes (``Location``, ``LocationLink``,
    ``Diagnostic.relatedInformation``, ``WorkspaceEdit.changes`` keyed by
    URI, ``documentChanges``, ``InsertReplaceEdit``'s two ranges, opaque
    ``Command.arguments`` we round-trip verbatim), and a per-site fix has
    to be remembered at every new site forever. A Position is
    unambiguously identifiable — an object carrying integer ``line`` and
    ``character`` — so one walk at the transport boundary covers all of
    them, and the two directions being the *same* walk is what makes
    round-tripping opaque server data (``command.arguments``,
    ``completionItem/resolve``'s echoed item) correct: whatever we
    decoded on the way in, we re-encode identically on the way out.

    Conversion is per line, so the walk needs the document's text. The
    URI context comes from the enclosing object's ``uri`` / ``targetUri``
    / ``textDocument.uri``, or from the key when descending a
    ``WorkspaceEdit.changes`` map; ``default_uri`` covers results whose
    positions are implicitly about the request's own document (hover,
    documentSymbol, formatting …). With no resolvable URI we leave the
    value alone — a wrong column beats a guessed one.

    Open buffers' text is the manager's ``_docs`` (what the server was
    last sent — authoritative, the buffer may be dirty), passed to each
    walk and indexed only when a walk first needs it, so an edit costs
    nothing until a payload actually mentions that document; an edit or
    close ``invalidate``s the stale index. Anything
    else is read from disk, cached for the life of one walk
    (``begin_walk``), so a rename touching 50 edits in one file reads and
    indexes it once.

    The walk rewrites the payload in place: rebuilding it copied each
    node once per level on the way down and again into its parent.
    """
    var enc: UInt8
    var paths: List[String]
    var tables: List[LineTable]
    var from_disk: List[Bool]
    var missing: List[String]

    def __init__(out self, enc: UInt8):
        self.enc = enc
        self.paths = List[String]()
        self.tables = List[LineTable]()
        self.from_disk = List[Bool]()
        self.missing = List[String]()

    def invalidate(mut self, path: String):
        """Forget ``path``'s index: an open document's text changed, or it
        closed (and is read from disk from now on)."""
        for i in range(len(self.paths)):
            if self.paths[i] == path:
                _ = self.paths.pop(i)
                _ = self.tables.pop(i)
                _ = self.from_disk.pop(i)
                return

    def begin_walk(mut self):
        """Start a top-level walk: files read from disk may have changed
        since the last one, so their indexes (and misses) are dropped.
        Open documents' indexes stay until their text changes."""
        var i = 0
        while i < len(self.paths):
            if self.from_disk[i]:
                _ = self.paths.pop(i)
                _ = self.tables.pop(i)
                _ = self.from_disk.pop(i)
            else:
                i += 1
        self.missing.clear()

    def _slot_for(mut self, path: String, docs: List[_OpenDoc]) -> Int:
        """Cache slot for ``path``: an open document's text (``docs``, what
        the server was last sent — authoritative, the buffer may be dirty),
        or the file on disk. Returns -1 when the file can't be read — the
        caller then leaves columns untouched rather than converting
        against empty text."""
        if len(path.as_bytes()) == 0:
            return -1
        for i in range(len(self.paths)):
            if self.paths[i] == path:
                return i
        for i in range(len(docs)):
            if docs[i].path == path:
                self.paths.append(path)
                self.tables.append(LineTable(docs[i].text.copy()))
                self.from_disk.append(False)
                return len(self.tables) - 1
        for i in range(len(self.missing)):
            if self.missing[i] == path:
                return -1
        try:
            var text = read_file(path)
            self.paths.append(path)
            self.tables.append(LineTable(text^))
            self.from_disk.append(True)
        except:
            self.missing.append(path)
            return -1
        return len(self.tables) - 1

    def _own_uri(self, v: JsonValue) -> String:
        """``v``'s own URI context: its ``uri`` / ``targetUri``, else the
        ``uri`` of a nested ``textDocument`` (the ``documentChanges``
        shape); ``""`` when it carries none and inherits its parent's."""
        var di = v.object_index(String("uri"))
        if di >= 0 and v.obj_v[di].value.is_string():
            return v.obj_v[di].value.str_v
        var ti = v.object_index(String("targetUri"))
        if ti >= 0 and v.obj_v[ti].value.is_string():
            return v.obj_v[ti].value.str_v
        var tdi = v.object_index(String("textDocument"))
        if tdi >= 0 and v.obj_v[tdi].value.is_object():
            ref td = v.obj_v[tdi].value
            var ui = td.object_index(String("uri"))
            if ui >= 0 and td.obj_v[ui].value.is_string():
                return td.obj_v[ui].value.str_v
        return String("")

    def walk(
        mut self, mut v: JsonValue, uri: String, to_bytes: Bool,
        docs: List[_OpenDoc],
    ):
        """Convert every Position's ``character`` in ``v``, in place.

        ``to_bytes`` True is the inbound direction (wire units → byte
        columns); False is outbound (byte columns → wire units).
        """
        if self.enc == POS_UTF8:
            return
        var slot = _SLOT_UNRESOLVED
        self._walk(v, uri, slot, to_bytes, docs)

    def _walk(
        mut self, mut v: JsonValue, uri: String, mut slot: Int,
        to_bytes: Bool, docs: List[_OpenDoc],
    ):
        """``walk`` with the URI context's table slot, resolved on the
        first Position under it and shared by the rest (a 500-edit
        formatting result resolves its document once, not 500 times)."""
        if v.is_array():
            for i in range(len(v.arr_v)):
                self._walk(v.arr_v[i], uri, slot, to_bytes, docs)
            return
        if not v.is_object():
            return
        var ln = v.object_index(String("line"))
        var ch = v.object_index(String("character"))
        if ln >= 0 and ch >= 0 and v.obj_v[ln].value.is_int() \
                and v.obj_v[ch].value.is_int():
            if slot == _SLOT_UNRESOLVED:
                slot = self._slot_for(_uri_to_path(uri), docs)
            if slot < 0:
                return
            var row = v.obj_v[ln].value.int_v
            var col = v.obj_v[ch].value.int_v
            if to_bytes:
                col = self.tables[slot].wire_to_col(row, col, self.enc)
            else:
                col = self.tables[slot].col_to_wire(row, col, self.enc)
            v.obj_v[ch].value.int_v = col
            return
        var own = self._own_uri(v)
        if len(own.as_bytes()) > 0:
            # A new context: children resolve their own slot.
            var own_slot = _SLOT_UNRESOLVED
            self._walk_members(v, own, own_slot, to_bytes, docs)
        else:
            self._walk_members(v, uri, slot, to_bytes, docs)

    def _walk_members(
        mut self, mut v: JsonValue, uri: String, mut slot: Int,
        to_bytes: Bool, docs: List[_OpenDoc],
    ):
        for i in range(len(v.obj_v)):
            # ``WorkspaceEdit.changes`` is a ``{uri: TextEdit[]}`` map — the
            # URI context for each group is the *key*, not a field.
            if v.obj_v[i].key == String("changes") \
                    and v.obj_v[i].value.is_object():
                ref changes = v.obj_v[i].value
                for k in range(len(changes.obj_v)):
                    var curi = changes.obj_v[k].key
                    var cslot = _SLOT_UNRESOLVED
                    self._walk(
                        changes.obj_v[k].value, curi, cslot, to_bytes, docs,
                    )
                continue
            self._walk(v.obj_v[i].value, uri, slot, to_bytes, docs)


comptime _SLOT_UNRESOLVED = -2


@fieldwise_init
struct _OpenDoc(Copyable, Movable):
    """A document the server has been sent ``didOpen`` for, and the last
    text it got. Cursor-driven requests (documentHighlight, signatureHelp,
    documentColor, …) all funnel through ``_send_open_or_change`` to
    guarantee the server has the live text; without the comparison, each
    one bumps the version and fires a no-op didChange even when nothing
    changed, which restarts the server's analysis and flickers the
    "analyzing edits…" spinner on every cursor move."""
    var path: String    # absolute
    # ``_path_to_uri(path)``, resolved once at didOpen: every request for
    # the document names it, and ``realpath`` is a syscall per component.
    var uri: String
    var version: Int
    # The last text sent. Not a second copy of the buffer: the host passes
    # ``Editor.lsp_text``, cached per edit, and a ``String`` copy shares
    # its bytes — so comparing against it is a memcmp of the same buffer
    # while nothing changed, and exact (a hash was neither).
    var text: String


struct _Slot[T: Copyable & Defaultable & Deinitable](Copyable, Movable):
    """One request whose parsed answer is parked until the host takes it:
    the in-flight id, the file it was asked about, the answer, and
    ``ready`` to tell "no answer yet" from "an empty one"."""
    var id: String
    # The file the request was about, echoed to the host so it can drop
    # an answer for a buffer it no longer shows.
    var path: String
    # The buffer text the request was made against, for answers that only
    # mean anything against exactly that text (formatting, on-type, rename
    # edits): the host drops them if the buffer has moved on by the time
    # they land. Set by the requester ahead of the send.
    var text: String
    var value: Self.T
    var ready: Bool

    def __init__(out self):
        self.id = String("")
        self.path = String("")
        self.text = String("")
        self.value = Self.T()
        self.ready = False

    def start(mut self, id: String, path: String = String("")) -> Bool:
        """Record a request just sent (``id`` empty: the send failed, so
        nothing is in flight and the parked answer, path included, stays)."""
        self.id = id
        if len(id.as_bytes()) == 0:
            return False
        self.path = path
        self.value = Self.T()
        self.ready = False
        return True

    def owns(self, id: String) -> Bool:
        return len(self.id.as_bytes()) > 0 and id == self.id

    def publish(mut self, var value: Self.T):
        """Park ``value`` for the host, leaving any in-flight id alone (an
        answer settled by a follow-up round-trip, after a newer request
        may already have gone out)."""
        self.value = value^
        self.ready = True

    def finish(mut self, var value: Self.T):
        self.publish(value^)
        self.id = String("")

    def settle[parse: def(JsonValue) thin -> Self.T](
        mut self, result: Optional[JsonValue],
    ):
        """Finish with ``parse`` of a response's result, or the empty
        answer when there is none (an error response)."""
        if result:
            self.finish(parse(result.value()))
        else:
            self.finish(Self.T())

    def take(mut self) -> Self.T:
        """Move the parked answer out. Drops ``text`` with it: the host
        reads that first, and kept, it held a whole-file snapshot until
        the next request of the kind — past the file being closed."""
        var out = Self.T()
        swap(out, self.value)
        self.ready = False
        self.text = String("")
        return out^


# A request answered by a flat ``TextEditEntry`` list (edits, or range /
# row carriers) for one file.
comptime _EditSlot = _Slot[List[TextEditEntry]]


struct _ResolveFanout(Copyable, Movable):
    """In-flight ``*/resolve`` requests of one fan-out: each request id
    and the result slot its response fills. Used for code actions and
    document links, which both resolve a batch then publish once none is
    outstanding."""
    var _ids: List[String]
    var _slots: List[Int]

    def __init__(out self):
        self._ids = List[String]()
        self._slots = List[Int]()

    def add(mut self, id: String, slot: Int):
        self._ids.append(id)
        self._slots.append(slot)

    def pending(self) -> Int:
        return len(self._ids)

    def slot(self, id: String) -> Int:
        """Result slot the response ``id`` fills, or -1."""
        for i in range(len(self._ids)):
            if self._ids[i] == id:
                return self._slots[i]
        return -1

    def drop(mut self, id: String):
        for i in range(len(self._ids)):
            if self._ids[i] == id:
                _ = self._ids.pop(i)
                _ = self._slots.pop(i)
                return


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
    # Position encoding negotiated at ``initialize`` (LSP 3.17
    # ``general.positionEncodings``). The rest of this file treats LSP
    # ``character`` offsets as byte offsets into the line, which is exactly
    # what ``utf-8`` means — so with ``utf-8`` negotiated, the editor's byte
    # columns map straight through, including on lines with multibyte
    # characters. A server that doesn't support the negotiation uses the
    # spec-mandated default ``utf-16``, and then byte columns are *not*
    # valid ``character`` offsets on any line containing multibyte text —
    # so every position crossing the transport is converted by
    # ``_PositionRemapper``. ``_position_encoding_tag`` is the parsed tag driving
    # that; ``_position_encoding`` keeps the raw string for display.
    var _position_encoding: String
    var _position_encoding_tag: UInt8
    # Line-index cache backing the conversion: open documents are
    # registered as they're sent and indexed only when a payload needs
    # them (see ``_PositionRemapper``).
    var _remap: _PositionRemapper
    # ``id`` → the ``textDocument.uri`` the request was about, recorded at
    # send time. A response's positions are usually *implicitly* about the
    # request's own document (hover range, formatting TextEdits, inlay
    # hints, folding ranges …) with no URI on the wire, so remapping them
    # needs that context back. Taking it from the outbound params rather
    # than a per-request ``_x_path`` field means every request — including
    # ones added later — gets it for free. Bounded ring: a response we
    # never see would otherwise leak an entry per request.
    var _req_uris: List[_IdText]
    # The requests the server hasn't answered, oldest first, and when it
    # last sent anything: together they tell a server that is slow from
    # one that has stopped answering (``unresponsive_secs``). A process
    # can be alive, its pipes open and its state READY while it reads
    # nothing — ty deadlocked that way, and every request then waited
    # forever behind a status bar saying "ready".
    var _awaited: List[_Awaited]
    var _last_rx_ms: Int
    # Server-driven invalidation (``workspace/*/refresh``). The server tells
    # us its previous answers for a whole class of feature are stale — after
    # a build finishes, a dependency resolves, a config file changes. We used
    # to reply MethodNotFound, so the server gave up and the stale inlay
    # hints / code lenses / folding ranges sat there until the buffer's line
    # count happened to change (the host's debounce key). Two flags rather
    # than five because that is the granularity the host can act on: one
    # clears its document-feature debounce key, the other re-pulls
    # diagnostics.
    var _refresh_doc_features: Bool
    var _refresh_diagnostics: Bool
    # Close-handshake state. See the ``_CLOSE_*`` constants: the handshake is
    # driven by polls so a window close never waits on a language server.
    var _close_stage: UInt8
    var _close_deadline_ms: Int
    var _close_shutdown_id: String
    # Shared transport (``lsp_shared.mojo``). ``_channel`` is the address of
    # the ``LspChannel`` this manager is a session on, 0 for the private
    # ``client`` (no pool, or a server that can't share). ``_join_pending``:
    # joined a channel whose ``initialize`` result hasn't arrived yet.
    # ``_reply_muted``: the message being handled is a replay another session
    # answers, so this one must not reply.
    var _channel: Int
    var _session: Int
    var _pool: Int
    var _join_pending: Bool
    var _reply_muted: Bool

    # Outstanding request ids — strings so they round-trip verbatim
    # whether they ride as JSON ints or JSON strings on the wire (we
    # send strings; some servers reply with strings, our test stubs
    # use ints — the comparison code is identical either way because
    # we always canonicalize ids to strings before comparing).
    # Empty string is the "no request in flight" sentinel.
    var _init_id: String
    var _inflight_def_id: String
    var _inflight_word: String       # surfaced via status_summary() while pending
    var _last_empty: Bool            # latched when a response had no location
    # Word from a definition request whose response *just* arrived empty.
    # One-shot: ``take_empty_word()`` returns it and clears, so the host
    # can chain a fallback (e.g. open the docs entry for that word) on
    # the same frame the empty response lands. Distinct from the latched
    # ``_last_empty`` flag, which persists across frames so the status
    # bar can keep showing "no definition found" until the next request.
    var _empty_word: String
    # Origin of the most recently completed definition request — the
    # (path, line, character) the user actually clicked on, plus the word
    # under that click. Surfaced via ``definition_origin_*`` so the host
    # can compare against the resolved location: when they overlap, the
    # click landed on the definition site itself and the host can chain a
    # references lookup instead of jumping to where the user already is.
    var _def_origin_path: String
    var _def_origin_line: Int
    var _def_origin_char: Int
    var _def_origin_word: String
    # Raw server ``capabilities`` object from the initialize response,
    # queried via ``server_supports`` so feature requests only fire when
    # the server advertises them. Empty until initialize lands.
    var _capabilities: Optional[JsonValue]
    # True once the server has registered (via ``client/registerCapability``)
    # or statically advertised a ``workspace/didChangeWatchedFiles`` watcher.
    # We don't model the registered glob patterns — this just gates the
    # notification so we never push watched-file events to a server that
    # never asked for them (most ask dynamically, post-initialize).
    var _watches_files: Bool
    # ``_lsp_debug_enabled``, cached by ``_logging`` and re-checked at
    # most once per ``_LOG_RECHECK_MS``.
    var _log_on: Bool
    var _log_checked_ms: Int
    # Generic "navigate to a location" request (typeDefinition /
    # implementation / declaration). Parked target + origin word, kept
    # separate from the definition slot so it never triggers the
    # cmd-click → references chaining the definition path does.
    var _nav: _Slot[Optional[DefinitionResolved]]
    var _nav_word: String
    # Background ``textDocument/definition``s asking whether misspelled
    # words are library symbols (``Desktop._maybe_probe_library_word``,
    # ``_library_check_step``). Slots of their own so they never disturb
    # a user's Cmd+click; answers queue in arrival order.
    var _libprobes: List[_InflightProbe]
    var _libprobe_done: List[LibraryProbe]
    # ``textDocument/prepareRename`` round-trip that gates the rename
    # flow. ``_prepare_rename_state``: 0 = unsupported / errored (host
    # falls back to a direct prompt), 1 = renameable (seed prompt with
    # the placeholder ``_prepare_rename`` parks), 2 = not renameable
    # (null result).
    var _prepare_rename: _Slot[String]
    var _prepare_rename_state: Int
    # ``textDocument/references`` — list-of-locations form of definition.
    # Parked as ``DefinitionResolved`` rows (same shape, different list).
    # ``_references.ready`` distinguishes "no response yet" from
    # "empty list".
    var _references: _Slot[List[DefinitionResolved]]
    var _ref_word: String
    var _symbols: _Slot[List[SymbolItem]]
    # ``workspace/symbol`` — parallel to the document-symbol fields but
    # scoped to a workspace-wide query rather than a single document.
    # Used by the Find Symbol picker to disambiguate same-named symbols.
    var _ws_symbols: _Slot[List[WorkspaceSymbolItem]]
    # Pending ``textDocument/completion`` request state. The slot's path
    # is echoed back via ``pending_completion_path`` so the host can drop a
    # stale response when the user has switched buffers by the time it
    # lands. ``_completion_manual`` records
    # whether the request was a user-invoked Ctrl+Space (vs. the as-you-
    # type auto-trigger) so the host can decide whether an empty
    # response should surface a ``<no completion found>`` message.
    var _completions: _Slot[List[CompletionItem]]
    var _completion_manual: Bool
    # ``completionItem/resolve`` round-trip. Servers that set
    # ``resolveProvider`` ship the initial list without ``detail`` /
    # ``additionalTextEdits`` (auto-imports) and fill them in only on a
    # follow-up resolve. We surface just the resolved item's aux edits +
    # detail; the host merges them into the completion item it already
    # holds (it tracks the item's identity itself). One in flight at a
    # time — a fresh resolve shadows the prior id.
    var _inflight_resolve_id: String
    var _resolve_aux: List[TextEditEntry]
    var _resolve_detail: String
    var _has_resolve_result: Bool
    # Pending ``textDocument/hover`` request state. Same idea as the
    # completion fields: the slot's path and ``_hover_row``/``_hover_col``
    # are echoed via ``pending_hover_*`` so the host can drop a stale
    # response when the cursor has moved off the symbol. ``_hover`` parks
    # the rendered hover text (already joined into a single string).
    var _hover: _Slot[String]
    var _hover_row: Int
    var _hover_col: Int
    # Pending ``textDocument/codeAction`` request state: the slot parks
    # the parsed action list until ``take_code_actions`` consumes it.
    # The slot's path is echoed via ``pending_code_action_path`` so
    # the host can tell when the response is for a stale diagnostic menu
    # (the user moved on).
    var _code_actions: _Slot[List[CodeAction]]
    # ``codeAction/resolve`` fan-out. A server with
    # ``codeActionProvider.resolveProvider`` returns actions with a title and
    # no ``edit``; we resolve every such action before publishing the list, so
    # the host's contract ("these are the actions you can apply") is unchanged
    # and it needs to know nothing about resolve. Ids and the accumulator
    # slot each one fills run in parallel lists; the list emptying is what
    # publishes ``_code_actions``.
    var _ca_resolve: _ResolveFanout
    var _ca_accum: List[CodeAction]
    var _ca_resolve_deadline_ms: Int
    # Pending ``textDocument/rename`` request state. Same shape as the
    # code-action slots: an inflight id, an echoed origin path so a stale
    # response can be dropped, and a parked ``WorkspaceEdit`` (reusing the
    # ``CodeActionFileEdit`` grouping since rename returns the same shape).
    var _rename: _Slot[List[CodeActionFileEdit]]
    # ``textDocument/formatting`` + ``rangeFormatting`` — both return a flat
    # ``TextEdit[]`` for one file, parked here for the host to apply via
    # the same edit-application path rename/code-actions use.
    # ``.text`` is the buffer the edits are for; the host drops them if
    # the buffer has moved on (typing, a merged outside write) by the time
    # they arrive. Same for ``_willsave.text``.
    var _formatting: _EditSlot
    # ``textDocument/onTypeFormatting`` — format-as-you-type. Fired when a
    # server-declared trigger char (``}``/``;``/newline/…) is typed; the
    # returned ``TextEdit[]`` (typically a reindent) is parked here and
    # applied without saving (distinct from the on-save formatting slot).
    # ``.text`` matters even more here: the next keystroke usually lands
    # before the edits do.
    var _ontype: _EditSlot
    # ``textDocument/moniker`` — cross-repo symbol identity (scheme +
    # identifier). Rendered as a one-line status string; parked here.
    var _moniker: _Slot[String]
    # ``textDocument/colorPresentation`` — given a color + its range, the
    # server returns alternate textual forms (hex / rgb() / named). Parked
    # as parallel ``_colorpres_labels`` / ``_colorpres_edits`` (label[i] ↔
    # the TextEdit that rewrites the literal to that form). ``_colorpres_*``
    # range fields remember the requested span so a label-only presentation
    # (no textEdit) can synthesize one.
    var _colorpres: _Slot[List[String]]
    var _colorpres_edits: List[TextEditEntry]
    var _colorpres_sl: Int
    var _colorpres_sc: Int
    var _colorpres_el: Int
    var _colorpres_ec: Int
    # ``textDocument/inlineCompletion`` — ghost-text suggestion. Parked text
    # + the request position (so the editor anchors the ghost there).
    var _inlinecomp: _Slot[String]
    var _inlinecomp_row: Int
    var _inlinecomp_col: Int
    # ``textDocument/linkedEditingRange`` — the set of ranges that should be
    # edited together (e.g. an HTML open/close tag pair). Parked as range
    # carriers; the host places synchronized carets at them for co-editing.
    var _linked: _EditSlot
    # ``textDocument/inlineValue`` — values to show inline at the stopped
    # debug frame. We render the ``InlineValueText`` variant (server gives
    # the text directly) as end-of-line annotations, parked here as (row,
    # text) carriers. (The variable-lookup / evaluable-expression variants
    # would need a DAP ``evaluate`` round-trip — not wired yet.)
    var _inlineval: _EditSlot
    # The variable-lookup / evaluable-expression inline values: (row, expr)
    # carriers the host evaluates via DAP, then renders as ``expr = value``.
    var _inlineval_exprs: List[TextEditEntry]
    # ``textDocument/foldingRange`` — collapsible regions. Parked as range
    # carriers (start_line..end_line). The editor marks region starts; full
    # collapse (which needs fold-aware cursor/scroll/layout) is deferred.
    var _folding: _EditSlot
    # ``textDocument/documentHighlight`` — occurrences of the symbol at the
    # cursor, parked as range carriers (``TextEditEntry`` with empty
    # ``new_text``) for the host to push into the editor overlay.
    var _doc_highlight: _EditSlot
    # ``textDocument/signatureHelp`` — the active signature's rendered label
    # (with the active parameter marked), parked for the status bar.
    var _signature: _Slot[String]
    # ``textDocument/inlayHint`` + ``codeLens`` — rendered as end-of-line
    # annotations. Parked as (row, text) carriers (``TextEditEntry`` with
    # ``start_line`` = row, ``new_text`` = the label).
    var _inlay: _EditSlot
    var _codelens: _EditSlot
    # ``codeLens/resolve`` round-trip. Servers (rust-analyzer) ship lenses
    # without a ``command`` — just ``range`` + ``data`` — and fill the
    # title only on resolve. We'd otherwise drop those, so we queue the raw
    # unresolved lenses, resolve them one at a time, and grow ``_codelens_
    # accum`` (the source of truth re-published into ``_resolved_codelens``
    # after each resolve so the host's overlay grows). ``_codelens_resolve_
    # row`` is the line of the in-flight lens.
    var _inflight_codelens_resolve_id: String
    var _codelens_resolve_queue: List[JsonValue]
    var _codelens_resolve_row: Int
    var _codelens_accum: List[TextEditEntry]
    # ``textDocument/documentLink`` — clickable links (range + target uri),
    # parked as range carriers with ``new_text`` = the target. Only links
    # the server returned with an inline ``target`` are kept (we don't
    # round-trip ``documentLink/resolve`` for deferred targets).
    var _doclinks: _EditSlot
    # ``documentLink/resolve`` fan-out. Unlike the code-action one this does
    # *not* gate publication: links are decorative, so the list is published
    # immediately and re-published as each target arrives. The accumulator is
    # the full list every time, because the host replaces its link set on
    # each take — handing it only the newly-resolved ones would drop the
    # rest.
    var _dl_resolve: _ResolveFanout
    var _dl_accum: List[TextEditEntry]
    # Server-initiated status: ``$/progress`` (work-done progress) and
    # ``window/showMessage``. Parked for the host to surface in the status
    # bar — progress only when ``lsp_server_progress`` is on.
    var _progress_note: String
    var _has_progress_note: Bool
    var _server_message: String
    var _has_server_message: Bool
    # ``textDocument/selectionRange`` — the cursor's range hierarchy
    # (innermost→outermost), parked for the editor's smart-select grow.
    var _selrange: _EditSlot
    # Call / type hierarchy: a two-step flow (prepare → incomingCalls /
    # supertypes) auto-chained in ``tick``. ``_hierarchy_followup`` is the
    # method to fire on the prepared item; the final locations are parked
    # in ``_hierarchy`` (whose id is the prepare request's) and surfaced
    # through the references picker.
    var _hierarchy: _Slot[List[DefinitionResolved]]
    var _inflight_hier_followup_id: String
    var _hierarchy_followup: String
    var _hierarchy_word: String
    # ``textDocument/documentColor`` — per-color swatch ``Highlight``s
    # (truecolor bg) parked for the editor overlay.
    var _colors: _Slot[List[Highlight]]
    # ``textDocument/diagnostic`` — the pull-diagnostics model (LSP 3.17).
    # Servers that advertise ``diagnosticProvider`` don't push
    # ``publishDiagnostics``; we request a report per document instead.
    # Multiple pulls can be in flight at once — on session restore the host
    # opens N buffers and fires one pull per file in a single frame, so a
    # single slot would let all but the last response go unmatched (their
    # "analysing edits…" spinners then stick until the inflight timeout, and
    # their diagnostics never land). We track every outstanding request as an
    # index-aligned (id, path) pair; the parsed items land in the same
    # ``_diagnostic_buckets`` the push path uses. ``_pulled_paths`` records
    # every path we've requested so the host can fire the *initial* pull
    # exactly once per buffer (subsequent pulls are edit-driven).
    var _pull_diags: List[_IdText]   # (request id, path)
    var _pulled_paths: List[String]
    # ``textDocument/willSaveWaitUntil`` — the server returns a
    # ``TextEdit[]`` to apply before the buffer is written (e.g. organize
    # imports / final-newline). Parked like the formatting edits; the host
    # applies them then writes (see ``_drain_willsave``).
    var _willsave: _EditSlot
    # ``window/showMessageRequest`` — a server request that blocks until the
    # client replies with the chosen ``MessageActionItem`` (or null). We
    # park the message + action titles + the request id, surface a modal,
    # and reply via ``respond_message_request`` once the user picks.
    var _msgreq_pending: Bool
    var _msgreq_id: Optional[JsonValue]
    var _msgreq_message: String
    var _msgreq_actions: List[String]
    # ``window/showDocument`` — the server asks us to open a file (in an
    # editor, optionally at a selection) or an external URL. Parked for the
    # host to act on next frame; we reply ``success: true`` optimistically.
    var _show_doc_pending: Bool
    var _show_doc_uri: String
    var _show_doc_external: Bool
    var _show_doc_line: Int
    var _show_doc_char: Int
    # Server-driven ``workspace/applyEdit`` (e.g. after executeCommand):
    # the parsed WorkspaceEdit, parked for the host to apply project-wide.
    # We optimistically reply ``applied: true`` and apply next frame.
    var _resolved_applyedit: List[CodeActionFileEdit]
    var _has_resolved_applyedit: Bool
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
    var _stderr_log: CappedText
    # Rolling capture of the server's protocol-level log: ``window/
    # logMessage`` lines (prefixed by severity) and ``telemetry/event``
    # payloads, both of which the spec otherwise drops on the floor.
    # Surfaced in the LSP info window alongside stderr so a server that
    # explains a problem via logMessage (rather than crashing) is visible.
    # Capped at 16 KB like the stderr capture.
    var _log_capture: CappedText

    # Per-document tracking for didOpen / didChange.
    var _docs: List[_OpenDoc]

    # Queued ``(path, text)`` pairs waiting for ``initialized`` to land.
    var _pending_opens: List[_IdText]   # (path, text)

    # Latest published diagnostics keyed by URI-resolved path. The list
    # holds at most one bucket per path — a fresh publishDiagnostics
    # overwrites the prior bucket's list and resets ``consumed``.
    # ``take_diagnostics_for`` moves the list out, so a consumed bucket is
    # only a marker; ``notify_closed`` drops it. An *unconsumed* one stays
    # when its file closes (or was never open — a server publishing for
    # the whole workspace), so a reopen shows its squiggles at once; an
    # empty publish for a file that isn't open deletes the bucket instead
    # of parking an "all clear" nobody will read. What remains is bounded
    # by the files the server currently reports problems in.
    var _diagnostic_buckets: List[_DiagnosticBucket]

    # In-flight diagnostic refresh tracking, parallel-list per path:
    # set when ``_send_did_open`` / ``_send_did_change`` fires, cleared
    # when a matching ``publishDiagnostics`` arrives. Drives the status
    # bar's "analyzing edits…" spinner so the user can see why
    # squiggles haven't updated yet — distinguishes "server is slow"
    # from "no diagnostics for this code". ``_diag_inflight_versions``
    # holds the version we sent so a stale publishDiagnostics for an
    # earlier version doesn't clear the flag for a newer in-flight
    # change. ``_diag_inflight_since_ms`` is the wallclock at send
    # time so the status bar can render elapsed seconds.
    var _diag_inflight_paths: List[String]
    var _diag_inflight_versions: List[Int]
    var _diag_inflight_since_ms: List[Int]

    def __init__(out self):
        self.client = LspClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self._position_encoding = String("utf-16")
        self._position_encoding_tag = encoding_from_name(String("utf-16"))
        self._remap = _PositionRemapper(POS_UTF8)
        self._req_uris = List[_IdText]()
        self._awaited = List[_Awaited]()
        self._last_rx_ms = 0
        self._refresh_doc_features = False
        self._refresh_diagnostics = False
        self._close_stage = _CLOSE_IDLE
        self._close_deadline_ms = 0
        self._channel = 0
        self._session = 0
        self._pool = 0
        self._join_pending = False
        self._reply_muted = False
        self._close_shutdown_id = String("")
        self._init_id = String("")
        self._inflight_def_id = String("")
        self._inflight_word = String("")
        self._last_empty = False
        self._empty_word = String("")
        self._def_origin_path = String("")
        self._def_origin_line = 0
        self._def_origin_char = 0
        self._def_origin_word = String("")
        self._capabilities = Optional[JsonValue]()
        self._watches_files = False
        self._log_on = False
        self._log_checked_ms = -_LOG_RECHECK_MS
        self._nav = _Slot[Optional[DefinitionResolved]]()
        self._nav_word = String("")
        self._libprobes = List[_InflightProbe]()
        self._libprobe_done = List[LibraryProbe]()
        self._prepare_rename = _Slot[String]()
        self._prepare_rename_state = 0
        self._references = _Slot[List[DefinitionResolved]]()
        self._ref_word = String("")
        self._symbols = _Slot[List[SymbolItem]]()
        self._ws_symbols = _Slot[List[WorkspaceSymbolItem]]()
        self._completions = _Slot[List[CompletionItem]]()
        self._completion_manual = False
        self._inflight_resolve_id = String("")
        self._resolve_aux = List[TextEditEntry]()
        self._resolve_detail = String("")
        self._has_resolve_result = False
        self._hover = _Slot[String]()
        self._hover_row = 0
        self._hover_col = 0
        self._code_actions = _Slot[List[CodeAction]]()
        self._ca_resolve = _ResolveFanout()
        self._ca_accum = List[CodeAction]()
        self._ca_resolve_deadline_ms = 0
        self._rename = _Slot[List[CodeActionFileEdit]]()
        self._formatting = _EditSlot()
        self._ontype = _EditSlot()
        self._moniker = _Slot[String]()
        self._colorpres = _Slot[List[String]]()
        self._colorpres_edits = List[TextEditEntry]()
        self._colorpres_sl = 0
        self._colorpres_sc = 0
        self._colorpres_el = 0
        self._colorpres_ec = 0
        self._inlinecomp = _Slot[String]()
        self._inlinecomp_row = 0
        self._inlinecomp_col = 0
        self._linked = _EditSlot()
        self._inlineval = _EditSlot()
        self._inlineval_exprs = List[TextEditEntry]()
        self._folding = _EditSlot()
        self._doc_highlight = _EditSlot()
        self._signature = _Slot[String]()
        self._inlay = _EditSlot()
        self._codelens = _EditSlot()
        self._inflight_codelens_resolve_id = String("")
        self._codelens_resolve_queue = List[JsonValue]()
        self._codelens_resolve_row = 0
        self._codelens_accum = List[TextEditEntry]()
        self._doclinks = _EditSlot()
        self._dl_resolve = _ResolveFanout()
        self._dl_accum = List[TextEditEntry]()
        self._progress_note = String("")
        self._has_progress_note = False
        self._server_message = String("")
        self._has_server_message = False
        self._selrange = _EditSlot()
        self._hierarchy = _Slot[List[DefinitionResolved]]()
        self._inflight_hier_followup_id = String("")
        self._hierarchy_followup = String("")
        self._hierarchy_word = String("")
        self._colors = _Slot[List[Highlight]]()
        self._pull_diags = List[_IdText]()
        self._pulled_paths = List[String]()
        self._willsave = _EditSlot()
        self._msgreq_pending = False
        self._msgreq_id = Optional[JsonValue]()
        self._msgreq_message = String("")
        self._msgreq_actions = List[String]()
        self._show_doc_pending = False
        self._show_doc_uri = String("")
        self._show_doc_external = False
        self._show_doc_line = 0
        self._show_doc_char = 0
        self._resolved_applyedit = List[CodeActionFileEdit]()
        self._has_resolved_applyedit = False
        self._root_uri = String("")
        self._language_id = String("")
        self._argv = List[String]()
        self._docs = List[_OpenDoc]()
        self._pending_opens = List[_IdText]()
        self._diagnostic_buckets = List[_DiagnosticBucket]()
        self._diag_inflight_paths = List[String]()
        self._diag_inflight_versions = List[Int]()
        self._diag_inflight_since_ms = List[Int]()
        self._stderr_log = CappedText(_LOG_CAP, keep_tail=False)
        self._log_capture = CappedText(_LOG_CAP, keep_tail=False)

    def __copyinit__(mut self, copy: Self):
        # Honest copying would duplicate child PID + pipe FD ownership,
        # which leaks. We only declare ``Copyable`` so we can stash
        # managers in ``List[LspManager]``; the list is grown via ``^``
        # transfer and indexed through references in the methods that
        # mutate, so this branch never runs for a live manager. If it
        # ever does fire, it produces a fresh NOT_STARTED sibling — bad
        # but recoverable, rather than corrupting the original's state.
        # The fresh manager is exactly what ``__init__`` builds: one list of
        # field defaults, not two to keep in step.
        self = Self()

    def is_active(self) -> Bool:
        return self.state == _STATE_READY \
            or self.state == _STATE_INITIALIZING

    def is_ready(self) -> Bool:
        return self.state == _STATE_READY

    def position_encoding(self) -> String:
        """The negotiated LSP position encoding (``utf-8`` or ``utf-16``)."""
        return self._position_encoding

    def is_failed(self) -> Bool:
        return self.state == _STATE_FAILED

    def is_initializing(self) -> Bool:
        return self.state == _STATE_INITIALIZING

    def is_not_started(self) -> Bool:
        return self.state == _STATE_NOT_STARTED

    def inflight_word(self) -> String:
        return self._inflight_word

    def last_empty(self) -> Bool:
        return self._last_empty

    def take_empty_word(mut self) -> String:
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

    def clear_empty(mut self):
        """Drop the latched ``_last_empty`` flag. Host calls this after
        successfully handling an empty response some other way so the
        status bar stops claiming "no definition found"."""
        self._last_empty = False

    def language_id(self) -> String:
        return self._language_id

    def argv(self) -> List[String]:
        return self._argv.copy()

    def root_uri(self) -> String:
        return self._root_uri

    def captured_stderr(self) -> String:
        """Everything we've drained from the server's stderr since spawn,
        capped at 16 KB. Surfaced in the info window so the user can see
        what the server printed before exiting / hanging."""
        return self._stderr_log.text

    # --- diagnostics -------------------------------------------------------

    def has_unconsumed_diagnostics_for(self, path: String) -> Bool:
        """True iff a fresh publishDiagnostics for ``path`` has landed
        since the last ``take_diagnostics_for`` call. Lets the host
        avoid re-running the apply path every frame for buffers whose
        diagnostic set is unchanged."""
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path \
                    and not self._diagnostic_buckets[k].consumed:
                return True
        return False

    def take_diagnostics_for(mut self, path: String) -> List[Diagnostic]:
        """Return the latest published diagnostic list for ``path`` and
        mark the bucket consumed so the host doesn't re-apply on every
        frame. Returns an empty list when nothing has been published
        for ``path`` (or it was already consumed)."""
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                if self._diagnostic_buckets[k].consumed:
                    return List[Diagnostic]()
                # Moved, not copied: nothing reads a consumed bucket's list.
                var out = List[Diagnostic]()
                swap(out, self._diagnostic_buckets[k].diags)
                self._diagnostic_buckets[k].consumed = True
                return out^
        return List[Diagnostic]()

    def supports_pull_diagnostics(self) -> Bool:
        """True iff the server advertises ``diagnosticProvider`` — the LSP
        3.17 pull model. Such servers don't push ``publishDiagnostics``;
        the host must request a report per document via
        ``request_pull_diagnostics`` or no squiggles ever appear."""
        return self.server_supports(String("diagnosticProvider"))

    def has_pulled(self, path: String) -> Bool:
        """True once we've issued at least one ``textDocument/diagnostic``
        for ``path``. Lets the host fire the *initial* pull exactly once
        per buffer (later pulls are edit-driven)."""
        for k in range(len(self._pulled_paths)):
            if self._pulled_paths[k] == path:
                return True
        return False

    def request_pull_diagnostics(mut self, path: String) -> Bool:
        """Request a ``textDocument/diagnostic`` report for ``path`` (pull
        model). The parsed items land in the same diagnostic bucket the
        push path writes, so the host consumes them identically. Every
        outstanding request is tracked by (id, path) so a burst of pulls
        across many buffers (session restore opens N files in one frame)
        all match their responses — see ``_pull_diags``.
        No-op unless ready and the server advertises ``diagnosticProvider``;
        assumes the document is already open (caller pre-flights via the
        normal didOpen/didChange path)."""
        if self.state != _STATE_READY or not self.supports_pull_diagnostics():
            return False
        var params = self._doc_params(path)
        var req_id: String
        try:
            req_id = self._send_request(
                String("textDocument/diagnostic"), params,
            )
        except:
            return False
        # Drop any prior outstanding request for the same path — a newer
        # pull (edit-driven) supersedes it, and its response would just
        # overwrite the same bucket.
        self._drop_pull_diags(path)
        self._pull_diags.append(_IdText(req_id, path))
        if not self.has_pulled(path):
            self._pulled_paths.append(path)
        return True

    # --- lifecycle ---------------------------------------------------------

    def start_with(
        mut self, language_id: String, argv: List[String], root_path: String,
        pool: Int = 0, fresh: Bool = False,
    ):
        """Generic spawn: ``argv`` is the server command, ``language_id``
        is what we tag every ``didOpen``'d document with.

        Idempotent on a second call after a successful start. On failure
        latches to FAILED so we don't keep retrying every frame. Callers
        that want a multi-binary fallback should check ``which()``
        themselves before calling and only invoke this once they've
        picked an actually-installed binary.

        ``pool`` (an ``LspPool`` address, 0 = none) makes the server
        shareable: if another window already runs this exact server, join
        it as a second workspace folder instead of spawning (see
        ``lsp_shared.mojo``); otherwise spawn and offer it to the next one.
        ``fresh`` spawns even when one is running — LSP ▸ Restart, where
        joining the server being restarted would restart nothing.
        """
        if self.state != _STATE_NOT_STARTED:
            return
        self._language_id = language_id
        self._argv = argv.copy()
        self._pool = pool
        # Always give the server a workspace root: a project dir if the
        # host has one open, otherwise the editor's own cwd. Pyright and
        # friends key module resolution off ``rootUri``/``workspaceFolders``
        # and the child's cwd; leaving any of them blank causes silent
        # "module not found" failures on first didOpen.
        var resolved_root = root_path \
            if len(root_path.as_bytes()) > 0 else getcwd_path()
        self._root_uri = _path_to_uri(resolved_root) \
            if len(resolved_root.as_bytes()) > 0 else String("")
        if pool != 0 and not fresh:
            var shared = pool_at(pool)[].find(server_key(language_id, argv))
            if shared != 0 and not channel_at(shared)[].dead:
                self._channel = shared
                self._session = channel_at(shared)[].join(self._root_uri)
                self._join_pending = True
                self.state = _STATE_INITIALIZING
                return
        self._spawn_and_initialize(resolved_root)

    def _spawn_and_initialize(mut self, resolved_root: String):
        """Spawn the server and send ``initialize``: onto a new shared
        channel when there is a pool, else into the private ``client``."""
        var argv = self._argv.copy()
        var language_id = self._language_id
        var client: LspClient
        try:
            client = LspClient.spawn(argv, resolved_root)
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("spawn failed: ") + String(e)
            return
        # Enable wire trace if turbokod-lsp.log already exists (debug aid).
        var trace_path_str = debug_log_path(
            String("turbokod-lsp-wire-") + language_id + String(".log"),
        )
        var trace_info = stat_file(debug_log_path(String("turbokod-lsp.log")))
        if trace_info.ok:
            var trace_path = trace_path_str + String("\0")
            var tfd = external_call["creat", Int32](
                trace_path.unsafe_ptr(), Int32(0o644),
            )
            if Int(tfd) >= 0:
                client.process.own_trace_fd(tfd)
                var hdr = String("session start argv:")
                for k in range(len(argv)):
                    hdr = hdr + String(" ") + argv[k]
                client.process.trace(hdr)
        if self._pool != 0:
            var key = server_key(language_id, argv)
            var addr = new_channel(client^, key)
            if addr == 0:
                self.state = _STATE_FAILED
                self.failure_reason = String("out of memory")
                return
            self._channel = addr
            self._session = channel_at(addr)[].join(self._root_uri)
            pool_at(self._pool)[].add(key, addr)
        else:
            self.client = client^
        try:
            var ws_name = basename(resolved_root) \
                if len(resolved_root.as_bytes()) > 0 else String("")
            self._init_id = self._send_request(
                String("initialize"),
                lsp_initialize_params(self._root_uri, ws_name),
            )
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("initialize failed: ") + String(e)
            return
        self.state = _STATE_INITIALIZING

    # --- position encoding ------------------------------------------------

    def _from_wire(mut self, mut v: JsonValue, uri: String):
        """Convert wire units in an inbound payload to byte columns, in
        place. ``uri`` is the document the payload is implicitly about
        (the in-flight request's file) — positions carrying their own
        ``uri`` override it."""
        if self._position_encoding_tag == POS_UTF8:
            return
        self._remap.begin_walk()
        self._remap.walk(v, uri, True, self._docs)

    def _send_wire(
        mut self, method: String, params: JsonValue, is_request: Bool,
    ) raises -> String:
        """Send ``params`` with byte columns converted to the negotiated
        encoding — a copy only when there is something to convert."""
        if self._position_encoding_tag == POS_UTF8:
            return self._transport_send(method, params, is_request)
        var wire = params.copy()
        self._remap.begin_walk()
        self._remap.walk(wire, String(""), False, self._docs)
        return self._transport_send(method, wire, is_request)

    def _transport_send(
        mut self, method: String, wire: JsonValue, is_request: Bool,
    ) raises -> String:
        if self._channel != 0:
            if is_request:
                return channel_at(self._channel)[].send_request(
                    self._session, method, wire,
                )
            channel_at(self._channel)[].send_notification(
                self._session, method, wire,
            )
            return String("")
        if is_request:
            return self.client.send_request(method, wire)
        self.client.send_notification(method, wire)
        return String("")

    def _request(mut self, method: String, params: JsonValue) -> String:
        """``_send_request`` for a caller that only needs to know whether it
        went out: the request id, or empty when the send failed."""
        try:
            return self._send_request(method, params)
        except:
            return String("")

    def _send_request(
        mut self, method: String, params: JsonValue,
    ) raises -> String:
        """Every outbound request funnels through here so byte columns are
        converted to the negotiated encoding exactly once, and so the
        request's document is remembered for remapping the response."""
        var uri = String("")
        var tdi = params.object_index(String("textDocument"))
        if tdi >= 0:
            uri = json_get_string(params.obj_v[tdi].value, String("uri"))
        var id = self._send_wire(method, params, True)
        if len(id.as_bytes()) > 0:
            if len(self._awaited) >= _AWAITED_MAX:
                _ = self._awaited.pop(0)
            self._awaited.append(_Awaited(id, monotonic_ms()))
        # Only a non-utf-8 encoding remaps responses (see the dispatch's
        # ``_take_req_uri``), so under utf-8 there's nothing to remember.
        if self._position_encoding_tag != POS_UTF8 \
                and len(uri.as_bytes()) > 0 and len(id.as_bytes()) > 0:
            self._req_uris.append(_IdText(id, uri^))
            while len(self._req_uris) > _REQ_URI_RING:
                _ = self._req_uris.pop(0)
        return id^

    def _take_req_uri(mut self, id: String) -> String:
        """The document URI recorded for ``id``, consuming the entry.
        Empty when unknown — the walk then relies on URIs carried in the
        payload itself and leaves positionless-context values alone."""
        for i in range(len(self._req_uris)):
            if self._req_uris[i].key == id:
                return self._req_uris.pop(i).text
        return String("")

    def _settle_awaited(mut self, id: String):
        """``id`` is no longer owed an answer: it came, or we cancelled
        the request (a server may answer a cancelled one or not)."""
        for i in range(len(self._awaited)):
            if self._awaited[i].id == id:
                _ = self._awaited.pop(i)
                return

    def unresponsive_secs(self) -> Int:
        """Whole seconds the server has been silent with a request
        waiting, once that passes ``_UNRESPONSIVE_MS``; -1 otherwise.

        Counted from the oldest unanswered request sent *after* the
        server's last message, so a request it simply never answers
        doesn't count while it keeps talking — only silence does."""
        if self.state != _STATE_READY:
            return -1
        for i in range(len(self._awaited)):
            if self._awaited[i].sent_ms < self._last_rx_ms:
                continue
            var waited = monotonic_ms() - self._awaited[i].sent_ms
            if waited >= _UNRESPONSIVE_MS:
                return waited // 1000
            return -1
        return -1

    def is_unresponsive(self) -> Bool:
        return self.unresponsive_secs() >= 0

    def _send_notification(mut self, method: String, params: JsonValue) raises:
        """Outbound-notification twin of ``_send_request``."""
        _ = self._send_wire(method, params, False)

    def _notify(mut self, method: String, params: JsonValue, context: String):
        """``_send_notification`` for a fire-and-forget notification: a
        failed send is printed (with ``context``, say the path) and
        otherwise dropped."""
        try:
            self._send_notification(method, params)
        except e:
            print("lsp:", method, context, ":", String(e))

    # --- transport: the private client, or a session on a shared channel --

    def _logging(mut self) -> Bool:
        """Whether debug logging is on — ``_lsp_debug_enabled`` re-asked at
        most once per ``_LOG_RECHECK_MS``, so touching or deleting the log
        file still takes effect within a second."""
        var now = monotonic_ms()
        if now - self._log_checked_ms >= _LOG_RECHECK_MS:
            self._log_on = _lsp_debug_enabled()
            self._log_checked_ms = now
        return self._log_on

    def _log_server_request(
        mut self, method: String, id_label: String, note: String,
    ):
        """Log a request the server sent us, with what we made of it."""
        if self._logging():
            _lsp_debug_write(
                String("← server request ") + method + String(" id=")
                + id_label + note,
            )

    def _log_response(mut self, what: String, id: String, label: String, n: Int):
        """Log a response the way every slot does: what it answered, its
        id, and one count. Nothing is built while logging is off."""
        if self._logging():
            _lsp_debug_write(
                String("← ") + what + String(" response id=") + id
                + String(" lang=") + self._language_id
                + String(" ") + label + String("=") + String(n),
            )

    def is_shared(self) -> Bool:
        """True while this manager is a session on a shared channel."""
        return self._channel != 0

    def _poll(mut self) raises -> Optional[LspIncoming]:
        """The next message for this manager. On a shared channel that is
        this session's inbox, and a replay (``_reply_muted``) is one some
        other session answers."""
        if self._channel == 0:
            self._reply_muted = False
            return self.client.poll(Int32(0))
        var replay = False
        var got = channel_at(self._channel)[].pop(self._session, replay)
        self._reply_muted = replay
        return got^

    def _reply(mut self, id: JsonValue, result: JsonValue) raises:
        if self._reply_muted:
            return
        if self._channel != 0:
            channel_at(self._channel)[].client.send_response(id, result)
        else:
            self.client.send_response(id, result)

    def _reply_error(mut self, id: JsonValue, code: Int, message: String) raises:
        if self._reply_muted:
            return
        if self._channel != 0:
            channel_at(self._channel)[].client.send_error(id, code, message)
        else:
            self.client.send_error(id, code, message)

    def _transport_alive(self) -> Bool:
        if self._channel != 0:
            var ch = channel_at(self._channel)
            return not ch[].dead and ch[].client.process.alive \
                and ch[].client.process.pid > 0
        return self.client.process.alive and self.client.process.pid > 0

    def _pump_writes(mut self):
        if self._channel != 0:
            channel_at(self._channel)[].client.process.pump_writes()
        else:
            self.client.process.pump_writes()

    def _write_overflowed(self) -> Bool:
        if self._channel != 0:
            return channel_at(self._channel)[].client.process.write_overflowed()
        return self.client.process.write_overflowed()

    def _reaped(mut self) -> Bool:
        """True once the server process has exited (every session of a
        shared one sees it, not just whichever reaped it)."""
        if self._channel != 0:
            return not channel_at(self._channel)[].check_alive()
        return self.client.process.try_reap()

    def _complete_join(mut self):
        """Finish joining a shared channel once its ``initialize`` result
        is in: add this root as a workspace folder and adopt the result
        (capabilities, position encoding) as if this session had asked.
        A server that can't add folders, or one that died, sends this
        manager off to spawn its own."""
        var ch = channel_at(self._channel)
        if not ch[].check_alive():
            self._fall_back_to_private()
            return
        if not ch[].init_result:
            return
        if not ch[].supports_folder_changes():
            self._fall_back_to_private()
            return
        var init = ch[].init_result.value().copy()
        try:
            ch[].change_folders(self._root_uri, String(""))
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("joining shared server failed: ") \
                + String(e)
            return
        self._join_pending = False
        # Sends ``initialized`` (the channel drops it — the first session
        # sent it) and the didOpens queued while waiting.
        self._on_initialize_response(init)
        # Capabilities registered before we joined.
        var regs = ch[].registrations()
        self._reply_muted = True
        for i in range(len(regs)):
            self._handle_server_request(regs[i])
        self._reply_muted = False

    def _fall_back_to_private(mut self):
        _ = channel_at(self._channel)[].leave(self._session)
        self._channel = 0
        self._session = 0
        self._join_pending = False
        var pool = self._pool
        self._pool = 0
        self._spawn_and_initialize(_uri_to_path(self._root_uri))
        self._pool = pool

    def shutdown(mut self):
        """Close the session, blocking until the handshake finishes.

        The blocking wrapper over ``begin_shutdown`` / ``shutdown_poll`` /
        ``finish_shutdown``. Use it where there is no "later" to drain in —
        the terminal frontend (the process is exiting) and tests. The native
        frontend uses the poll form instead so a window closes instantly.
        Idempotent."""
        if self.state == _STATE_NOT_STARTED:
            return
        self.begin_shutdown()
        while not self.shutdown_poll():
            sleep_ms(_SHUTDOWN_POLL_MS)
        self.finish_shutdown()

    def begin_shutdown(mut self):
        """Start the spec close handshake without waiting for it.

        Sends the ``shutdown`` request and returns. The caller then polls
        ``shutdown_poll`` until it reports done and calls
        ``finish_shutdown``; nothing here blocks, so a window can close
        while its servers are still winding down.

        Why bother at all rather than going straight to SIGTERM: the spec
        sequence is ``shutdown`` → response → ``exit``, and servers use it.
        rust-analyzer and jdtls flush caches and workspace state on the way
        out, and killing them mid-flush makes the *next* session re-index or
        start from a partially-written cache.
        """
        if self.state == _STATE_NOT_STARTED:
            self._close_stage = _CLOSE_DONE
            return
        if self._close_stage != _CLOSE_IDLE:
            return   # already closing
        if self._channel != 0:
            var ch = channel_at(self._channel)
            if ch[].session_count() > 1:
                # Other windows still use this server: hand back our
                # folder and documents, and leave it running.
                self._leave_shared_channel()
                self._close_stage = _CLOSE_DONE
                return
            # The last session closes it for real — but stop offering it
            # first, so nobody joins a server that is saying goodbye.
            if self._pool != 0:
                pool_at(self._pool)[].forget(self._channel)
        if not self._transport_alive():
            self._close_stage = _CLOSE_DONE
            return
        var shutdown_id: String
        try:
            shutdown_id = self._send_request(
                String("shutdown"), json_null(),
            )
        except:
            # Couldn't even write the request — the server isn't reading
            # stdin, so nothing graceful is possible. Let the terminate in
            # ``finish_shutdown`` deal with it.
            self._close_stage = _CLOSE_DONE
            return
        self._close_shutdown_id = shutdown_id^
        self._close_stage = _CLOSE_AWAIT_RESPONSE
        self._close_deadline_ms = monotonic_ms() + _SHUTDOWN_RESPONSE_MS

    def shutdown_poll(mut self) -> Bool:
        """Advance the close handshake. True once the transport can be torn
        down — the child exited, or its budget elapsed and it has a SIGTERM
        coming from ``finish_shutdown``.

        Safe to call at any rate; the budgets are wall-clock deadlines, so
        polling more often doesn't shorten the grace period and polling less
        often doesn't extend it past the next call."""
        if self._close_stage == _CLOSE_DONE or self._close_stage == _CLOSE_IDLE:
            return True
        if self._reaped():
            self._close_stage = _CLOSE_DONE
            return True
        var now = monotonic_ms()
        if self._close_stage == _CLOSE_AWAIT_RESPONSE:
            var acked = False
            # Drain whatever is queued. A server may flush a backlog of
            # notifications ahead of its shutdown response, so read until the
            # pipe is empty rather than giving up after one message.
            for _ in range(64):
                var maybe: Optional[LspIncoming]
                try:
                    maybe = self._poll()
                except:
                    self._close_stage = _CLOSE_DONE
                    return True
                if not maybe:
                    break
                var inc = maybe.take()
                if inc.kind == LSP_RESPONSE and inc.id \
                        and json_rpc_id(inc.id.value()) \
                            == self._close_shutdown_id:
                    acked = True
                    break
            if not acked and now < self._close_deadline_ms:
                return False
            # Send ``exit`` whether or not the response arrived: an
            # unacknowledged shutdown is still better followed by exit than
            # by an immediate signal, and a server that ignores both gets
            # SIGTERM from ``finish_shutdown`` anyway.
            try:
                self._send_notification(String("exit"), json_null())
            except:
                self._close_stage = _CLOSE_DONE
                return True
            self._close_stage = _CLOSE_AWAIT_EXIT
            self._close_deadline_ms = monotonic_ms() + _SHUTDOWN_EXIT_MS
            return False
        # _CLOSE_AWAIT_EXIT: the reap check at the top is what completes
        # this; here we only enforce the budget.
        if now >= self._close_deadline_ms:
            self._close_stage = _CLOSE_DONE
            return True
        return False

    def finish_shutdown(mut self):
        """Tear down the transport once ``shutdown_poll`` reports done.

        ``terminate`` closes the pipe fds and drops the outbound queue even
        when the child already exited cleanly — a graceful exit clears
        ``alive``, so the kill and reap steps are skipped and only the fd
        cleanup runs. A child that ignored ``exit`` gets its SIGTERM here."""
        if self._channel != 0:
            var addr = self._channel
            channel_at(addr)[].client.terminate()
            _ = channel_at(addr)[].leave(self._session)
            if self._pool != 0:
                pool_at(self._pool)[].forget(addr)
            free_channel(addr)
            self._channel = 0
            self._session = 0
            self._join_pending = False
        else:
            self.client.terminate()
        self.state = _STATE_NOT_STARTED
        self._close_stage = _CLOSE_IDLE
        self._close_shutdown_id = String("")
        self._close_deadline_ms = 0

    def _leave_shared_channel(mut self):
        """Detach from a shared channel others still use: close our
        documents and remove our folder (when the server got as far as
        knowing about either), then drop the session."""
        var ch = channel_at(self._channel)
        if not self._join_pending and Bool(ch[].init_result) \
                and ch[].check_alive():
            for ref d in self._docs:
                var params = json_object()
                params.put_owned(String("textDocument"), self._text_doc(d.path))
                try:
                    self._send_notification(
                        String("textDocument/didClose"), params,
                    )
                except:
                    break
            try:
                ch[].change_folders(String(""), self._root_uri)
            except:
                pass
        _ = ch[].leave(self._session)
        self._channel = 0
        self._session = 0
        self._join_pending = False
        self.state = _STATE_NOT_STARTED

    def is_closing(self) -> Bool:
        """True while a close handshake is in progress."""
        return self._close_stage == _CLOSE_AWAIT_RESPONSE \
            or self._close_stage == _CLOSE_AWAIT_EXIT

    # --- document lifecycle -----------------------------------------------

    def notify_opened(mut self, path: String, var text: String):
        """Tell the server about a newly opened editor for ``path``.

        Queues until the server is READY. A second open of the same path
        bumps the version and resends as didChange (unusual but harmless —
        keeps the server's view consistent if a window is closed and the
        same file reopened).
        """
        if self.state == _STATE_FAILED or self.state == _STATE_NOT_STARTED:
            return
        if self.state == _STATE_INITIALIZING:
            self._pending_opens.append(_IdText(path, text^))
            return
        self._send_open_or_change(path, text^)

    def notify_changed(mut self, path: String, var text: String):
        """Send a didChange for ``path`` carrying the latest buffer
        text. No-op when the server isn't READY — for INITIALIZING the
        pending didOpen will eventually deliver some snapshot, and the
        next post-READY tick will resend the *current* text via this
        path, so the server's view converges to the live buffer
        regardless of timing."""
        if self.state != _STATE_READY:
            return
        self._send_open_or_change(path, text^)

    def notify_saved(mut self, path: String, var text: String):
        """Send ``textDocument/didSave`` for ``path``. No-op unless the
        server is READY and we already opened the document — some
        servers run save-triggered passes (extra diagnostics, build
        steps) that only fire on this notification. ``includeText`` is
        sent only when the server advertised ``save.includeText`` in
        its sync capability; most want just the URI."""
        if self.state != _STATE_READY:
            return
        if self._doc_index(path) < 0:
            return
        var params = self._doc_params(path)
        if self.save_includes_text():
            params.put(String("text"), json_str(text^))
        self._notify(String("textDocument/didSave"), params, path)

    def notify_closed(mut self, path: String):
        """Send ``textDocument/didClose`` and forget the document so a
        later reopen re-sends ``didOpen`` (version resetting to 1)
        rather than ``didChange``. Without this the server keeps the
        buffer's state pinned for the whole session — closing 50 files
        leaves the server thinking all 50 are still open. Also drops it
        from the pending-open queue so a close that races ahead of the
        handshake never opens it at all."""
        if self.state == _STATE_FAILED or self.state == _STATE_NOT_STARTED:
            return
        if self.state == _STATE_INITIALIZING:
            var j = 0
            while j < len(self._pending_opens):
                if self._pending_opens[j].key == path:
                    _ = self._pending_opens.pop(j)
                else:
                    j += 1
            return
        var idx = self._doc_index(path)
        if idx < 0:
            return
        var closed = self._docs.pop(idx)
        self._remap.invalidate(path)
        # A consumed bucket is only a marker (its list went to the editor),
        # and a pull answered after the close would just park a report
        # nobody reads: drop both. An unconsumed bucket stays for a reopen.
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                if self._diagnostic_buckets[k].consumed:
                    _ = self._diagnostic_buckets.pop(k)
                break
        self._drop_pull_diags(path)
        # Drop any "analyzing edits…" spinner state — a closed buffer
        # must not keep one spinning.
        self._clear_diag_inflight(path, 0)
        # Re-arm the initial pull: a reopen sends a fresh didOpen of what
        # may be different text (changed on disk while closed), and
        # without this ``has_pulled`` stayed true, so the reopened buffer
        # showed the old report until its first edit.
        for k in range(len(self._pulled_paths)):
            if self._pulled_paths[k] == path:
                _ = self._pulled_paths.pop(k)
                break
        var params = json_object()
        var td = json_object()
        td.put_owned(String("uri"), json_str(closed.uri))
        params.put_owned(String("textDocument"), td^)
        self._notify(String("textDocument/didClose"), params, path)

    def notify_watched_changed(mut self, path: String, change_type: Int):
        """Send ``workspace/didChangeWatchedFiles`` for one on-disk change
        (``change_type``: 1=created, 2=changed, 3=deleted). The single-file
        shape the save path uses; see ``notify_watched_changes``."""
        var paths = List[String]()
        paths.append(path)
        var types = List[Int]()
        types.append(change_type)
        self.notify_watched_changes(paths, types)

    def notify_watched_changes(
        mut self, paths: List[String], types: List[Int],
    ):
        """Send one ``workspace/didChangeWatchedFiles`` carrying every
        ``(paths[i], types[i])`` pair (``types``: 1=created, 2=changed,
        3=deleted), but only when ready and the server actually
        registered a watcher. Lets servers re-index files that changed
        outside an open buffer — a saved ``Cargo.toml``, a sibling module
        the buffer imports, or the hundreds of files a branch switch
        rewrote (the host's git poll batches those into one call rather
        than one notification per file). We don't model the registered
        glob patterns, so a watcher may receive events for paths outside
        its set; that's spec-legal (servers ignore paths they don't
        track) and far cheaper than mirroring the matcher."""
        if self.state != _STATE_READY or not self._watches_files \
                or len(paths) == 0:
            return
        self._notify(
            String("workspace/didChangeWatchedFiles"),
            _watched_changes_params(paths, types),
            String(len(paths)) + String(" changes"),
        )

    def notify_configuration_changed(mut self):
        """Send ``workspace/didChangeConfiguration`` so the server knows
        its settings may have changed and re-reads them. Servers that use
        push-configuration read the ``settings`` payload directly; the
        more common pull-configuration servers ignore it and re-issue
        ``workspace/configuration`` (which ``_handle_server_request``
        answers). We carry an empty ``settings`` object — the host doesn't
        push per-server settings blobs, it only answers the pull — so this
        is purely the "go re-pull" kick. No-op until ready."""
        if self.state != _STATE_READY:
            return
        var params = json_object()
        params.put(String("settings"), json_object())
        self._notify(
            String("workspace/didChangeConfiguration"), params, String(""),
        )

    def _server_wants_file_op(self, key: String) -> Bool:
        """True iff the server advertised ``workspace.fileOperations.<key>``
        (``didCreate`` / ``didRename`` / ``didDelete``). A boolean ``true``
        or a registration-options object both count."""
        var v = self._cap_at(
            String("workspace"), String("fileOperations"), key,
        )
        if not v:
            return False
        if v.value().is_bool():
            return v.value().as_bool()
        return v.value().is_object()

    def server_wants_did_rename(self) -> Bool:
        """True iff the server wants ``workspace/didRenameFiles``. This is
        the one that actually changes behavior for the user: pyright and
        typescript-language-server rewrite every import of a renamed module
        when they get it, and do nothing at all when they don't."""
        return self._server_wants_file_op(String("didRename"))

    def server_wants_did_delete(self) -> Bool:
        """True iff the server wants ``workspace/didDeleteFiles`` — so it can
        drop the file from its index instead of holding stale symbols for a
        path that no longer exists."""
        return self._server_wants_file_op(String("didDelete"))

    def server_wants_did_create(self) -> Bool:
        """True iff the server wants ``workspace/didCreateFiles`` — so it can
        index a newly-created file and fix up imports referring to it."""
        return self._server_wants_file_op(String("didCreate"))

    def notify_did_create_files(mut self, path: String):
        """Send ``workspace/didCreateFiles`` for one newly-created file, but
        only when ready and the server registered interest. We don't model
        the registered glob filters — a server still receives events for
        paths outside its set, which it ignores (spec-legal)."""
        if self.state != _STATE_READY or not self.server_wants_did_create():
            return
        self._notify_file_op(String("workspace/didCreateFiles"), path)

    def _notify_file_op(mut self, method: String, path: String):
        """Send a one-file ``workspace/didCreateFiles`` / ``didDeleteFiles``."""
        var f = json_object()
        f.put(String("uri"), json_str(_path_to_uri(path)))
        var files = json_array()
        files.append(f)
        var params = json_object()
        params.put(String("files"), files)
        self._notify(method, params, path)

    def notify_did_rename_files(mut self, old_path: String, new_path: String):
        """Send ``workspace/didRenameFiles`` for one rename.

        This is the file operation that changes what the user sees: pyright
        and typescript-language-server rewrite every import of a renamed
        module on this notification, and without it a rename in the file tree
        silently leaves the project full of imports pointing at the old name.

        Fire-and-forget, and gated on the server advertising interest. Like
        ``didCreateFiles`` we don't model the registered glob filters — a
        server may receive an event for a path outside its set and ignore it,
        which is spec-legal."""
        if self.state != _STATE_READY or not self.server_wants_did_rename():
            return
        var params = json_object()
        var files = json_array()
        var f = json_object()
        f.put(String("oldUri"), json_str(_path_to_uri(old_path)))
        f.put(String("newUri"), json_str(_path_to_uri(new_path)))
        files.append(f)
        params.put(String("files"), files)
        self._notify(String("workspace/didRenameFiles"), params, old_path)

    def notify_did_delete_files(mut self, path: String):
        """Send ``workspace/didDeleteFiles`` for one deleted file or
        directory, so the server drops it from its index instead of holding
        stale symbols for a path that no longer exists (which then surface in
        Find Symbol and go-to-definition as jumps into nothing)."""
        if self.state != _STATE_READY or not self.server_wants_did_delete():
            return
        self._notify_file_op(String("workspace/didDeleteFiles"), path)

    def notify_will_save(mut self, path: String, reason: Int):
        """Send ``textDocument/willSave`` (``reason``: 1=manual, 2=after-
        delay, 3=focus-out) so the server can react before the buffer is
        written. Fire-and-forget; no-op unless ready and the server set
        ``textDocumentSync.willSave``."""
        if self.state != _STATE_READY or not self.server_supports_will_save():
            return
        var params = self._doc_params(path)
        params.put(String("reason"), json_int(reason))
        self._notify(String("textDocument/willSave"), params, path)

    def request_will_save_wait_until(
        mut self, path: String, reason: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/willSaveWaitUntil`` and park the returned
        ``TextEdit[]`` for the host to apply *before* writing the file
        (organize-imports / final-newline style edits). Pre-flights the
        about-to-be-saved text via didChange. No-op unless ready and the
        server set ``textDocumentSync.willSaveWaitUntil``."""
        if self.state != _STATE_READY \
                or not self.server_supports_will_save_wait_until():
            return False
        self._willsave.text = text.copy()
        self._send_open_or_change(path, text^)
        var params = self._doc_params(path)
        params.put(String("reason"), json_int(reason))
        return self._willsave.start(
            self._request_replacing(
                self._willsave.id.copy(),
                String("textDocument/willSaveWaitUntil"), params,
            ),
            path,
        )

    def has_pending_willsave(self) -> Bool:
        return self._willsave.ready

    def pending_willsave_path(self) -> String:
        return self._willsave.path

    def pending_willsave_text(self) -> String:
        """The buffer text the pending willSaveWaitUntil was made against."""
        return self._willsave.text

    def take_willsave_edits(mut self) -> List[TextEditEntry]:
        return self._willsave.take()

    def request_definition(
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
        if self._logging():
            _lsp_debug_write(
                String("→ request_definition lang=") + self._language_id
                + String(" path=") + path
                + String(" line=") + String(line)
                + String(" character=") + String(character)
                + String(" word=") + word
                + String(" text_len=") + String(len(text.as_bytes())),
            )
        self._send_open_or_change(path, text^)
        var params = self._position_params(path, line, character)
        self._inflight_def_id = self._request(String("textDocument/definition"), params)
        if len(self._inflight_def_id.as_bytes()) == 0:
            return False
        self._def_origin_path = path
        self._def_origin_line = line
        self._def_origin_char = character
        self._def_origin_word = word.copy()
        self._inflight_word = word^
        self._last_empty = False
        return True

    def definition_origin_path(self) -> String:
        return self._def_origin_path

    def definition_origin_line(self) -> Int:
        return self._def_origin_line

    def definition_origin_char(self) -> Int:
        return self._def_origin_char

    def definition_origin_word(self) -> String:
        return self._def_origin_word

    # --- server capability queries ----------------------------------------

    def _cap_at(self, *path: String) -> Optional[JsonValue]:
        """The value at ``capabilities.<path[0]>.<path[1]>…`` of the
        initialize response, or empty when any step is absent or not an
        object. Every capability probe walks through here."""
        if not self._capabilities:
            return None
        # Borrow down the path and copy only the leaf: probes run per
        # frame, and copying the whole capabilities tree per step was the
        # cost.
        var keys = List[String]()
        for i in range(len(path)):
            keys.append(path[i])
        return _json_at_path(self._capabilities.value(), keys, 0)

    def _cap_bool(self, a: String, b: String, c: String = String("")) -> Bool:
        """``capabilities.a.b[.c]`` when it's a boolean; False otherwise."""
        var v = self._cap_at(a, b) if len(c.as_bytes()) == 0 \
            else self._cap_at(a, b, c)
        return Bool(v) and v.value().is_bool() and v.value().as_bool()

    def server_supports(self, key: String) -> Bool:
        """True iff the server advertised the capability named ``key`` in
        its initialize response (e.g. ``implementationProvider``,
        ``documentFormattingProvider``, ``inlayHintProvider``). A boolean
        ``true`` or any registration-options object/string counts as
        supported; absent or ``false`` counts as unsupported."""
        var v = self._cap_at(key)
        if not v:
            return False
        if v.value().is_bool():
            return v.value().as_bool()
        return v.value().is_object() or v.value().is_string() \
            or v.value().is_array()

    def server_supports_prepare_rename(self) -> Bool:
        """True iff ``renameProvider`` is an object with
        ``prepareProvider: true`` — i.e. the server implements
        ``textDocument/prepareRename``. Plain ``renameProvider: true``
        means rename works but prepare does not."""
        return self._cap_bool(
            String("renameProvider"), String("prepareProvider"),
        )

    def save_includes_text(self) -> Bool:
        """True iff the server's ``textDocumentSync.save`` is an object
        with ``includeText: true`` — i.e. it wants the full buffer text
        on ``didSave``. A plain ``save: true`` (or an int sync kind)
        means notify-only, so we send just the URI."""
        return self._cap_bool(
            String("textDocumentSync"), String("save"), String("includeText"),
        )

    def _text_sync_bool(self, key: String) -> Bool:
        """Read a boolean flag (``willSave`` / ``willSaveWaitUntil``) off
        the object form of ``textDocumentSync``. The int / absent forms
        mean the feature is unsupported."""
        return self._cap_bool(String("textDocumentSync"), key)

    def server_supports_will_save(self) -> Bool:
        """True iff ``textDocumentSync.willSave`` — the server wants a
        ``textDocument/willSave`` notification before each save."""
        return self._text_sync_bool(String("willSave"))

    def server_supports_will_save_wait_until(self) -> Bool:
        """True iff ``textDocumentSync.willSaveWaitUntil`` — the server can
        return edits to apply *before* the buffer is written."""
        return self._text_sync_bool(String("willSaveWaitUntil"))

    def server_supports_completion_resolve(self) -> Bool:
        """True iff ``completionProvider.resolveProvider`` is ``true`` —
        the server fills in ``detail`` / ``documentation`` /
        ``additionalTextEdits`` (auto-imports) only on a follow-up
        ``completionItem/resolve``. When false, the initial completion
        list is already complete and we never resolve."""
        return self._cap_bool(
            String("completionProvider"), String("resolveProvider"),
        )

    def server_supports_code_action_resolve(self) -> Bool:
        """True iff ``codeActionProvider.resolveProvider`` — the server
        returns actions carrying only a ``title`` + ``data`` and fills in the
        ``edit`` on a ``codeAction/resolve`` round-trip.

        This is rust-analyzer's default shape. Without the round-trip its
        actions arrive with no edit and no command, the host filters them out
        as inapplicable, and the user sees an empty quick-fix menu on a
        buffer full of fixable diagnostics."""
        return self._cap_bool(
            String("codeActionProvider"), String("resolveProvider"),
        )

    # --- navigate-to-location (typeDefinition / implementation / declaration)

    def request_navigation(
        mut self, method: String, path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        """Send a definition-shaped jump request for ``method`` (one of
        ``textDocument/typeDefinition`` / ``implementation`` /
        ``declaration``). Pre-flights with didOpen/didChange and parks the
        resolved target for the host to ``take_nav_target`` and jump to.
        Kept separate from ``request_definition`` so it never trips the
        cmd-click → references chaining."""
        if self.state != _STATE_READY:
            return False
        if self._logging():
            _lsp_debug_write(
                String("→ request_navigation ") + method
                + String(" lang=") + self._language_id
                + String(" line=") + String(line)
                + String(" character=") + String(character),
            )
        self._send_open_or_change(path, text^)
        var params = self._position_params(path, line, character)
        var sent = self._request_replacing(self._nav.id.copy(), method, params)
        if not self._nav.start(sent):
            return False
        self._nav_word = word^
        return True

    def has_pending_nav(self) -> Bool:
        """True iff a navigation response is parked. The parked target may
        still be empty (server found nothing) — distinguish via
        ``take_nav_target`` returning None."""
        return self._nav.ready

    def nav_word(self) -> String:
        return self._nav_word

    def take_nav_target(mut self) -> Optional[DefinitionResolved]:
        """Move out the parked navigation target (None if the server
        returned no location). Clears the pending flag either way."""
        var out = self._nav.take()
        return out^

    # --- library-word probe ----------------------------------------------

    def request_library_probe(
        mut self, path: String, line: Int, character: Int,
        var word: String, var text: String, tag: Int, limit: Int = 1,
    ) -> Bool:
        """Ask for the definition of ``word`` at ``(line, character)``
        in the background, to learn whether it's a library symbol.
        ``tag`` comes back with the answer (who asked). False while
        ``limit`` probes are already in flight or the server isn't
        ready."""
        if self.state != _STATE_READY or len(self._libprobes) >= limit:
            return False
        self._send_open_or_change(path, text^)
        var params = self._position_params(path, line, character)
        var id: String
        try:
            id = self._send_request(String("textDocument/definition"), params)
        except:
            return False
        self._libprobes.append(_InflightProbe(id^, word^, tag, monotonic_ms()))
        return True

    def library_probes_inflight(self) -> Int:
        return len(self._libprobes)

    def library_probes_inflight_tagged(self, tag: Int) -> Int:
        var n = 0
        for ref p in self._libprobes:
            if p.tag == tag:
                n += 1
        return n

    def has_library_probe(self) -> Bool:
        """True iff a probe's answer is parked."""
        return len(self._libprobe_done) > 0

    def take_library_probe(mut self) -> LibraryProbe:
        """Move out the oldest parked answer."""
        return self._libprobe_done.pop(0)

    def _expire_library_probes(mut self):
        """Give up on probes the server hasn't answered in time, so a
        wedged server can't stall Project ▸ Spelling's library check."""
        var now = monotonic_ms()
        var i = 0
        while i < len(self._libprobes):
            if now - self._libprobes[i].sent_ms < _LIBPROBE_TIMEOUT_MS:
                i += 1
                continue
            var p = self._libprobes.pop(i)
            self._libprobe_done.append(LibraryProbe(
                p.word, Optional[DefinitionResolved](), p.tag, False,
            ))

    def _libprobe_slot(self, id: String) -> Int:
        for i in range(len(self._libprobes)):
            if self._libprobes[i].id == id:
                return i
        return -1

    def _drop_pull_diags(mut self, path: String):
        """Forget the pull-diagnostic requests outstanding for ``path`` (a
        newer pull supersedes them; a close makes them moot)."""
        var k = 0
        while k < len(self._pull_diags):
            if self._pull_diags[k].text == path:
                _ = self._pull_diags.pop(k)
            else:
                k += 1

    # --- prepareRename ----------------------------------------------------

    def request_prepare_rename(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/prepareRename`` to validate the symbol at
        ``(line, character)`` and fetch its placeholder before prompting.
        Parks a tri-state result drained via ``take_prepare_rename``."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        var sent = self._request_replacing(
            self._prepare_rename.id.copy(),
            String("textDocument/prepareRename"), params,
        )
        if not self._prepare_rename.start(sent):
            return False
        self._prepare_rename_state = 0
        return True

    def has_pending_prepare_rename(self) -> Bool:
        return self._prepare_rename.ready

    def take_prepare_rename(mut self) -> Tuple[Int, String]:
        """Return ``(state, placeholder)`` and clear the pending flag.
        ``state``: 0 unsupported/error, 1 renameable, 2 not renameable."""
        var st = self._prepare_rename_state
        var ph = self._prepare_rename.take()
        self._prepare_rename_state = 0
        return (st, ph^)

    def request_references(
        mut self, path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        """Ask the server for ``textDocument/references`` at
        ``(line, character)``.

        Mirrors ``request_definition`` — pre-flights with didOpen/didChange
        and parks an inflight id for the tick loop to drain. Asks the
        server to include the declaration in the result set: when the user
        cmd+clicks at the definition site we want every site (including
        the definition itself, which the user is presumably about to leave)
        so the picker can offer all of them.
        """
        if self.state != _STATE_READY:
            return False
        if self._logging():
            _lsp_debug_write(
                String("→ request_references lang=") + self._language_id
                + String(" path=") + path
                + String(" line=") + String(line)
                + String(" character=") + String(character)
                + String(" word=") + word,
            )
        self._send_open_or_change(path, text^)
        var params = self._position_params(path, line, character)
        var ctx = json_object()
        ctx.put(String("includeDeclaration"), json_bool(True))
        params.put(String("context"), ctx)
        var sent = self._request_replacing(
            self._references.id.copy(), String("textDocument/references"), params)
        if not self._references.start(sent):
            return False
        self._ref_word = word^
        return True

    def has_pending_references(self) -> Bool:
        """True iff a parsed references response is parked for ``take``."""
        return self._references.ready

    def take_references(mut self) -> List[DefinitionResolved]:
        """Move the parked references list out of the manager. Pair with
        ``has_pending_references()`` — the flag is cleared either way."""
        var out = self._references.take()
        return out^

    def references_word(self) -> String:
        """Word the most recent references request was about. Kept until
        the next request; lets the host build a status-bar message that
        names the symbol after the response has been taken."""
        return self._ref_word

    def request_document_symbols(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Ask the server for ``textDocument/documentSymbol`` on ``path``.

        Like ``request_definition``, this pre-flights with a didOpen/didChange
        so the server's view matches the buffer. Returns False if the server
        isn't ready (or a send fails); the caller can retry once the LSP is
        in the READY state. A fresh request shadows any earlier in-flight
        symbol id — there's no concurrent symbol lookup model here.
        """
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        var sent = self._request_replacing(
            self._symbols.id.copy(),
            String("textDocument/documentSymbol"), params,
        )
        return self._symbols.start(sent)

    def has_pending_symbols(self) -> Bool:
        """True iff a parsed symbol response is parked, ready for ``take``."""
        return self._symbols.ready

    def take_symbols(mut self) -> List[SymbolItem]:
        """Move the parked symbol list out of the manager.

        Pair with ``has_pending_symbols()`` — calling this when nothing is
        parked just hands back an empty list. The flag is cleared either
        way so a subsequent call returns empty.
        """
        var out = self._symbols.take()
        return out^

    def request_workspace_symbols(
        mut self, query: String,
    ) -> Bool:
        """Ask the server for ``workspace/symbol`` matching ``query``.

        Unlike ``request_document_symbols``, this scans the entire
        workspace and the response items each carry their own
        location — so we don't need a didOpen pre-flight (the server
        already has its full project view from initialization).
        Returns False if the server isn't ready or the send fails.
        A fresh request shadows any earlier in-flight workspace
        symbol id — there's no concurrent lookup model.
        """
        if self.state != _STATE_READY:
            return False
        var params = json_object()
        params.put(String("query"), json_str(query))
        var sent = self._request_replacing(
            self._ws_symbols.id.copy(), String("workspace/symbol"), params)
        return self._ws_symbols.start(sent)

    def has_pending_workspace_symbols(self) -> Bool:
        """True iff a parsed workspace-symbol response is parked."""
        return self._ws_symbols.ready

    def take_workspace_symbols(
        mut self,
    ) -> List[WorkspaceSymbolItem]:
        """Move the parked workspace-symbol list out of the manager.
        Pair with ``has_pending_workspace_symbols()`` to distinguish
        "no response yet" from "empty list"."""
        var out = self._ws_symbols.take()
        if self._channel != 0:
            return self._own_workspace_symbols(out^)
        return out^

    def _own_workspace_symbols(
        self, var items: List[WorkspaceSymbolItem],
    ) -> List[WorkspaceSymbolItem]:
        """A shared server searches every window's workspace folder at once,
        so drop the symbols that belong to *another* window's project: those
        whose innermost containing root isn't ours. Symbols under no root at
        all — the stdlib, site-packages outside the project — stay."""
        var roots = channel_at(self._channel)[].roots()
        var root_paths = List[String]()
        for i in range(len(roots)):
            root_paths.append(_uri_to_path(roots[i]))
        var own = _uri_to_path(self._root_uri)
        var kept = List[WorkspaceSymbolItem]()
        for k in range(len(items)):
            var owner = String("")
            for i in range(len(root_paths)):
                var r = root_paths[i]
                if (items[k].path == r or items[k].path.startswith(r + String("/"))) \
                        and len(r.as_bytes()) > len(owner.as_bytes()):
                    owner = r
            if len(owner.as_bytes()) == 0 or owner == own:
                kept.append(items[k])
        return kept^

    def _request_replacing(
        mut self, var superseded: String, method: String, params: JsonValue,
    ) -> String:
        """``_request`` for a slot that holds one request at a time: the
        one it replaces (``superseded``, empty if none) is cancelled, so
        the server stops computing an answer nobody will read — a cursor
        move otherwise left every per-position request running to
        completion, and the stale response still got parsed and remapped
        before being dropped. The cancel goes out first, so the fresh
        request doesn't queue behind a worker still busy on the stale one."""
        if len(superseded.as_bytes()) > 0:
            self._send_cancel(superseded^, method)
        return self._request(method, params)

    def _send_cancel(mut self, var request_id: String, context: String):
        """Best-effort ``$/cancelRequest`` for ``request_id``. The cancel is
        a notification (no response), so a send failure is logged with
        ``context`` and otherwise ignored — if the server already returned,
        the cancel is a no-op anyway."""
        self._settle_awaited(request_id)
        var cancel_params = json_object()
        cancel_params.put(String("id"), json_str(request_id))
        self._notify(String("$/cancelRequest"), cancel_params, context)

    def request_completion(
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
        if self._logging():
            _lsp_debug_write(
                String("→ request_completion lang=") + self._language_id
                + String(" path=") + path
                + String(" line=") + String(line)
                + String(" character=") + String(character),
            )
        self._send_open_or_change(path, text^)
        var params = self._position_params(path, line, character)
        # ``CompletionContext.triggerKind`` 1 = Invoked (manual / Ctrl+Space).
        # Most servers ignore the field but pyright/pylsp use it to suppress
        # auto-import suggestions when the user explicitly invoked.
        var ctx = json_object()
        ctx.put(String("triggerKind"), json_int(1))
        params.put(String("context"), ctx)
        # If a previous completion is still in flight, tell the server
        # to stop computing it via ``$/cancelRequest``. Without this
        # the server keeps a worker pinned on a stale prefix and our
        # fresh request queues behind it — felt as laggy "type two
        # chars, wait for the first response to land before the popup
        # updates" behavior. The cancel is a notification (no
        # response), so it costs us nothing on the read side. The slot
        # shadows the old id, so its response (cancelled or not) is
        # dropped on arrival.
        var sent = self._request_replacing(
            self._completions.id.copy(),
            String("textDocument/completion"), params,
        )
        if not self._completions.start(sent, path):
            return False
        self._completion_manual = manual
        return True

    def cancel_completion(mut self):
        """Cancel any in-flight completion request.

        Sends ``$/cancelRequest`` so the server can drop work it has
        already started, and clears the slot's in-flight id so a
        late response — if one slips in before the cancel propagates —
        is ignored by the response handler instead of being parked
        for the host. Also clears any parked-but-unconsumed completion
        list (the user dismissed the popup; that list is irrelevant).
        No-op when nothing is in flight."""
        if len(self._completions.id.as_bytes()) == 0 \
                and not self._completions.ready:
            return
        if len(self._completions.id.as_bytes()) > 0:
            if self._logging():
                _lsp_debug_write(
                    String("→ cancel_completion id=")
                    + self._completions.id
                    + String(" lang=") + self._language_id,
                )
            var stale = self._completions.id^
            self._completions.id = String("")
            self._send_cancel(stale^, String("cancel_completion"))
        _ = self._completions.take()

    def has_pending_completions(self) -> Bool:
        """True iff a parsed completion response is parked for ``take``."""
        return self._completions.ready

    def pending_completion_path(self) -> String:
        return self._completions.path

    def pending_completion_manual(self) -> Bool:
        """Echo the ``manual`` flag of the most recent completion
        request. True when the user explicitly invoked completion
        (Ctrl+Space), False for the as-you-type auto-trigger."""
        return self._completion_manual

    def take_completions(mut self) -> List[CompletionItem]:
        """Move the parked completion list out of the manager.

        Pair with ``has_pending_completions()``. The flag is cleared
        either way so a subsequent call returns empty.
        """
        var out = self._completions.take()
        return out^

    def request_resolve_completion(mut self, item: CompletionItem) -> Bool:
        """Round-trip ``item`` through ``completionItem/resolve`` to pull
        in the ``detail`` / ``additionalTextEdits`` (auto-import) the
        server deferred. Gated on the server's ``resolveProvider`` — the
        host only calls this for the highlighted item, so the cost is one
        request per item the user actually considers. A fresh resolve
        shadows any prior in-flight one. Returns False (no-op) when the
        server isn't ready or doesn't resolve."""
        if self.state != _STATE_READY:
            return False
        if not self.server_supports_completion_resolve():
            return False
        # Reconstruct enough of the CompletionItem for the server to key
        # the resolve. ``data`` is the field most servers actually need;
        # ``label`` is mandatory. Re-parse the stashed raw ``data`` JSON
        # so it goes back as a real value, not a string.
        var ci = json_object()
        ci.put(String("label"), json_str(item.label))
        if item.kind > 0:
            ci.put(String("kind"), json_int(item.kind))
        if len(item.detail.as_bytes()) > 0:
            ci.put(String("detail"), json_str(item.detail))
        if len(item.insert_text.as_bytes()) > 0:
            ci.put(String("insertText"), json_str(item.insert_text))
        if len(item.data.as_bytes()) > 0:
            try:
                ci.put(String("data"), parse_json(item.data))
            except:
                pass
        self._inflight_resolve_id = self._request(String("completionItem/resolve"), ci)
        if len(self._inflight_resolve_id.as_bytes()) == 0:
            return False
        self._has_resolve_result = False
        return True

    def has_resolve_result(self) -> Bool:
        """True iff a resolved CompletionItem's enrichment is parked."""
        return self._has_resolve_result

    def resolve_detail(self) -> String:
        """The resolved item's ``detail`` (empty if none / unresolved).
        Read before ``take_resolve_aux``, which clears it."""
        return self._resolve_detail

    def take_resolve_aux(mut self) -> List[TextEditEntry]:
        """Move the resolved item's ``additionalTextEdits`` out and clear
        the parked-result flag. Pair with ``has_resolve_result``."""
        var out = self._resolve_aux^
        self._resolve_aux = List[TextEditEntry]()
        self._resolve_detail = String("")
        self._has_resolve_result = False
        return out^

    def request_hover(
        mut self, path: String, line: Int, character: Int,
        var text: String,
    ) -> Bool:
        """Ask the server for ``textDocument/hover`` at ``(line, character)``.

        Pre-flights with didOpen/didChange so the server's view matches
        the buffer at request time, then issues the hover request. A fresh
        request shadows any in-flight hover id — there's no concurrent
        hover model. Returns False when the server isn't ready (caller
        can simply skip — a hover that arrives after the mouse has moved
        elsewhere is not useful).

        The request coordinates are echoed back via ``pending_hover_*``
        so the host can drop a stale response when the cursor has moved
        on by the time the response arrives.
        """
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        # Cancel any prior in-flight hover so the server doesn't keep
        # working on a stale position. Mirrors ``request_completion``.
        var sent = self._request_replacing(
            self._hover.id.copy(), String("textDocument/hover"), params,
        )
        if not self._hover.start(sent, path):
            return False
        self._hover_row = line
        self._hover_col = character
        return True

    def has_pending_hover(self) -> Bool:
        """True iff a parsed hover response is parked for ``take``."""
        return self._hover.ready

    def pending_hover_path(self) -> String:
        return self._hover.path

    def pending_hover_row(self) -> Int:
        return self._hover_row

    def pending_hover_col(self) -> Int:
        return self._hover_col

    def take_hover_text(mut self) -> String:
        """Move the parked hover text out of the manager. Pair with
        ``has_pending_hover()`` — the flag is cleared either way."""
        var out = self._hover.take()
        return out^

    def request_code_actions(
        mut self, path: String, diag: Diagnostic, var text: String,
    ) -> Bool:
        """Ask the server for ``textDocument/codeAction`` covering
        ``diag``'s range, with ``diag`` echoed back in the request
        ``context.diagnostics`` array.

        The ``context.diagnostics`` echo is what unlocks "quickfix for
        this specific diagnostic" responses from ty / pyright / ruff —
        they key their fix lookups off the diagnostic that was at the
        position, not just the position itself. Pre-flights with
        didOpen/didChange so the server's view matches the buffer at
        request time. A fresh request shadows any in-flight code-action
        id — there's no concurrent code-action model (the diagnostic
        menu is modal).
        """
        if self.state != _STATE_READY:
            return False
        if self._logging():
            _lsp_debug_write(
                String("→ request_code_actions lang=") + self._language_id
                + String(" path=") + path
                + String(" range=(") + String(diag.start_row)
                + String(",") + String(diag.start_col)
                + String(")-(") + String(diag.end_row)
                + String(",") + String(diag.end_col) + String(")"),
            )
        self._send_open_or_change(path, text^)
        var params = self._doc_params(path)
        var rng = _lsp_range(
            diag.start_row, diag.start_col, diag.end_row, diag.end_col,
        )
        params.put(String("range"), rng)
        var ctx = json_object()
        var diag_obj = json_object()
        var d_rng = _lsp_range(
            diag.start_row, diag.start_col, diag.end_row, diag.end_col,
        )
        diag_obj.put(String("range"), d_rng)
        diag_obj.put(String("severity"), json_int(diag.severity))
        if len(diag.message.as_bytes()) > 0:
            diag_obj.put(String("message"), json_str(diag.message))
        if len(diag.source.as_bytes()) > 0:
            diag_obj.put(String("source"), json_str(diag.source))
        # The ``code`` echo is what makes ty / ruff / pyright return
        # actual fixes — they match quickfix rules by diagnostic code.
        # Sending the request without it gets ``result: null``.
        if len(diag.code.as_bytes()) > 0:
            diag_obj.put(String("code"), json_str(diag.code))
        var diags_arr = json_array()
        diags_arr.append(diag_obj)
        ctx.put(String("diagnostics"), diags_arr)
        params.put(String("context"), ctx)
        var sent = self._request_replacing(
            self._code_actions.id.copy(),
            String("textDocument/codeAction"), params,
        )
        return self._code_actions.start(sent, path)

    # --- codeAction/resolve ------------------------------------------------

    def _start_code_action_resolves(mut self, var actions: List[CodeAction]):
        """Park ``actions`` and fire a ``codeAction/resolve`` for each one
        that arrived without an inline edit.

        Publishing is deferred until every resolve returns (or the deadline
        passes) so the host sees one settled list rather than a list that
        grows edits underneath it. When nothing needs resolving — the common
        case, and every server that isn't rust-analyzer — this publishes
        immediately and costs a single empty-list check."""
        self._ca_accum = actions^
        self._ca_resolve = _ResolveFanout()
        if not self.server_supports_code_action_resolve():
            self._publish_code_actions_if_settled()
            return
        var raws = List[JsonValue]()
        var slots = List[Int]()
        for i in range(len(self._ca_accum)):
            ref a = self._ca_accum[i]
            if len(a.file_edits) == 0 and a.unresolved:
                raws.append(a.unresolved.value().copy())
                slots.append(i)
        self._ca_resolve = self._send_resolves(
            String("codeAction/resolve"), raws, slots,
        )
        if self._ca_resolve.pending() > 0:
            self._ca_resolve_deadline_ms = \
                monotonic_ms() + _CA_RESOLVE_TIMEOUT_MS
            if self._logging():
                _lsp_debug_write(
                    String("→ codeAction/resolve x")
                    + String(self._ca_resolve.pending())
                    + String(" lang=") + self._language_id,
                )
        self._publish_code_actions_if_settled()

    def _publish_code_actions_if_settled(mut self):
        """Hand the accumulated list to the host once no resolve is
        outstanding. Idempotent — safe to call after every resolve."""
        if self._ca_resolve.pending() > 0:
            return
        var settled = self._ca_accum^
        self._ca_accum = List[CodeAction]()
        self._code_actions.publish(settled^)
        self._ca_resolve_deadline_ms = 0

    def _expire_code_action_resolves(mut self):
        """Publish what we have if the resolves haven't come back in time.

        Driven from ``tick``. Without it a server that accepts a resolve and
        never answers leaves the quick-fix menu on "Loading fixes…" forever;
        with it the user gets the actions that did resolve (plus any that
        already had inline edits) and the menu settles."""
        if self._ca_resolve.pending() == 0:
            return
        if self._ca_resolve_deadline_ms <= 0:
            return
        if monotonic_ms() < self._ca_resolve_deadline_ms:
            return
        if self._logging():
            _lsp_debug_write(
                String("codeAction/resolve timed out with ")
                + String(self._ca_resolve.pending())
                + String(" outstanding; publishing partial list"),
            )
        self._ca_resolve = _ResolveFanout()
        self._publish_code_actions_if_settled()

    def has_pending_code_actions(self) -> Bool:
        """True iff a parsed code-action response is parked for ``take``.
        Pair with ``pending_code_action_path()`` to distinguish "still
        waiting" from "empty list for this file"."""
        return self._code_actions.ready

    def pending_code_action_path(self) -> String:
        """Path the most recent code-action request was issued for. Lets
        the host drop a stale response when the user has dismissed the
        diagnostic menu before the server replied."""
        return self._code_actions.path

    def take_code_actions(mut self) -> List[CodeAction]:
        """Move the parked code-action list out of the manager. Pair
        with ``has_pending_code_actions()`` — the flag is cleared either
        way so a follow-up call returns empty."""
        var out = self._code_actions.take()
        return out^

    def request_execute_command(
        mut self, command: String, var args: Optional[JsonValue],
    ) -> Bool:
        """Fire ``workspace/executeCommand``. The server applies the effect
        and typically pushes a ``workspace/applyEdit`` back, which our
        handler parks for the host. Fire-and-forget — we don't track the
        response (success is observed via the resulting edits)."""
        if self.state != _STATE_READY or len(command.as_bytes()) == 0:
            return False
        var params = json_object()
        params.put(String("command"), json_str(command))
        if args and args.value().is_array():
            params.put(String("arguments"), args.value().copy())
        else:
            params.put(String("arguments"), json_array())
        try:
            _ = self._send_request(
                String("workspace/executeCommand"), params,
            )
        except:
            return False
        return True

    def request_rename(
        mut self, path: String, line: Int, character: Int,
        new_name: String, var text: String,
    ) -> Bool:
        """Ask the server for ``textDocument/rename`` at
        ``(line, character)`` with the new identifier ``new_name``.

        Mirrors ``request_references`` — pre-flights with didOpen/didChange
        so the server's view matches the buffer, then parks an inflight id.
        The response is a ``WorkspaceEdit`` (possibly spanning several
        files), parsed in ``tick`` into the same ``CodeActionFileEdit``
        grouping the host already knows how to apply."""
        if self.state != _STATE_READY:
            return False
        if self._logging():
            _lsp_debug_write(
                String("→ request_rename lang=") + self._language_id
                + String(" path=") + path
                + String(" line=") + String(line)
                + String(" character=") + String(character)
                + String(" new_name=") + new_name,
            )
        self._rename.text = text.copy()
        self._send_open_or_change(path, text^)
        var params = self._position_params(path, line, character)
        params.put(String("newName"), json_str(new_name))
        var sent = self._request_replacing(
            self._rename.id.copy(), String("textDocument/rename"), params,
        )
        return self._rename.start(sent, path)

    def has_pending_rename(self) -> Bool:
        """True iff a parsed rename ``WorkspaceEdit`` is parked for ``take``.
        An empty list with the flag set means "server replied but had no
        edits" (rename unsupported / nothing to rename)."""
        return self._rename.ready

    def pending_rename_path(self) -> String:
        """Path the most recent rename request was issued for."""
        return self._rename.path

    def pending_rename_text(self) -> String:
        """The text of that file the rename was asked for against."""
        return self._rename.text

    def take_rename_edits(mut self) -> List[CodeActionFileEdit]:
        """Move the parked rename edits out of the manager. Clears the
        pending flag either way."""
        var out = self._rename.take()
        return out^

    # --- formatting -------------------------------------------------------

    def request_formatting(
        mut self, path: String, var text: String,
        tab_size: Int = 4, insert_spaces: Bool = True,
    ) -> Bool:
        """Send ``textDocument/formatting`` for the whole file. The
        resulting ``TextEdit[]`` is parked for the host to apply."""
        if self.state != _STATE_READY:
            return False
        self._formatting.text = text.copy()
        self._send_open_or_change(path, text^)
        var params = self._doc_params(path)
        params.put(String("options"), _formatting_options(tab_size, insert_spaces))
        return self._formatting.start(
            self._request_replacing(
                self._formatting.id.copy(), String("textDocument/formatting"), params), path,
        )

    def request_range_formatting(
        mut self, path: String, start_line: Int, start_char: Int,
        end_line: Int, end_char: Int, var text: String,
        tab_size: Int = 4, insert_spaces: Bool = True,
    ) -> Bool:
        """Send ``textDocument/rangeFormatting`` for the given range."""
        if self.state != _STATE_READY:
            return False
        self._formatting.text = text.copy()
        self._send_open_or_change(path, text^)
        var params = self._doc_params(path)
        var rng = _lsp_range(start_line, start_char, end_line, end_char)
        params.put(String("range"), rng)
        params.put(String("options"), _formatting_options(tab_size, insert_spaces))
        return self._formatting.start(
            self._request_replacing(
                self._formatting.id.copy(), String("textDocument/rangeFormatting"), params), path,
        )

    def has_pending_formatting(self) -> Bool:
        return self._formatting.ready

    def pending_formatting_path(self) -> String:
        return self._formatting.path

    def pending_formatting_text(self) -> String:
        """The buffer text the pending formatting request was made against."""
        return self._formatting.text

    def take_formatting_edits(mut self) -> List[TextEditEntry]:
        """Move out the parked formatting ``TextEdit[]``. Clears the flag."""
        return self._formatting.take()

    def on_type_trigger_chars(self) -> String:
        """The concatenated set of characters that trigger
        ``onTypeFormatting`` (``firstTriggerCharacter`` +
        ``moreTriggerCharacter[]``), or empty when unsupported. The host
        only fires a request when the just-typed char is in this set."""
        var p_opt = self._cap_at(
            String("documentOnTypeFormattingProvider"),
        )
        if not p_opt or not p_opt.value().is_object():
            return String("")
        var prov = p_opt.value().copy()
        var out = String("")
        var first = prov.object_get(String("firstTriggerCharacter"))
        if first and first.value().is_string():
            out = out + first.value().as_str()
        var more = prov.object_get(String("moreTriggerCharacter"))
        if more and more.value().is_array():
            var arr = more.value().copy()
            for i in range(arr.array_len()):
                var c = arr.array_at(i)
                if c.is_string():
                    out = out + c.as_str()
        return out^

    def request_on_type_formatting(
        mut self, path: String, line: Int, character: Int, ch: String,
        var text: String, tab_size: Int = 4, insert_spaces: Bool = True,
    ) -> Bool:
        """Send ``textDocument/onTypeFormatting`` at ``(line, character)``
        for the just-typed ``ch``. The returned ``TextEdit[]`` (a reindent
        of the current construct) is parked for the host to apply without
        saving."""
        if self.state != _STATE_READY:
            return False
        self._ontype.text = text.copy()
        self._send_open_or_change(path, text^)
        var params = self._position_params(path, line, character)
        params.put(String("ch"), json_str(ch))
        params.put(String("options"), _formatting_options(tab_size, insert_spaces))
        return self._ontype.start(
            self._request_replacing(
                self._ontype.id.copy(), String("textDocument/onTypeFormatting"), params), path,
        )

    def has_pending_ontype(self) -> Bool:
        return self._ontype.ready

    def pending_ontype_path(self) -> String:
        return self._ontype.path

    def pending_ontype_text(self) -> String:
        return self._ontype.text

    def take_ontype_edits(mut self) -> List[TextEditEntry]:
        return self._ontype.take()

    def request_moniker(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/moniker`` for the symbol at ``(line,
        character)``. The parsed ``scheme:identifier`` list is parked as a
        status string."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        var sent = self._request_replacing(
            self._moniker.id.copy(),
            String("textDocument/moniker"), params,
        )
        return self._moniker.start(sent)

    def has_moniker(self) -> Bool:
        return self._moniker.ready

    def take_moniker(mut self) -> String:
        var out = self._moniker.take()
        return out^

    def request_color_presentation(
        mut self, path: String, r: Int, g: Int, b: Int,
        start_line: Int, start_char: Int, end_line: Int, end_char: Int,
        var text: String,
    ) -> Bool:
        """Send ``textDocument/colorPresentation`` for the color ``(r,g,b)``
        (0..255) occupying the given range. The server returns alternate
        textual forms; each becomes a (label, edit) pair the host shows in a
        picker."""
        if not self._sync_for_request(path, text^):
            return False
        var color = json_object()
        color.put(String("red"), json_float(_unit_text(r)))
        color.put(String("green"), json_float(_unit_text(g)))
        color.put(String("blue"), json_float(_unit_text(b)))
        color.put(String("alpha"), json_float(String("1.0")))
        var rng = _lsp_range(start_line, start_char, end_line, end_char)
        var params = self._doc_params(path)
        params.put(String("color"), color)
        params.put(String("range"), rng)
        var sent = self._request_replacing(
            self._colorpres.id.copy(),
            String("textDocument/colorPresentation"), params,
        )
        if not self._colorpres.start(sent):
            return False
        self._colorpres_sl = start_line
        self._colorpres_sc = start_char
        self._colorpres_el = end_line
        self._colorpres_ec = end_char
        self._colorpres_edits = List[TextEditEntry]()
        return True

    def has_color_presentations(self) -> Bool:
        return self._colorpres.ready

    def color_presentation_labels(self) -> List[String]:
        return self._colorpres.value.copy()

    def take_color_presentation_edit(
        mut self, index: Int,
    ) -> List[TextEditEntry]:
        """Return the chosen presentation's edit (as a one-element list) and
        clear all parked presentations. Empty list for an out-of-range
        index."""
        var out = List[TextEditEntry]()
        if 0 <= index and index < len(self._colorpres_edits):
            out.append(self._colorpres_edits[index])
        _ = self._colorpres.take()
        self._colorpres_edits = List[TextEditEntry]()
        return out^

    def request_inline_completion(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/inlineCompletion`` at ``(line, character)``
        (manually invoked). The first item's insert text is parked as a
        ghost-text suggestion anchored at the request position."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        var ctx = json_object()
        ctx.put(String("triggerKind"), json_int(1))  # Invoked
        params.put(String("context"), ctx)
        var sent = self._request_replacing(
            self._inlinecomp.id.copy(),
            String("textDocument/inlineCompletion"), params,
        )
        if not self._inlinecomp.start(sent):
            return False
        self._inlinecomp_row = line
        self._inlinecomp_col = character
        return True

    def has_inline_completion(self) -> Bool:
        return self._inlinecomp.ready

    def inline_completion_text(self) -> String:
        return self._inlinecomp.value

    def inline_completion_row(self) -> Int:
        return self._inlinecomp_row

    def inline_completion_col(self) -> Int:
        return self._inlinecomp_col

    def clear_inline_completion(mut self):
        _ = self._inlinecomp.take()

    def request_linked_editing(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/linkedEditingRange`` at ``(line, character)``.
        Parks the linked ranges (range carriers) for the host to place
        synchronized carets at."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        if not self._linked.start(
            self._request_replacing(
                self._linked.id.copy(), String("textDocument/linkedEditingRange"), params),
        ):
            return False
        return True

    def has_linked_editing(self) -> Bool:
        return self._linked.ready

    def take_linked_ranges(mut self) -> List[TextEditEntry]:
        return self._linked.take()

    def request_inline_values(
        mut self, path: String, start_line: Int, end_line: Int,
        stopped_line: Int, frame_id: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/inlineValue`` for the ``[start_line,
        end_line]`` range with the debugger's stopped context. Parks the
        ``InlineValueText`` entries as (row, text) carriers for end-of-line
        rendering."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        var rng = _lsp_range(start_line, 0, end_line, 0)
        params.put(String("range"), rng)
        var ctx = json_object()
        ctx.put(String("frameId"), json_int(frame_id))
        var stopped = _lsp_range(stopped_line, 0, stopped_line, 0)
        ctx.put(String("stoppedLocation"), stopped)
        params.put(String("context"), ctx)
        if not self._inlineval.start(
            self._request_replacing(
                self._inlineval.id.copy(), String("textDocument/inlineValue"), params),
        ):
            return False
        self._inlineval_exprs = List[TextEditEntry]()
        return True

    def has_inline_values(self) -> Bool:
        return self._inlineval.ready

    def take_inline_values(mut self) -> List[TextEditEntry]:
        return self._inlineval.take()

    def take_inline_value_exprs(mut self) -> List[TextEditEntry]:
        """The variable-lookup / evaluable inline values as (row, expr)
        carriers for the host to evaluate via DAP. Cleared on take."""
        var out = self._inlineval_exprs^
        self._inlineval_exprs = List[TextEditEntry]()
        return out^

    def request_folding_ranges(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Send ``textDocument/foldingRange`` for the whole file. Parks the
        collapsible regions as (start_line..end_line) range carriers."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        return self._folding.start(
            self._request_replacing(
                self._folding.id.copy(), String("textDocument/foldingRange"), params), path,
        )

    def has_pending_folding(self) -> Bool:
        return self._folding.ready

    def pending_folding_path(self) -> String:
        return self._folding.path

    def take_folding_ranges(mut self) -> List[TextEditEntry]:
        return self._folding.take()

    # --- document highlight ----------------------------------------------

    def request_document_highlight(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/documentHighlight`` for the symbol at
        ``(line, character)``. Parks the occurrence ranges."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        return self._doc_highlight.start(
            self._request_replacing(
                self._doc_highlight.id.copy(), String("textDocument/documentHighlight"), params), path,
        )

    def has_pending_doc_highlights(self) -> Bool:
        return self._doc_highlight.ready

    def pending_doc_highlight_path(self) -> String:
        return self._doc_highlight.path

    def take_doc_highlights(mut self) -> List[TextEditEntry]:
        return self._doc_highlight.take()

    # --- signature help ---------------------------------------------------

    def request_signature_help(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/signatureHelp`` at ``(line, character)``.
        Parks the rendered active-signature label for the status bar."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        var sent = self._request_replacing(
            self._signature.id.copy(),
            String("textDocument/signatureHelp"), params,
        )
        return self._signature.start(sent)

    def has_pending_signature(self) -> Bool:
        return self._signature.ready

    def take_signature(mut self) -> String:
        """Move out the parked signature label (empty if the server had no
        signature here). Clears the pending flag."""
        var out = self._signature.take()
        return out^

    # --- inlay hints / code lens -----------------------------------------

    def request_inlay_hints(
        mut self, path: String, start_line: Int, end_line: Int,
        var text: String,
    ) -> Bool:
        """Send ``textDocument/inlayHint`` for the ``[start_line, end_line]``
        range (typically the visible rows). Parks (row, label) carriers."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        var rng = _lsp_range(start_line, 0, end_line, 0)
        params.put(String("range"), rng)
        return self._inlay.start(
            self._request_replacing(
                self._inlay.id.copy(), String("textDocument/inlayHint"), params), path,
        )

    def has_pending_inlay(self) -> Bool:
        return self._inlay.ready

    def pending_inlay_path(self) -> String:
        return self._inlay.path

    def take_inlay(mut self) -> List[TextEditEntry]:
        return self._inlay.take()

    def request_code_lens(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Send ``textDocument/codeLens`` for the whole file. Parks
        (row, title) carriers for lenses that carry a resolved command."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        if not self._codelens.start(
            self._request_replacing(
                self._codelens.id.copy(), String("textDocument/codeLens"), params), path,
        ):
            return False
        self._inflight_codelens_resolve_id = String("")
        self._codelens_resolve_queue = List[JsonValue]()
        self._codelens_accum = List[TextEditEntry]()
        return True

    def server_supports_codelens_resolve(self) -> Bool:
        """True iff ``codeLensProvider.resolveProvider`` — lenses arrive
        without a ``command`` and need a ``codeLens/resolve`` to fill the
        title."""
        return self._cap_bool(
            String("codeLensProvider"), String("resolveProvider"),
        )

    def _send_next_codelens_resolve(mut self):
        """Pop the next unresolved lens off the queue and fire a
        ``codeLens/resolve``. No-op when the queue is empty or one is
        already in flight."""
        if len(self._inflight_codelens_resolve_id.as_bytes()) > 0:
            return
        if len(self._codelens_resolve_queue) == 0:
            return
        var lens = self._codelens_resolve_queue.pop(0)
        # Capture the lens's line so the resolved title lands on the right
        # row regardless of response ordering.
        self._codelens_resolve_row = _codelens_row_of(lens)
        try:
            self._inflight_codelens_resolve_id = self._send_request(
                String("codeLens/resolve"), lens,
            )
        except:
            self._inflight_codelens_resolve_id = String("")

    def has_pending_codelens(self) -> Bool:
        return self._codelens.ready

    def pending_codelens_path(self) -> String:
        return self._codelens.path

    def take_codelens(mut self) -> List[TextEditEntry]:
        return self._codelens.take()

    # --- document links ---------------------------------------------------

    def request_document_links(mut self, path: String, var text: String) -> Bool:
        """Send ``textDocument/documentLink`` for the whole file. Parks
        range carriers (``new_text`` = target uri) for links the server
        returned with an inline target."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        return self._doclinks.start(
            self._request_replacing(
                self._doclinks.id.copy(), String("textDocument/documentLink"), params), path,
        )

    def server_supports_document_link_resolve(self) -> Bool:
        """True iff ``documentLinkProvider.resolveProvider`` — the server
        returns links whose ``target`` it fills in on a
        ``documentLink/resolve`` round-trip. ``vscode-json-language-server``
        does this for every ``$ref``."""
        return self._cap_bool(
            String("documentLinkProvider"), String("resolveProvider"),
        )

    def _start_document_link_resolves(mut self, parsed: DocumentLinkParse):
        """Publish the links that have targets now, and fire a
        ``documentLink/resolve`` for each one the server withheld.

        The slot each resolve fills comes from ``parsed.unresolved_slots``,
        computed during the parse walk — nothing here re-derives which links
        needed resolving, so there is no second filter to drift out of step
        and pair a target with the wrong link."""
        self._dl_accum = parsed.links.copy()
        self._dl_resolve = _ResolveFanout()
        # Publish immediately: a resolvable link is merely missing until its
        # target arrives, so there's nothing to gain from making the ones we
        # already have wait on a round-trip.
        self._publish_document_links()
        if not self.server_supports_document_link_resolve():
            return
        self._dl_resolve = self._send_resolves(
            String("documentLink/resolve"), parsed.unresolved_raw,
            parsed.unresolved_slots,
        )
        if self._dl_resolve.pending() > 0:
            if self._logging():
                _lsp_debug_write(
                    String("→ documentLink/resolve x")
                    + String(self._dl_resolve.pending())
                    + String(" lang=") + self._language_id,
                )

    def _send_resolves(
        mut self, method: String, raws: List[JsonValue], slots: List[Int],
    ) -> _ResolveFanout:
        """Send ``method`` for each of ``raws`` (the items as the server
        sent them), each answer to fill ``slots[i]``; the requests that
        went out."""
        var out = _ResolveFanout()
        for i in range(len(raws)):
            var rid: String
            try:
                rid = self._send_request(method, raws[i])
            except:
                continue
            if len(rid.as_bytes()) > 0:
                out.add(rid, slots[i])
        return out^

    def _publish_document_links(mut self):
        """Hand the host every link that has a target.

        The accumulator keeps the targetless entries so a resolve response
        can still find its slot, but they are filtered out of what the host
        sees: an underlined range that does nothing on click is worse than
        no underline, which is why the pre-resolve code dropped them
        outright. A server that never answers the resolve therefore degrades
        to exactly the old behavior."""
        var out = List[TextEditEntry]()
        for i in range(len(self._dl_accum)):
            if len(self._dl_accum[i].new_text.as_bytes()) > 0:
                out.append(self._dl_accum[i])
        self._doclinks.publish(out^)

    def has_pending_doclinks(self) -> Bool:
        return self._doclinks.ready

    def pending_doclink_path(self) -> String:
        return self._doclinks.path

    def take_doclinks(mut self) -> List[TextEditEntry]:
        return self._doclinks.take()

    # --- selection range --------------------------------------------------

    def request_selection_range(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/selectionRange`` for one position. Parks the
        flattened range hierarchy (innermost→outermost)."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        var positions = json_array()
        positions.append(_lsp_position(line, character))
        params.put(String("positions"), positions)
        return self._selrange.start(
            self._request_replacing(
                self._selrange.id.copy(), String("textDocument/selectionRange"), params), path,
        )

    def has_pending_selrange(self) -> Bool:
        return self._selrange.ready

    def pending_selrange_path(self) -> String:
        return self._selrange.path

    def take_selrange(mut self) -> List[TextEditEntry]:
        return self._selrange.take()

    # --- call / type hierarchy -------------------------------------------

    def request_call_hierarchy(
        mut self, path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        """Begin a "find callers" flow: ``prepareCallHierarchy`` at the
        cursor, auto-chained to ``callHierarchy/incomingCalls`` on the
        prepared item. Final caller locations route to the references
        picker."""
        return self._begin_hierarchy(
            String("textDocument/prepareCallHierarchy"),
            String("callHierarchy/incomingCalls"),
            path, line, character, word^, text^,
        )

    def request_type_hierarchy(
        mut self, path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        """Begin a "find supertypes" flow: ``prepareTypeHierarchy`` →
        ``typeHierarchy/supertypes``."""
        return self._begin_hierarchy(
            String("textDocument/prepareTypeHierarchy"),
            String("typeHierarchy/supertypes"),
            path, line, character, word^, text^,
        )

    def request_call_hierarchy_outgoing(
        mut self, path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        """Begin a "find callees" flow: ``prepareCallHierarchy`` →
        ``callHierarchy/outgoingCalls`` (the functions this symbol calls).
        Mirror of ``request_call_hierarchy`` with the opposite direction."""
        return self._begin_hierarchy(
            String("textDocument/prepareCallHierarchy"),
            String("callHierarchy/outgoingCalls"),
            path, line, character, word^, text^,
        )

    def request_type_hierarchy_subtypes(
        mut self, path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        """Begin a "find subtypes" flow: ``prepareTypeHierarchy`` →
        ``typeHierarchy/subtypes`` (the types deriving from this one)."""
        return self._begin_hierarchy(
            String("textDocument/prepareTypeHierarchy"),
            String("typeHierarchy/subtypes"),
            path, line, character, word^, text^,
        )

    def _begin_hierarchy(
        mut self, prepare_method: String, followup_method: String,
        path: String, line: Int, character: Int,
        var word: String, var text: String,
    ) -> Bool:
        if not self._sync_for_request(path, text^):
            return False
        var params = self._position_params(path, line, character)
        var sent = self._request_replacing(
            self._hierarchy.id.copy(), prepare_method, params,
        )
        if not self._hierarchy.start(sent):
            return False
        # A superseded flow already past its prepare step is cancelled too.
        if len(self._inflight_hier_followup_id.as_bytes()) > 0:
            var followup = self._inflight_hier_followup_id^
            self._inflight_hier_followup_id = String("")
            self._send_cancel(followup^, self._hierarchy_followup.copy())
        self._hierarchy_followup = followup_method
        self._hierarchy_word = word^
        return True

    def has_pending_hierarchy(self) -> Bool:
        return self._hierarchy.ready

    def hierarchy_word(self) -> String:
        return self._hierarchy_word

    def take_hierarchy(mut self) -> List[DefinitionResolved]:
        var out = self._hierarchy.take()
        return out^

    # --- document color ---------------------------------------------------

    def request_document_colors(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Send ``textDocument/documentColor``. Parks swatch highlights."""
        if not self._sync_for_request(path, text^):
            return False
        var params = self._doc_params(path)
        var sent = self._request_replacing(
            self._colors.id.copy(),
            String("textDocument/documentColor"), params,
        )
        return self._colors.start(sent, path)

    def has_pending_colors(self) -> Bool:
        return self._colors.ready

    def pending_color_path(self) -> String:
        return self._colors.path

    def take_colors(mut self) -> List[Highlight]:
        var out = self._colors.take()
        return out^

    def take_document_refresh(mut self) -> Bool:
        """True once per ``workspace/{codeLens,inlayHint,inlineValue,foldingRange,textDocumentContent}/refresh``
        the server sent. The host drops its document-feature debounce key so
        the next tick re-requests. Consuming clears the flag."""
        var was = self._refresh_doc_features
        self._refresh_doc_features = False
        return was

    def take_diagnostics_refresh(mut self) -> Bool:
        """True once per ``workspace/diagnostic/refresh``. The pull-diagnostics
        re-arm already happened in the handler (``_pulled_paths`` was
        cleared); this is for the host that wants to know it happened."""
        var was = self._refresh_diagnostics
        self._refresh_diagnostics = False
        return was

    def has_pending_applyedit(self) -> Bool:
        return self._has_resolved_applyedit

    def take_applyedit(mut self) -> List[CodeActionFileEdit]:
        """Move out a server-driven ``workspace/applyEdit`` payload (parsed
        per-file edit groups). The host applies it project-wide."""
        var out = self._resolved_applyedit^
        self._resolved_applyedit = List[CodeActionFileEdit]()
        self._has_resolved_applyedit = False
        return out^

    # --- frame-tick driver -------------------------------------------------

    def tick(mut self) -> Optional[DefinitionResolved]:
        """Drive the state machine one step.

        Drains every framed message currently available, advancing the
        handshake on ``initialize`` responses, surfacing the first
        ``DefinitionResolved`` from the in-flight request id, and
        parking ``textDocument/publishDiagnostics`` payloads on the
        per-URI bucket list; ``window/logMessage``, ``$/progress`` and the
        other notifications and server requests are routed to their own
        handlers below.
        """
        if self.state == _STATE_NOT_STARTED or self.state == _STATE_FAILED:
            return Optional[DefinitionResolved]()
        # Continue draining any outbound bytes that the previous
        # ``write_message`` couldn't push in one shot (server stopped
        # reading stdin mid-frame). Without this a backlog never
        # flushes until the next ``write_message`` call, which may be
        # far enough in the future that the server has already given
        # up.
        if self._join_pending:
            self._complete_join()
            if self._join_pending or self.state == _STATE_FAILED:
                return Optional[DefinitionResolved]()
        self._pump_writes()
        self._expire_library_probes()
        # If the outbound queue overflowed, the server isn't draining
        # its stdin and we've lost framing alignment — there's no
        # recovery short of restarting. Latch FAILED so the host
        # surfaces the state and stops sending more.
        if self._write_overflowed():
            self.state = _STATE_FAILED
            self.failure_reason = String(
                "outbound queue overflowed (server not reading stdin)",
            )
            if self._logging():
                _lsp_debug_write(
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
        # Publish a partially-resolved code-action list rather than leaving
        # the quick-fix menu on "Loading fixes…" if a resolve never answers.
        self._expire_code_action_resolves()
        # Crash-detection: if the child has exited while we still
        # consider the session live, latch FAILED with whatever stderr
        # carried. Without this the manager stays in INITIALIZING
        # forever and the user sees an indefinite "starting…" with no
        # explanation. Mirror of the DAP manager's crash-detect.
        if self._reaped():
            # One last drain — between the previous absorb and the
            # reap the child may have flushed its final stderr line.
            self._absorb_stderr()
            self.state = _STATE_FAILED
            var why = String("server exited")
            var first = _first_nonempty_line(self._stderr_log.text)
            if len(first.as_bytes()) > 0:
                why = why + String(": ") + first
            self.failure_reason = why^
            if self._logging():
                _lsp_debug_write(
                    String("✗ lsp ") + self._language_id
                    + String(" exited; failure_reason=") + self.failure_reason,
                )
            return Optional[DefinitionResolved]()
        var resolved = Optional[DefinitionResolved]()
        # Drain every framed message currently sitting in the kernel
        # pipe buffer. The previous cap of 16 was too low for the
        # diagnostics-fanout case (a large project may publish
        # diagnostics for dozens of files at startup) and for very
        # large completion responses that split across multiple
        # ``read(2)`` calls. ``poll_message`` itself now reads
        # non-blocking until the pipe is empty, so each iteration is
        # bounded by "one framed message"; the safety cap stays as a
        # belt-and-braces guard against a runaway server, but well
        # above the realistic worst case.
        var i = 0
        while i < 256:
            i += 1
            var maybe: Optional[LspIncoming]
            try:
                maybe = self._poll()
            except:
                return resolved
            if not maybe:
                return resolved
            var msg = maybe.take()
            self._last_rx_ms = monotonic_ms()
            if msg.kind == LSP_NOTIFICATION:
                if msg.method and msg.params:
                    var method = msg.method.value()
                    # ``publishDiagnostics`` ranges are wire-encoded and the
                    # params carry the ``uri`` the walk needs; the other
                    # notifications have no positions, so converting them
                    # all is free and keeps future ones correct.
                    self._from_wire(msg.params.value(), String(""))
                    if method == String("textDocument/publishDiagnostics"):
                        self._on_publish_diagnostics(msg.params.value())
                    elif method == String("$/progress"):
                        self._on_progress(msg.params.value())
                    elif method == String("window/showMessage"):
                        self._on_show_message(msg.params.value())
                    elif method == String("window/logMessage"):
                        self._on_log_message(msg.params.value())
                    elif method == String("$/logTrace"):
                        # Trace output the server emits when tracing is on.
                        # Route it to the same capture the info window shows
                        # as ``window/logMessage`` — it's the only channel a
                        # server has for "here is what I just did", and we
                        # were dropping it on the floor.
                        self._on_log_trace(msg.params.value())
                    elif method == String("telemetry/event") \
                            and not self._log_capture.full():
                        self._append_log(
                            String("[telemetry] ")
                            + encode_json(msg.params.value()),
                        )
                continue
            if msg.kind == LSP_REQUEST:
                # ``workspace/applyEdit`` carries a whole WorkspaceEdit and
                # ``window/showDocument`` a selection range — both in wire
                # units, both applied to buffers, so both must be converted
                # before ``_handle_server_request`` parses them.
                if msg.params:
                    self._from_wire(msg.params.value(), String(""))
                self._handle_server_request(msg)
                continue
            if msg.kind != LSP_RESPONSE:
                continue
            if not msg.id:
                continue
            var id = json_rpc_id(msg.id.value())
            if len(id.as_bytes()) == 0:
                continue
            self._settle_awaited(id)
            if self.state == _STATE_INITIALIZING and id == self._init_id:
                self._on_initialize_response(msg)
                continue
            # Convert every ``Position.character`` in the result from the
            # negotiated wire encoding to the byte columns the rest of this
            # file (and the editor) speak — once, before the id-dispatch
            # chain, so none of the ~30 parse branches below has to know
            # the encoding exists. No-op under ``utf-8``. Deliberately
            # after the initialize branch: the encoding isn't negotiated
            # until that response is handled, and it carries no positions.
            if self._position_encoding_tag != POS_UTF8 and msg.result:
                var default_uri = self._take_req_uri(id)
                self._from_wire(msg.result.value(), default_uri)
            if id == self._inflight_def_id:
                var loc = Optional[DefinitionResolved]()
                if msg.result:
                    loc = _parse_definition_result(msg.result.value())
                if self._logging():
                    var result_dump = String("<no result>")
                    var error_dump = String("<no error>")
                    if msg.result:
                        result_dump = encode_json(msg.result.value())
                    if msg.error:
                        error_dump = encode_json(msg.error.value())
                    _lsp_debug_write(
                        String("← definition response id=") + id
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
                self._inflight_def_id = String("")
                self._inflight_word = String("")
                continue
            if self._references.owns(id):
                self._references.settle[_parse_references_result](msg.result)
                self._log_response(
                    String("references"), id, String("count"), len(self._references.value),
                )
                continue
            if self._symbols.owns(id):
                self._symbols.settle[_parse_symbols_result](msg.result)
                continue
            if self._ws_symbols.owns(id):
                self._ws_symbols.settle[_parse_workspace_symbols_result](msg.result)
                continue
            if self._completions.owns(id):
                self._completions.settle[_parse_completion_result](msg.result)
                self._log_response(
                    String("completion"), id, String("count"), len(self._completions.value),
                )
                continue
            if id == self._inflight_resolve_id:
                var r_aux = List[TextEditEntry]()
                var r_detail = String("")
                if msg.result and msg.result.value().is_object():
                    r_aux = _parse_additional_text_edits(msg.result.value())
                    r_detail = json_get_string(
                        msg.result.value(), String("detail"), r_detail,
                    )
                if self._logging():
                    _lsp_debug_write(
                        String("← resolve response id=") + id
                        + String(" lang=") + self._language_id
                        + String(" aux=") + String(len(r_aux)),
                    )
                self._resolve_aux = r_aux^
                self._resolve_detail = r_detail^
                self._has_resolve_result = True
                self._inflight_resolve_id = String("")
                continue
            if self._hover.owns(id):
                self._hover.settle[_parse_hover_result](msg.result)
                self._log_response(
                    String("hover"), id, String("len"),
                    len(self._hover.value.as_bytes()),
                )
                continue
            if self._code_actions.owns(id):
                var actions = List[CodeAction]()
                if msg.result:
                    actions = _parse_code_action_result(msg.result.value())
                if self._logging():
                    _lsp_debug_write(
                        String("← codeAction response id=") + id
                        + String(" lang=") + self._language_id
                        + String(" count=") + String(len(actions)),
                    )
                self._code_actions.id = String("")
                self._start_code_action_resolves(actions^)
                continue
            var ca_slot = self._ca_resolve.slot(id)
            if ca_slot >= 0:
                # A resolved action carries the same fields plus the ``edit``
                # the initial response withheld. Only the edit is merged: the
                # title is already on screen, and letting a resolve rewrite it
                # would change the row the user is looking at.
                if msg.result and msg.result.value().is_object():
                    var resolved = _parse_workspace_edit(
                        _code_action_edit_of(msg.result.value()),
                    )
                    self._ca_accum[ca_slot].file_edits = \
                        resolved.file_edits.copy()
                    # A resolve may also be where the Command shows up.
                    if len(self._ca_accum[ca_slot].command.as_bytes()) == 0:
                        var cmd = _code_action_command_of(msg.result.value())
                        self._ca_accum[ca_slot].command = cmd[0]
                        self._ca_accum[ca_slot].command_args = cmd[1].copy()
                self._ca_resolve.drop(id)
                self._publish_code_actions_if_settled()
                continue
            if self._rename.owns(id):
                var rename_edits = List[CodeActionFileEdit]()
                if msg.result and msg.result.value().is_object():
                    rename_edits = _parse_workspace_edit_changes(
                        msg.result.value(),
                    )
                if self._logging():
                    _lsp_debug_write(
                        String("← rename response id=") + id
                        + String(" lang=") + self._language_id
                        + String(" files=") + String(len(rename_edits)),
                    )
                self._rename.finish(rename_edits^)
                continue
            if self._nav.owns(id):
                var nav = Optional[DefinitionResolved]()
                if msg.result:
                    nav = _parse_definition_result(msg.result.value())
                var nav_found = String("no")
                if nav:
                    nav_found = String("yes")
                if self._logging():
                    _lsp_debug_write(
                        String("← navigation response id=") + id
                        + String(" found=") + nav_found,
                    )
                self._nav.finish(nav^)
                continue
            var lp_slot = self._libprobe_slot(id)
            if lp_slot >= 0:
                var probe = Optional[DefinitionResolved]()
                if msg.result:
                    probe = _parse_definition_result(msg.result.value())
                var p = self._libprobes.pop(lp_slot)
                self._libprobe_done.append(LibraryProbe(
                    p.word, probe, p.tag, True,
                ))
                continue
            if self._prepare_rename.owns(id):
                # Success with a range/placeholder → renameable (1);
                # success with null → not renameable (2); an error
                # response (method unsupported) → fall back (0).
                var st = 0
                var ph = String("")
                if msg.result:
                    ref rv = msg.result.value()
                    if rv.is_null():
                        st = 2
                    elif rv.is_object():
                        st = 1
                        ph = _parse_prepare_rename_placeholder(rv)
                self._prepare_rename_state = st
                self._prepare_rename.finish(ph^)
                continue
            if self._formatting.owns(id):
                self._formatting.settle[_parse_text_edits](msg.result)
                self._log_response(
                    String("formatting"), id, String("edits"), len(self._formatting.value),
                )
                continue
            if self._ontype.owns(id):
                self._ontype.settle[_parse_text_edits](msg.result)
                continue
            if self._moniker.owns(id):
                self._moniker.settle[_parse_monikers](msg.result)
                continue
            if self._colorpres.owns(id):
                var cp_labels = List[String]()
                var cp_edits = List[TextEditEntry]()
                if msg.result and msg.result.value().is_array():
                    ref arr = msg.result.value()
                    for k in range(len(arr.arr_v)):
                        ref e = arr.arr_v[k]
                        var li = e.object_index(String("label"))
                        if li < 0 or not e.obj_v[li].value.is_string():
                            continue
                        var label = e.obj_v[li].value.as_str()
                        cp_labels.append(label)
                        # Rewrite the color literal's range with the chosen
                        # form. (We use the label as the new text — for color
                        # literals the server's textEdit range matches the
                        # requested span and its text is the label.)
                        cp_edits.append(TextEditEntry(
                            self._colorpres_sl, self._colorpres_sc,
                            self._colorpres_el, self._colorpres_ec, label,
                        ))
                self._colorpres_edits = cp_edits^
                self._colorpres.finish(cp_labels^)
                continue
            if self._inlinecomp.owns(id):
                self._inlinecomp.settle[_parse_inline_completion](msg.result)
                continue
            if self._linked.owns(id):
                self._linked.settle[_parse_linked_ranges](msg.result)
                continue
            if self._inlineval.owns(id):
                var iv = List[TextEditEntry]()
                var ive = List[TextEditEntry]()
                if msg.result:
                    iv = _parse_inline_values(msg.result.value())
                    ive = _parse_inline_value_exprs(msg.result.value())
                self._inlineval_exprs = ive^
                self._inlineval.finish(iv^)
                continue
            if self._folding.owns(id):
                self._folding.settle[_parse_folding_ranges](msg.result)
                continue
            if self._doc_highlight.owns(id):
                self._doc_highlight.settle[_parse_document_highlights](msg.result)
                continue
            if self._signature.owns(id):
                self._signature.settle[_parse_signature_help](msg.result)
                continue
            if self._inlay.owns(id):
                self._inlay.settle[_parse_inlay_hints](msg.result)
                continue
            if self._codelens.owns(id):
                self._codelens_accum = List[TextEditEntry]()
                self._codelens_resolve_queue = List[JsonValue]()
                if msg.result:
                    self._codelens_accum = _parse_code_lens(msg.result.value())
                    if self.server_supports_codelens_resolve():
                        self._codelens_resolve_queue = \
                            _collect_unresolved_lenses(msg.result.value())
                self._codelens.finish(self._codelens_accum.copy())
                # Kick off resolving lenses that shipped without a title.
                self._send_next_codelens_resolve()
                continue
            if id == self._inflight_codelens_resolve_id:
                self._inflight_codelens_resolve_id = String("")
                if msg.result and msg.result.value().is_object():
                    var title = _codelens_title_of(msg.result.value())
                    if len(title.as_bytes()) > 0:
                        self._codelens_accum.append(TextEditEntry(
                            self._codelens_resolve_row, 0,
                            self._codelens_resolve_row, 0,
                            String("‹") + title + String("›"),
                        ))
                        self._codelens.publish(self._codelens_accum.copy())
                # Chain the next queued lens, if any.
                self._send_next_codelens_resolve()
                continue
            if self._doclinks.owns(id):
                var parsed = DocumentLinkParse()
                if msg.result:
                    parsed = _parse_document_links_full(msg.result.value())
                self._doclinks.id = String("")
                self._start_document_link_resolves(parsed)
                continue
            var dl_slot = self._dl_resolve.slot(id)
            if dl_slot >= 0:
                if msg.result and msg.result.value().is_object():
                    var target = _document_link_target_of(msg.result.value())
                    if len(target.as_bytes()) > 0:
                        self._dl_accum[dl_slot].new_text = target
                self._dl_resolve.drop(id)
                # Re-publish the whole list, not just this link.
                self._publish_document_links()
                continue
            if self._selrange.owns(id):
                self._selrange.settle[_parse_selection_ranges](msg.result)
                continue
            if self._hierarchy.owns(id):
                # Prepare done → fire the follow-up (incomingCalls /
                # supertypes) with the first prepared item echoed back.
                self._hierarchy.id = String("")
                if msg.result and msg.result.value().is_array() \
                        and msg.result.value().array_len() > 0:
                    var fp = json_object()
                    fp.put_owned(
                        String("item"),
                        take_json(msg.result.value().arr_v[0]),
                    )
                    # Local copy: ``_send_request`` takes ``mut self``, so
                    # handing it a field of ``self`` directly aliases.
                    var hier_method = self._hierarchy_followup
                    try:
                        self._inflight_hier_followup_id = \
                            self._send_request(hier_method, fp)
                    except:
                        self._inflight_hier_followup_id = String("")
                        self._hierarchy.finish(List[DefinitionResolved]())
                else:
                    # No symbol here → empty result so the host can notice.
                    self._hierarchy.finish(List[DefinitionResolved]())
                continue
            if len(self._inflight_hier_followup_id.as_bytes()) > 0 \
                    and id == self._inflight_hier_followup_id:
                var hits = List[DefinitionResolved]()
                if msg.result:
                    hits = _parse_hierarchy_result(msg.result.value())
                self._hierarchy.finish(hits^)
                self._inflight_hier_followup_id = String("")
                continue
            if self._colors.owns(id):
                self._colors.settle[_parse_document_colors](msg.result)
                continue
            var pull_slot = -1
            for pk in range(len(self._pull_diags)):
                if self._pull_diags[pk].key == id:
                    pull_slot = pk
                    break
            if pull_slot >= 0:
                # Pull-diagnostics report. A "full" report (or any object
                # carrying ``items``) replaces the bucket — an empty
                # ``items`` array is a valid "all clear". An "unchanged"
                # report means reuse what we have, so leave the bucket be.
                var ppath = self._pull_diags.pop(pull_slot).text
                if msg.result and msg.result.value().is_object():
                    var rep = msg.result.value().copy()
                    var kind = json_get_string(rep, String("kind"))
                    if kind != String("unchanged"):
                        var items_opt = rep.object_get(String("items"))
                        var pdiags = List[Diagnostic]()
                        if items_opt and items_opt.value().is_array():
                            pdiags = _parse_diagnostics_array(items_opt.value())
                        if self._logging():
                            _lsp_debug_write(
                                String("← pull diagnostic response id=") + id
                                + String(" path=") + ppath
                                + String(" count=") + String(len(pdiags)),
                            )
                        self._store_diagnostics(ppath, pdiags^)
                self._clear_diag_inflight(ppath, 0)
                continue
            if self._willsave.owns(id):
                self._willsave.settle[_parse_text_edits](msg.result)
                self._log_response(
                    String("willSaveWaitUntil"), id, String("edits"), len(self._willsave.value),
                )
                continue
        return resolved

    # --- internals ---------------------------------------------------------

    def _esbonio_config(self) -> Optional[JsonValue]:
        """Build the ``esbonio`` config object esbonio v2 expects from
        ``workspace/configuration``. Returns ``None`` when the server
        isn't esbonio or no Sphinx ``conf.py`` was found — caller
        responds with ``null`` for that item (esbonio runs no
        diagnostics module in that case, which is fine).

        Why we *must* do this: esbonio v2 dropped auto-discovery — if
        we don't point at a ``conf.py``, no Sphinx instance ever
        starts and the server is silent for every .rst buffer. Schema:

            {"sphinx": {
                "pythonCommand": ["/path/to/python"],
                "buildCommand": ["sphinx-build", "-M", "dirhtml", "<src>", "<out>"]
            }}
        """
        if self._language_id != String("rst"):
            return Optional[JsonValue]()
        var root = _uri_to_path(self._root_uri)
        if len(root.as_bytes()) == 0:
            return Optional[JsonValue]()
        var src_dir_opt = _find_sphinx_source_dir(root)
        if not src_dir_opt:
            return Optional[JsonValue]()
        var src_dir = src_dir_opt.value()
        # Python: prefer a project-local venv (most likely to have the
        # docs' own deps + extensions installed) and fall back to the
        # interpreter that ships beside the esbonio binary so Sphinx
        # itself is available even if no venv exists.
        var python_cmd = _python_for_sphinx(root, self._argv)
        var sphinx = json_object()
        var python_arr = json_array()
        python_arr.append(json_str(python_cmd))
        sphinx.put(String("pythonCommand"), python_arr)
        var build_arr = json_array()
        build_arr.append(json_str(String("sphinx-build")))
        build_arr.append(json_str(String("-M")))
        build_arr.append(json_str(String("dirhtml")))
        build_arr.append(json_str(src_dir))
        # Output dir in the user's temp folder so we don't pollute the
        # project tree with build artefacts. esbonio uses this for
        # diagnostics, not for actually serving HTML.
        var out_dir = debug_log_path(
            String("turbokod-esbonio-") + basename(src_dir) + String("-build"),
        )
        build_arr.append(json_str(out_dir))
        sphinx.put(String("buildCommand"), build_arr)
        var cfg = json_object()
        cfg.put(String("sphinx"), sphinx)
        _lsp_debug_log(
            String("esbonio config: src=") + src_dir
            + String(" python=") + python_cmd
            + String(" out=") + out_dir,
        )
        return Optional[JsonValue](cfg^)

    def _absorb_stderr(mut self):
        """Drain whatever's available on the server's stderr pipe and
        append it to the rolling capture. Bounded at 16 KB so a chatty
        server can't blow up our memory; once at the cap, new bytes are
        dropped (the head usually has the actionable diagnostic)."""
        if self._channel != 0:
            var ch = channel_at(self._channel)
            ch[].drain_stderr()
            # The channel's log only grows (to its cap): copy on change.
            if len(ch[].stderr_log.text.as_bytes()) \
                    != len(self._stderr_log.text.as_bytes()):
                self._stderr_log = ch[].stderr_log.copy()
            return
        if self._stderr_log.full():
            # Still drained, so the server never blocks on a full pipe.
            _ = self.client.process.drain_stderr()
            return
        self._stderr_log.append(self.client.process.drain_stderr())

    def _on_publish_diagnostics(mut self, params: JsonValue):
        """Replace (not merge) the bucket for the published URI. The
        spec is clear: ``publishDiagnostics`` is the *current* set, not
        an incremental update — empty array means "all clear.

        When the server echoes a ``version`` field (LSP 3.15+, supported
        by pyright / ty / rust-analyzer / typescript-language-server …)
        we compare against the latest version we sent in didChange and
        drop the payload when it's older. Without this gate, a slow
        server that's still type-checking version N can publish stale
        diagnostics after the editor has already advanced to N+3 — the
        squiggly underline flashes back to wrong positions and only
        snaps forward once the in-flight catches up. Servers that don't
        send ``version`` (older builds, partial impls) fall through to
        the accept path so we don't break them."""
        if not params.is_object():
            return
        # Borrowed by index: ``object_get`` would copy the whole array.
        var ui = params.object_index(String("uri"))
        var di = params.object_index(String("diagnostics"))
        if ui < 0 or di < 0:
            return
        if not params.obj_v[ui].value.is_string():
            return
        if not params.obj_v[di].value.is_array():
            return
        var path = _uri_to_path(params.obj_v[ui].value.str_v)
        if len(path.as_bytes()) == 0:
            return
        var pub_version = 0  # 0 ⇒ server didn't echo a version
        var version_opt = params.object_get(String("version"))
        if version_opt and version_opt.value().is_int():
            pub_version = version_opt.value().as_int()
            for ref d in self._docs:
                if d.path == path:
                    if pub_version < d.version:
                        if self._logging():
                            _lsp_debug_write(
                                String("← publishDiagnostics (dropped stale) lang=")
                                + self._language_id
                                + String(" path=") + path
                                + String(" pub_version=") + String(pub_version)
                                + String(" latest_version=")
                                + String(d.version),
                            )
                        # Stale: don't clear the in-flight flag — the
                        # newer didChange we already sent is still
                        # genuinely waiting for an answer.
                        return
                    break
        # Clear the analyzing-edits spinner now that this path's
        # diagnostics have been refreshed (or the server publishes
        # without versions and we have to assume any reply covers the
        # latest send).
        self._clear_diag_inflight(path, pub_version)
        var diags = _parse_diagnostics_array(params.obj_v[di].value)
        if self._logging():
            _lsp_debug_write(
                String("← publishDiagnostics lang=") + self._language_id
                + String(" path=") + path
                + String(" count=") + String(len(diags)),
            )
        self._store_diagnostics(path, diags^)

    def _store_diagnostics(mut self, path: String, var diags: List[Diagnostic]):
        """Replace (not merge) the diagnostic bucket for ``path`` and mark
        it unconsumed so the host re-applies on the next frame. Shared by
        the push (``publishDiagnostics``) and pull (``textDocument/
        diagnostic``) paths. An empty set for a file that isn't open
        deletes the bucket: there is nothing to show on a reopen."""
        var drop = len(diags) == 0 and self._doc_index(path) < 0
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                if drop:
                    _ = self._diagnostic_buckets.pop(k)
                    return
                self._diagnostic_buckets[k].diags = diags^
                self._diagnostic_buckets[k].consumed = False
                return
        if drop:
            return
        self._diagnostic_buckets.append(
            _DiagnosticBucket(path, diags^, False),
        )

    def _on_progress(mut self, params: JsonValue):
        """Parse a ``$/progress`` notification's ``value`` (a WorkDone
        progress payload). ``begin`` / ``report`` build a one-line note
        (``title — message (pct%)``); ``end`` clears it. Non-WorkDone
        progress (partial results) is ignored."""
        var vi = params.object_index(String("value"))
        if vi < 0 or not params.obj_v[vi].value.is_object():
            return
        ref val = params.obj_v[vi].value
        var kind = json_get_string(val, String("kind"))
        if kind == String("end"):
            self._progress_note = String("")
            self._has_progress_note = True
            return
        if kind != String("begin") and kind != String("report"):
            return
        var note = self._language_id
        var title = json_get_string(val, String("title"))
        if len(title.as_bytes()) > 0:
            note = note + String(": ") + title
        var message = json_get_string(val, String("message"))
        if len(message.as_bytes()) > 0:
            note = note + String(" — ") + message
        var pi = val.object_index(String("percentage"))
        if pi >= 0 and val.obj_v[pi].value.is_int():
            note = note + String(" (") + String(val.obj_v[pi].value.as_int()) \
                + String("%)")
        self._progress_note = note^
        self._has_progress_note = True

    def _on_show_message(mut self, params: JsonValue):
        """Parse ``window/showMessage`` into a parked status string."""
        if not params.is_object():
            return
        var msg_opt = params.object_get(String("message"))
        if not msg_opt or not msg_opt.value().is_string():
            return
        var m = msg_opt.value().as_str()
        if len(m.as_bytes()) == 0:
            return
        self._server_message = self._language_id + String(": ") + m
        self._has_server_message = True

    def _on_log_trace(mut self, params: JsonValue):
        """Append a ``$/logTrace`` payload to the captured log.

        ``message`` is the line; the optional ``verbose`` field carries the
        detail (a full JSON dump, when the server is in ``verbose`` trace
        mode). Both go in — the whole point of trace output is the detail."""
        if not params.is_object() or self._log_capture.full():
            return
        var line = json_get_string(params, String("message"))
        var v_opt = params.object_get(String("verbose"))
        if v_opt and v_opt.value().is_string():
            var detail = v_opt.value().as_str()
            if len(detail.as_bytes()) > 0:
                line = line + String("\n") + detail
        if len(line.as_bytes()) == 0:
            return
        self._append_log(String("[trace] ") + line)

    def _on_log_message(mut self, params: JsonValue):
        """Append a ``window/logMessage`` to the rolling log capture,
        prefixed by severity (E/W/I/L for error/warning/info/log). Unlike
        ``showMessage`` this is log-stream output, not a user toast — it
        lives in the LSP info window, not the status bar."""
        if not params.is_object() or self._log_capture.full():
            return
        var msg_opt = params.object_get(String("message"))
        if not msg_opt or not msg_opt.value().is_string():
            return
        var m = msg_opt.value().as_str()
        if len(m.as_bytes()) == 0:
            return
        var sev = String("L")
        var type_opt = params.object_get(String("type"))
        if type_opt and type_opt.value().is_int():
            var t = type_opt.value().as_int()
            if t == 1:
                sev = String("E")
            elif t == 2:
                sev = String("W")
            elif t == 3:
                sev = String("I")
        self._append_log(String("[") + sev + String("] ") + m)

    def _append_log(mut self, var line: String):
        """Append one line (a newline is added) to the 16 KB-capped log
        capture; once full, further text is dropped (the head is usually
        the most useful). Callers check ``full()`` before formatting."""
        self._log_capture.append_line(line)

    def captured_log(self) -> String:
        """The server's protocol-level log (``window/logMessage`` +
        ``telemetry/event``) captured since spawn, capped at 16 KB."""
        return self._log_capture.text

    def has_pending_progress(self) -> Bool:
        return self._has_progress_note

    def take_progress_note(mut self) -> String:
        var out = self._progress_note^
        self._progress_note = String("")
        self._has_progress_note = False
        return out^

    def has_pending_server_message(self) -> Bool:
        return self._has_server_message

    def take_server_message(mut self) -> String:
        var out = self._server_message^
        self._server_message = String("")
        self._has_server_message = False
        return out^

    def has_message_request(self) -> Bool:
        return self._msgreq_pending

    def message_request_text(self) -> String:
        return self._msgreq_message

    def message_request_actions(self) -> List[String]:
        return self._msgreq_actions.copy()

    def respond_message_request(mut self, action_index: Int):
        """Reply to the parked ``window/showMessageRequest`` with the chosen
        ``MessageActionItem`` (``action_index`` into
        ``message_request_actions``) or null when ``action_index < 0``
        (the user dismissed)."""
        if not self._msgreq_pending or not self._msgreq_id:
            return
        var id = self._msgreq_id.value().copy()
        var result = json_null()
        if 0 <= action_index and action_index < len(self._msgreq_actions):
            var item = json_object()
            item.put(
                String("title"),
                json_str(self._msgreq_actions[action_index]),
            )
            result = item^
        try:
            self._reply(id, result)
        except e:
            print("lsp: showMessageRequest response:", String(e))
        self._msgreq_pending = False
        self._msgreq_id = Optional[JsonValue]()
        self._msgreq_message = String("")
        self._msgreq_actions = List[String]()

    def has_show_document(self) -> Bool:
        return self._show_doc_pending

    def show_document_external(self) -> Bool:
        return self._show_doc_external

    def show_document_uri(self) -> String:
        return self._show_doc_uri

    def show_document_path(self) -> String:
        """Filesystem path for a non-external showDocument uri (``file://``
        stripped + percent-decoded). Empty for an external/http uri."""
        return _uri_to_path(self._show_doc_uri)

    def show_document_line(self) -> Int:
        return self._show_doc_line

    def show_document_char(self) -> Int:
        return self._show_doc_char

    def clear_show_document(mut self):
        self._show_doc_pending = False
        self._show_doc_uri = String("")
        self._show_doc_external = False
        self._show_doc_line = -1
        self._show_doc_char = 0

    def _apply_capability_registration(
        mut self, method: String, options: JsonValue,
    ):
        """Merge one ``client/registerCapability`` entry into the cached
        server ``capabilities`` so ``server_supports`` reflects a feature
        the server enabled after initialize. ``options`` is the entry's
        ``registerOptions`` (or null); stored verbatim when it's an object
        so capability sub-fields (``resolveProvider``, the semantic-tokens
        legend, formatting trigger chars, …) survive, else a bare
        ``true``. Methods with no ``capabilities`` field (e.g.
        ``workspace/didChangeWatchedFiles``) map to "" and are skipped."""
        if method == String("workspace/didChangeWatchedFiles"):
            # No ``capabilities`` field — record interest so the host's
            # on-save hook starts pushing watched-file events to us.
            self._watches_files = True
            return
        var key = _capability_key_for_method(method)
        if len(key.as_bytes()) == 0:
            return
        var caps = self._capabilities.value().copy() \
            if self._capabilities else json_object()
        if not caps.is_object():
            caps = json_object()
        if options.is_object():
            caps.put(key, options.copy())
        else:
            caps.put(key, json_bool(True))
        self._capabilities = Optional[JsonValue](caps^)

    def _remove_capability_registration(mut self, method: String):
        """Undo a registration on ``client/unregisterCapability`` by
        writing ``false`` for the mapped key — ``server_supports`` treats
        ``false`` as unsupported, and the object has no key-removal
        primitive."""
        if method == String("workspace/didChangeWatchedFiles"):
            self._watches_files = False
            return
        var key = _capability_key_for_method(method)
        if len(key.as_bytes()) == 0 or not self._capabilities:
            return
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return
        caps.put(key, json_bool(False))
        self._capabilities = Optional[JsonValue](caps^)

    def _handle_server_request(mut self, msg: LspIncoming):
        """Reply to a server-issued request.

        Most LSP servers occasionally issue requests *to* the client
        (workspace/configuration, client/registerCapability, …) and
        block on the response. Without a reply taplo never publishes
        diagnostics for any TOML buffer — the "analyzing edits…"
        spinner spins indefinitely. We keep the handler small: answer
        the common probes with a benign default, and reject anything
        unknown with MethodNotFound so the server falls back instead
        of waiting for an answer we'll never send.
        """
        if not msg.id or not msg.method:
            return
        var id = msg.id.value().copy()
        # ``_id_to_string`` is purely for logging — the response itself
        # carries the original JsonValue id verbatim so JSON-RPC pairing
        # works regardless of integer-vs-string typing.
        var id_label = json_rpc_id(id)
        var method = msg.method.value()
        try:
            if method == String("workspace/configuration"):
                # Reply with one entry per requested ``items[i]``,
                # matching by section name. Unknown sections become
                # ``null`` (= "use defaults"). The only section we
                # actively configure today is ``esbonio``, which needs
                # an explicit Sphinx project pointer to run anything
                # — see ``_esbonio_config`` for the discovery flow.
                var items_arr_opt = Optional[JsonValue]()
                if msg.params and msg.params.value().is_object():
                    var items = msg.params.value().object_get(
                        String("items"),
                    )
                    if items and items.value().is_array():
                        items_arr_opt = Optional[JsonValue](
                            items.value().copy(),
                        )
                var result = json_array()
                var n = 0
                if items_arr_opt:
                    var items_arr = items_arr_opt.value().copy()
                    n = items_arr.array_len()
                    for i in range(n):
                        var item = items_arr.array_at(i)
                        var section = String("")
                        if item.is_object():
                            section = json_get_string(item, String("section"), section)
                        if section == String("esbonio"):
                            var cfg_opt = self._esbonio_config()
                            if cfg_opt:
                                result.append(cfg_opt.value().copy())
                                continue
                        result.append(json_null())
                self._log_server_request(
                    method, id_label, String(" items=") + String(n),
                )
                self._reply(id, result)
                return
            if method == String("client/registerCapability"):
                # Merge each registration into the cached capabilities so
                # ``server_supports`` sees features the server turns on
                # *after* initialize. Many servers (rust-analyzer most
                # notably) advertise an almost-empty static capabilities
                # blob and register the real providers dynamically; without
                # this merge every dynamically-registered feature looks
                # unsupported and we never send the request. Reply success
                # regardless — we always accept.
                var merged = 0
                if msg.params and msg.params.value().is_object():
                    var regs_opt = msg.params.value().object_get(
                        String("registrations"),
                    )
                    if regs_opt and regs_opt.value().is_array():
                        var regs = regs_opt.value().copy()
                        for ri in range(regs.array_len()):
                            var reg = regs.array_at(ri)
                            if not reg.is_object():
                                continue
                            var m_opt = reg.object_get(String("method"))
                            if not m_opt or not m_opt.value().is_string():
                                continue
                            var ro = reg.object_get(String("registerOptions"))
                            var options = ro.value().copy() if ro \
                                else json_null()
                            self._apply_capability_registration(
                                m_opt.value().as_str(), options,
                            )
                            merged += 1
                self._log_server_request(
                    method, id_label, String(" merged=") + String(merged),
                )
                self._reply(id, json_null())
                return
            if method == String("client/unregisterCapability"):
                # Mirror of the register path: write ``false`` for each
                # unregistered method's capability key so ``server_supports``
                # stops reporting it. (The spec misspells the field as
                # ``unregisterations`` — match it verbatim.)
                if msg.params and msg.params.value().is_object():
                    var uns_opt = msg.params.value().object_get(
                        String("unregisterations"),
                    )
                    if uns_opt and uns_opt.value().is_array():
                        var uns = uns_opt.value().copy()
                        for ui in range(uns.array_len()):
                            var un = uns.array_at(ui)
                            if not un.is_object():
                                continue
                            var m_opt = un.object_get(String("method"))
                            if m_opt and m_opt.value().is_string():
                                self._remove_capability_registration(
                                    m_opt.value().as_str(),
                                )
                self._log_server_request(method, id_label, String(" (removed)"))
                self._reply(id, json_null())
                return
            if method == String("window/workDoneProgress/create"):
                # Acknowledge with success. We don't track the progress
                # token itself, but accepting lets the server proceed
                # instead of stalling on the probe.
                self._log_server_request(method, id_label, String(" (acked)"))
                self._reply(id, json_null())
                return
            if method == String("workspace/applyEdit"):
                # Parse the WorkspaceEdit and park it for the host to apply
                # project-wide next frame; reply ``applied: true``
                # optimistically (the host opens/edits/saves the files).
                var edits = List[CodeActionFileEdit]()
                if msg.params and msg.params.value().is_object():
                    var edit_opt = msg.params.value().object_get(
                        String("edit"),
                    )
                    if edit_opt and edit_opt.value().is_object():
                        edits = _parse_workspace_edit_changes(edit_opt.value())
                var edit_count = len(edits)
                var applied = edit_count > 0
                self._resolved_applyedit = edits^
                self._has_resolved_applyedit = applied
                var resp = json_object()
                resp.put(String("applied"), json_bool(applied))
                self._log_server_request(
                    method, id_label, String(" files=") + String(edit_count),
                )
                self._reply(id, resp)
                return
            if method == String("window/showMessageRequest"):
                # Park the message + action titles + request id for a modal;
                # the host replies via ``respond_message_request`` once the
                # user picks. A request with no actions is effectively a
                # showMessage with a mandatory (null) reply — surface it and
                # answer null now. A second request while one is pending is
                # declined (null) so the first isn't orphaned.
                var rmsg = String("")
                var ractions = List[String]()
                if msg.params and msg.params.value().is_object():
                    var p = msg.params.value().copy()
                    rmsg = json_get_string(p, String("message"), rmsg)
                    var a_opt = p.object_get(String("actions"))
                    if a_opt and a_opt.value().is_array():
                        var arr = a_opt.value().copy()
                        for ai in range(arr.array_len()):
                            var item = arr.array_at(ai)
                            if item.is_object():
                                var t_opt = item.object_get(String("title"))
                                if t_opt and t_opt.value().is_string():
                                    ractions.append(t_opt.value().as_str())
                if self._msgreq_pending or len(ractions) == 0:
                    if not self._msgreq_pending and len(rmsg.as_bytes()) > 0:
                        self._server_message = self._language_id \
                            + String(": ") + rmsg
                        self._has_server_message = True
                    self._reply(id, json_null())
                    return
                self._msgreq_id = Optional[JsonValue](id.copy())
                self._msgreq_message = rmsg^
                self._msgreq_actions = ractions^
                self._msgreq_pending = True
                self._log_server_request(
                    method, id_label, String(" actions=") + String(len(self._msgreq_actions)),
                )
                return
            if method == String("workspace/workspaceFolders"):
                # The server asks for the open workspace folders. Reply with
                # our single root (or an empty array if none — spec-legal).
                # Some servers (pyright) gate module resolution on this.
                var folders = json_array()
                if len(self._root_uri.as_bytes()) > 0:
                    folders.append_owned(workspace_folder(self._root_uri))
                self._log_server_request(method, id_label, String(""))
                self._reply(id, folders)
                return
            if method == String("window/showDocument"):
                # Park the open request (file → editor, or external URL) for
                # the host to act on next frame; reply success optimistically
                # like workspace/applyEdit.
                var uri = String("")
                var external = False
                var sel_line = -1
                var sel_char = 0
                if msg.params and msg.params.value().is_object():
                    var p = msg.params.value().copy()
                    uri = json_get_string(p, String("uri"), uri)
                    external = json_get_bool(p, String("external"), external)
                    var sel_opt = p.object_get(String("selection"))
                    if sel_opt and sel_opt.value().is_object():
                        var pos = _start_pos_of(sel_opt.value())
                        sel_line = pos[0]
                        sel_char = pos[1]
                self._show_doc_uri = uri^
                self._show_doc_external = external
                self._show_doc_line = sel_line
                self._show_doc_char = sel_char
                self._show_doc_pending = len(self._show_doc_uri.as_bytes()) > 0
                var ok = json_object()
                ok.put(String("success"), json_bool(self._show_doc_pending))
                self._log_server_request(
                    method, id_label, String(" external=") + String(external),
                )
                self._reply(id, ok)
                return
            if method == String("workspace/codeLens/refresh") \
                    or method == String("workspace/inlayHint/refresh") \
                    or method == String("workspace/inlineValue/refresh") \
                    or method == String("workspace/foldingRange/refresh") \
                    or method == String(
                        "workspace/textDocumentContent/refresh",
                    ):
                # "My previous answers for this feature are stale." Reply
                # null (the spec's success shape) and raise a flag the host
                # drains to drop its debounce key and re-request. Replying
                # MethodNotFound instead made the server stop asking, which
                # is why a rust-analyzer build finishing never updated the
                # code lenses already on screen.
                self._refresh_doc_features = True
                self._log_server_request(method, id_label, String(" (queued refresh)"))
                self._reply(id, json_null())
                return
            if method == String("workspace/diagnostic/refresh"):
                # Same, for the pull-diagnostics model. Clearing
                # ``_pulled_paths`` is what actually re-arms it: the host's
                # gate is "did the buffer change, or have we never pulled
                # it?", so forgetting that we pulled makes the next tick
                # re-request without the host needing to know about refresh
                # at all.
                self._pulled_paths = List[String]()
                self._refresh_diagnostics = True
                self._log_server_request(method, id_label, String(" (re-arm pull)"))
                self._reply(id, json_null())
                return
            # Unknown method: MethodNotFound (-32601) so the server
            # stops waiting.
            self._log_server_request(method, id_label, String(" (MethodNotFound)"))
            self._reply_error(
                id, -32601,
                String("method not implemented by turbokod: ") + method,
            )
        except e:
            print("lsp: send_error (MethodNotFound) id=", id_label, ":", String(e))

    def _on_initialize_response(mut self, msg: LspIncoming):
        # Spec: send the ``initialized`` notification before any other request,
        # then we're free to didOpen / definition / etc.
        try:
            self._send_notification(
                String("initialized"), json_object(),
            )
        except e:
            self.state = _STATE_FAILED
            self.failure_reason = String("initialized failed: ") + String(e)
            return
        self.state = _STATE_READY
        # Record the negotiated position encoding. With ``utf-8`` the
        # editor's byte columns are valid LSP ``character`` offsets as-is;
        # otherwise the server uses ``utf-16`` and multibyte columns can be
        # off (logged for diagnosis).
        if msg.result and msg.result.value().is_object():
            var caps_opt = msg.result.value().object_get(String("capabilities"))
            if caps_opt and caps_opt.value().is_object():
                # Stash the whole capabilities object so ``server_supports``
                # can gate every optional feature request off it.
                self._capabilities = Optional[JsonValue](
                    caps_opt.value().copy(),
                )
                var enc_opt = caps_opt.value().object_get(
                    String("positionEncoding"),
                )
                if enc_opt and enc_opt.value().is_string():
                    self._position_encoding = enc_opt.value().as_str()
        self._position_encoding_tag = encoding_from_name(self._position_encoding)
        self._remap.enc = self._position_encoding_tag
        # Normalize the display string too, so an unrecognized value is
        # reported as the encoding we'll actually convert against rather
        # than as whatever the server claimed.
        self._position_encoding = encoding_name(self._position_encoding_tag)
        if self._position_encoding_tag != POS_UTF8:
            if self._logging():
                _lsp_debug_write(
                    String("position encoding negotiated as '")
                    + self._position_encoding
                    + String("' (not utf-8); converting columns per line"),
                )
        # Drain the queue of opens that arrived before we were ready.
        var opens = List[_IdText]()
        swap(opens, self._pending_opens)
        for ref o in opens:
            self._send_open_or_change(o.key, o.text)

    def _doc_index(self, path: String) -> Int:
        """Index of the open document ``path`` in ``_docs``, or -1."""
        for k in range(len(self._docs)):
            if self._docs[k].path == path:
                return k
        return -1

    def _doc_uri(self, path: String) -> String:
        """``_path_to_uri(path)``, from the open document's cache when
        there is one."""
        var idx = self._doc_index(path)
        if idx >= 0:
            return self._docs[idx].uri
        return _path_to_uri(path)

    def _text_doc(self, path: String) -> JsonValue:
        """The ``{"uri": ...}`` TextDocumentIdentifier for ``path``.
        Callers that need a richer TextDocumentItem (languageId / version)
        add those fields to the returned object."""
        var doc = json_object()
        doc.put_owned(String("uri"), json_str(self._doc_uri(path)))
        return doc^

    def _position_params(
        self, path: String, line: Int, character: Int,
    ) -> JsonValue:
        """The ``{textDocument:{uri}, position:{line,character}}`` params
        shared by the definition / references / completion / hover
        requests. Callers add request-specific fields (e.g. ``context``)
        to the returned object."""
        var params = self._doc_params(path)
        params.put_owned(String("position"), _lsp_position(line, character))
        return params^

    def _sync_for_request(mut self, path: String, var text: String) -> Bool:
        """Bring the server's copy of ``path`` up to ``text`` before a
        request about it; False (nothing sent) unless the server is ready."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        return True

    def _doc_params(self, path: String) -> JsonValue:
        """``{textDocument: {uri}}`` — the params of a whole-document
        request, for the caller to add to."""
        var params = json_object()
        params.put_owned(String("textDocument"), self._text_doc(path))
        return params^

    def _send_open_or_change(mut self, path: String, var text: String):
        var idx = self._doc_index(path)
        if idx < 0:
            self._docs.append(
                _OpenDoc(path, _path_to_uri(path), 1, text.copy()),
            )
            self._remap.invalidate(path)
            self._send_did_open(path, text^)
        else:
            # Unchanged text → the server already has this exact content.
            # Skip the didChange so cursor-driven requests don't trigger a
            # spurious re-analysis (the "analyzing edits…" flicker).
            ref d = self._docs[idx]
            # Usually the very buffer it was handed last time: settled by
            # the pointer, not by comparing the whole file per request.
            if same_text(d.text, text):
                # Same content: keep the caller's copy, which is the
                # editor's cached snapshot, so the two share one buffer
                # rather than each holding the file.
                d.text = text^
                return
            d.version += 1
            var version = d.version
            d.text = text.copy()
            self._remap.invalidate(path)
            self._send_did_change(path, version, text^)

    def diagnostics_inflight_ms_for(mut self, path: String) -> Int:
        """Elapsed milliseconds since the most recent didOpen / didChange
        for ``path`` if we're still waiting for the server to reply
        with a matching ``publishDiagnostics``; ``-1`` when no refresh
        is in flight (server already responded, never sent for this
        path, or we gave up waiting). Driven by the status bar's
        "analyzing edits…" spinner so the user can see when squiggles
        are stale because the server hasn't caught up yet.

        Caps the wait at ``_DIAG_INFLIGHT_TIMEOUT_MS``: some servers
        push diagnostics only for project-scoped files and silently
        ignore the rest (esbonio doesn't publish for .rst files
        outside a Sphinx project; pyright with no ``pyproject.toml``
        sometimes drops diagnostics for ad-hoc files; …). Without
        a cap the spinner spins forever for those buffers. If real
        diagnostics arrive later they still process correctly — the
        cap only affects what the user sees, not internal state.
        """
        var k = 0
        while k < len(self._diag_inflight_paths):
            if self._diag_inflight_paths[k] == path:
                var elapsed = monotonic_ms() - self._diag_inflight_since_ms[k]
                if elapsed < 0:
                    return 0
                if elapsed >= _DIAG_INFLIGHT_TIMEOUT_MS:
                    _ = self._diag_inflight_paths.pop(k)
                    _ = self._diag_inflight_versions.pop(k)
                    _ = self._diag_inflight_since_ms.pop(k)
                    return -1
                return elapsed
            k += 1
        return -1

    def _mark_diag_inflight(mut self, path: String, version: Int):
        """Record that a didOpen / didChange for ``path`` at ``version``
        is now in flight. Replaces any prior entry for this path so a
        rapid burst of edits collapses to "the latest send is what
        we're waiting for"."""
        var now = monotonic_ms()
        for k in range(len(self._diag_inflight_paths)):
            if self._diag_inflight_paths[k] == path:
                self._diag_inflight_versions[k] = version
                self._diag_inflight_since_ms[k] = now
                return
        self._diag_inflight_paths.append(path)
        self._diag_inflight_versions.append(version)
        self._diag_inflight_since_ms.append(now)

    def _clear_diag_inflight(mut self, path: String, pub_version: Int):
        """Drop the in-flight tracking for ``path`` if the published
        version covers the latest send. ``pub_version <= 0`` means the
        server didn't echo a version (older builds, partial impls); we
        clear unconditionally so the spinner doesn't stick on those
        servers. With a real version, only clear when the server has
        caught up to the newest send we made — otherwise a slow server
        publishing N while we've moved on to N+1 would prematurely
        hide the spinner."""
        var k = 0
        while k < len(self._diag_inflight_paths):
            if self._diag_inflight_paths[k] == path:
                if pub_version <= 0 \
                        or pub_version >= self._diag_inflight_versions[k]:
                    _ = self._diag_inflight_paths.pop(k)
                    _ = self._diag_inflight_versions.pop(k)
                    _ = self._diag_inflight_since_ms.pop(k)
                    return
                return
            k += 1

    def _send_did_open(mut self, path: String, var text: String):
        if self._logging():
            _lsp_debug_write(
                String("→ didOpen lang=") + self._language_id
                + String(" path=") + path
                + String(" uri=") + _path_to_uri(path)
                + String(" text_len=") + String(len(text.as_bytes())),
            )
        var params = json_object()
        var doc = self._text_doc(path)
        doc.put(String("languageId"), json_str(self._language_id))
        doc.put(String("version"), json_int(1))
        doc.put_owned(String("text"), json_str(text^))
        params.put_owned(String("textDocument"), doc^)
        self._notify(String("textDocument/didOpen"), params, path)
        self._mark_diag_inflight(path, 1)

    def _send_did_change(mut self, path: String, version: Int, var text: String):
        if self._logging():
            _lsp_debug_write(
                String("→ didChange lang=") + self._language_id
                + String(" path=") + path
                + String(" uri=") + _path_to_uri(path)
                + String(" version=") + String(version)
                + String(" text_len=") + String(len(text.as_bytes())),
            )
        var params = json_object()
        var doc = self._text_doc(path)
        doc.put(String("version"), json_int(version))
        params.put_owned(String("textDocument"), doc^)
        var changes = json_array()
        var change = json_object()
        # Full-document sync: a single change with no ``range``.
        change.put_owned(String("text"), json_str(text^))
        changes.append_owned(change^)
        params.put_owned(String("contentChanges"), changes^)
        self._notify(
            String("textDocument/didChange"), params,
            path + String(" v=") + String(version),
        )
        self._mark_diag_inflight(path, version)


# --- response parsing ------------------------------------------------------


def _find_sphinx_source_dir(root: String) -> Optional[String]:
    """Locate a Sphinx ``conf.py`` reachable from the workspace root.
    Returns the directory containing it (the Sphinx *source dir*) or
    ``None``. Checks the conventional layouts in priority order —
    cheaper than walking the tree, and the ordering is "more specific
    first" so e.g. ``docs/source/`` wins over a bare ``docs/`` when
    both contain a ``conf.py`` (which would itself be weird).
    """
    var candidates = List[String]()
    candidates.append(join_path(root, String("docs/source")))
    candidates.append(join_path(root, String("doc/source")))
    candidates.append(join_path(root, String("source")))
    candidates.append(join_path(root, String("docs")))
    candidates.append(join_path(root, String("doc")))
    candidates.append(root)
    for i in range(len(candidates)):
        var conf_path = join_path(candidates[i], String("conf.py"))
        if stat_file(conf_path).ok:
            return Optional[String](candidates[i])
    return Optional[String]()


def _python_for_sphinx(root: String, server_argv: List[String]) -> String:
    """Pick a Python interpreter for Sphinx. Project-local venvs win
    because they're most likely to have the docs' own deps + Sphinx
    extensions installed; the server's bundled Python is the fallback
    (esbonio depends on Sphinx, so its interpreter at least has the
    package available — autodoc on third-party project modules might
    fail, but the server at least starts).
    """
    var venv_candidates = List[String]()
    venv_candidates.append(join_path(root, String(".venv/bin/python")))
    venv_candidates.append(join_path(root, String("venv/bin/python")))
    venv_candidates.append(join_path(root, String(".venv/bin/python3")))
    venv_candidates.append(join_path(root, String("venv/bin/python3")))
    for i in range(len(venv_candidates)):
        if stat_file(venv_candidates[i]).ok:
            return venv_candidates[i]
    # Fall back to the Python next to the server binary. e.g. when the
    # server resolved to ``/Users/x/.pyenv/versions/3.12.6/bin/esbonio``
    # we return ``/Users/x/.pyenv/versions/3.12.6/bin/python``.
    if len(server_argv) > 0:
        var server_bin = server_argv[0]
        var dir = parent_path(server_bin)
        var sibling = join_path(dir, String("python"))
        if stat_file(sibling).ok:
            return sibling
        var sibling3 = join_path(dir, String("python3"))
        if stat_file(sibling3).ok:
            return sibling3
    return String("python3")


def _capability_key_for_method(method: String) -> String:
    """Map an LSP feature method name (as it appears in a
    ``client/registerCapability`` registration) to the matching server
    ``capabilities`` field name, so a dynamic registration updates the
    very object ``server_supports`` reads. Returns "" for methods with no
    capabilities-object field (notifications like
    ``workspace/didChangeWatchedFiles`` carry no provider flag)."""
    if method == String("textDocument/completion"):
        return String("completionProvider")
    if method == String("textDocument/hover"):
        return String("hoverProvider")
    if method == String("textDocument/signatureHelp"):
        return String("signatureHelpProvider")
    if method == String("textDocument/declaration"):
        return String("declarationProvider")
    if method == String("textDocument/definition"):
        return String("definitionProvider")
    if method == String("textDocument/typeDefinition"):
        return String("typeDefinitionProvider")
    if method == String("textDocument/implementation"):
        return String("implementationProvider")
    if method == String("textDocument/references"):
        return String("referencesProvider")
    if method == String("textDocument/documentHighlight"):
        return String("documentHighlightProvider")
    if method == String("textDocument/documentSymbol"):
        return String("documentSymbolProvider")
    if method == String("textDocument/codeAction"):
        return String("codeActionProvider")
    if method == String("textDocument/codeLens"):
        return String("codeLensProvider")
    if method == String("textDocument/documentLink"):
        return String("documentLinkProvider")
    if method == String("textDocument/documentColor"):
        return String("colorProvider")
    if method == String("textDocument/formatting"):
        return String("documentFormattingProvider")
    if method == String("textDocument/rangeFormatting"):
        return String("documentRangeFormattingProvider")
    if method == String("textDocument/onTypeFormatting"):
        return String("documentOnTypeFormattingProvider")
    if method == String("textDocument/rename"):
        return String("renameProvider")
    if method == String("textDocument/foldingRange"):
        return String("foldingRangeProvider")
    if method == String("textDocument/selectionRange"):
        return String("selectionRangeProvider")
    if method == String("textDocument/inlayHint"):
        return String("inlayHintProvider")
    if method == String("textDocument/inlineValue"):
        return String("inlineValueProvider")
    if method == String("textDocument/inlineCompletion"):
        return String("inlineCompletionProvider")
    if method == String("textDocument/linkedEditingRange"):
        return String("linkedEditingRangeProvider")
    if method == String("textDocument/prepareCallHierarchy"):
        return String("callHierarchyProvider")
    if method == String("textDocument/prepareTypeHierarchy"):
        return String("typeHierarchyProvider")
    if method == String("textDocument/moniker"):
        return String("monikerProvider")
    if method == String("textDocument/diagnostic"):
        return String("diagnosticProvider")
    if method == String("workspace/symbol"):
        return String("workspaceSymbolProvider")
    if method == String("workspace/executeCommand"):
        return String("executeCommandProvider")
    return String("")


def _parse_prepare_rename_placeholder(v: JsonValue) -> String:
    """Extract the placeholder from a ``prepareRename`` object result. The
    response may be a bare ``Range`` (no placeholder — return empty so the
    host seeds the prompt from the word under the cursor), a
    ``{range, placeholder}`` pair, or ``{defaultBehavior: true}`` (no
    placeholder)."""
    if not v.is_object():
        return String("")
    var ph_opt = v.object_get(String("placeholder"))
    if ph_opt and ph_opt.value().is_string():
        return ph_opt.value().as_str()
    return String("")


def _parse_definition_result(v: JsonValue) -> Optional[DefinitionResolved]:
    """``textDocument/definition`` can return null, a single Location, or
    an array of Location/LocationLink. Pick the first usable hit."""
    if v.is_null():
        return Optional[DefinitionResolved]()
    if v.is_array():
        if v.array_len() == 0:
            return Optional[DefinitionResolved]()
        return _parse_one_definition(v.arr_v[0])
    if v.is_object():
        return _parse_one_definition(v)
    return Optional[DefinitionResolved]()


def _parse_one_definition(v: JsonValue) -> Optional[DefinitionResolved]:
    if not v.is_object():
        return Optional[DefinitionResolved]()
    # LocationLink: ``targetUri`` + ``targetSelectionRange`` (preferred) or
    # ``targetRange``. Plain Location: ``uri`` + ``range``.
    var ui = v.object_index(String("uri"))
    if ui < 0:
        ui = v.object_index(String("targetUri"))
    var ri = v.object_index(String("range"))
    if ri < 0:
        ri = v.object_index(String("targetSelectionRange"))
    if ri < 0:
        ri = v.object_index(String("targetRange"))
    if ui < 0 or ri < 0 or not v.obj_v[ui].value.is_string():
        return Optional[DefinitionResolved]()
    var path = _uri_to_path(v.obj_v[ui].value.str_v)
    if len(path.as_bytes()) == 0:
        return Optional[DefinitionResolved]()
    var start = _start_pos_of(v.obj_v[ri].value)
    if start[0] < 0:
        return Optional[DefinitionResolved]()
    return Optional[DefinitionResolved](DefinitionResolved(
        path, start[0], start[1],
    ))


def _parse_references_result(v: JsonValue) -> List[DefinitionResolved]:
    """``textDocument/references`` returns ``Location[] | null``. Each
    entry has the same shape ``_parse_one_definition`` accepts (uri +
    range, no LocationLink variant in the spec), so we reuse that
    parser per element and skip malformed entries silently."""
    var out = List[DefinitionResolved]()
    if not v.is_array():
        return out^
    for i in range(len(v.arr_v)):
        var one = _parse_one_definition(v.arr_v[i])
        if one:
            out.append(one.value())
    return out^


# --- symbol parsing --------------------------------------------------------


def _parse_symbols_result(v: JsonValue) -> List[SymbolItem]:
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


def _parse_document_symbol(
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
        var children = children_opt.value().copy()
        for i in range(children.array_len()):
            _parse_document_symbol(children.array_at(i), sub_container, out)


def _parse_symbol_information(v: JsonValue, mut out: List[SymbolItem]):
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


def _parse_workspace_symbols_result(
    v: JsonValue,
) -> List[WorkspaceSymbolItem]:
    """``workspace/symbol`` returns ``SymbolInformation[]`` (legacy
    form, every entry has ``location``) or ``WorkspaceSymbol[]``
    (newer 3.17 form, where the location may be a ``{uri}``-only
    stub the server resolves lazily via ``workspaceSymbol/resolve``).

    We treat them uniformly: every entry must surface a ``location``
    with at least a ``uri``. Stubs without a ``range`` land at the
    file's first line — fine for "jump to definition" since the
    user can navigate within the file once it opens. Anything else
    malformed is silently dropped (servers occasionally emit half-
    populated entries; surfacing them as zeroed rows would be worse)."""
    var out = List[WorkspaceSymbolItem]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        _parse_workspace_symbol(v.array_at(i), out)
    return out^


def _parse_workspace_symbol(
    v: JsonValue, mut out: List[WorkspaceSymbolItem],
):
    if not v.is_object():
        return
    var name_opt = v.object_get(String("name"))
    if not name_opt or not name_opt.value().is_string():
        return
    var name = name_opt.value().as_str()
    var kind = json_get_int(v, String("kind"), 0)
    var container = json_get_string(v, String("containerName"))
    var loc_opt = v.object_get(String("location"))
    if not loc_opt or not loc_opt.value().is_object():
        return
    var uri_opt = loc_opt.value().object_get(String("uri"))
    if not uri_opt or not uri_opt.value().is_string():
        return
    var path = _uri_to_path(uri_opt.value().as_str())
    var line = 0
    var character = 0
    var range_opt = loc_opt.value().object_get(String("range"))
    if range_opt:
        var pos = _start_pos_of(range_opt.value())
        if pos[0] >= 0:
            line = pos[0]
            character = pos[1]
    out.append(
        WorkspaceSymbolItem(name, kind, container, path, line, character),
    )


def _parse_additional_text_edits(entry: JsonValue) -> List[TextEditEntry]:
    """Pull the ``additionalTextEdits`` array off a CompletionItem (or a
    resolved CompletionItem) into normalized ``TextEditEntry`` rows.
    Malformed entries (missing range or newText) are skipped silently —
    losing one auxiliary edit is better than dropping the whole item.
    Returns an empty list when the field is absent or not an array."""
    var ai = entry.object_index(String("additionalTextEdits"))
    if ai < 0:
        return List[TextEditEntry]()
    return _parse_text_edits(entry.obj_v[ai].value)


def _parse_completion_result(v: JsonValue) -> List[CompletionItem]:
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
    # The array is borrowed, in place: copying it out of the response (and
    # each item out of it) cloned the whole list on every keystroke with
    # the popup open.
    if v.is_array():
        _parse_completion_items(v, out)
    elif v.is_object():
        for k in range(len(v.obj_v)):
            if v.obj_v[k].key == String("items"):
                if v.obj_v[k].value.is_array():
                    _parse_completion_items(v.obj_v[k].value, out)
                break
    # Stable insertion sort by sort_text — typical completion lists are
    # under ~200 items so quadratic worst-case is fine here. In place, by
    # swapping: a swap moves two items, where building a sorted copy
    # cloned every item (labels, aux edits and all).
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j].sort_text < out[j - 1].sort_text:
            out.swap_elements(j, j - 1)
            j -= 1
    return out^


def _parse_completion_items(arr: JsonValue, mut out: List[CompletionItem]):
    """Append each well-formed ``CompletionItem`` in ``arr`` to ``out``."""
    for i in range(len(arr.arr_v)):
        ref entry = arr.arr_v[i]
        if not entry.is_object():
            continue
        var li = entry.object_index(String("label"))
        if li < 0 or not entry.obj_v[li].value.is_string():
            continue
        var label = entry.obj_v[li].value.as_str()
        var kind = json_get_int(entry, String("kind"), 0)
        var detail = json_get_string(entry, String("detail"))
        var insert_text = label
        var has_range = False
        var rs_line = 0
        var rs_char = 0
        var re_line = 0
        var re_char = 0
        var fmt = json_get_int(entry, String("insertTextFormat"), 1)
        if fmt != 2:
            # Per LSP spec, when ``textEdit`` is provided the value of
            # ``insertText`` is ignored — textEdit is authoritative for
            # both the text to insert and the range to replace. Fall
            # back to ``insertText`` only when textEdit is absent, and
            # fall back to the label only when both are absent.
            var got_te = False
            var tei = entry.object_index(String("textEdit"))
            if tei >= 0 and entry.obj_v[tei].value.is_object():
                ref te = entry.obj_v[tei].value
                var nti = te.object_index(String("newText"))
                if nti >= 0 and te.obj_v[nti].value.is_string():
                    insert_text = te.obj_v[nti].value.as_str()
                    got_te = True
                # ``TextEdit`` carries ``range``; ``InsertReplaceEdit``
                # carries ``insert`` and ``replace`` — prefer ``replace``
                # so accepting overwrites existing text rather than
                # leaving a suffix behind the cursor.
                var rgi = te.object_index(String("range"))
                if rgi < 0:
                    rgi = te.object_index(String("replace"))
                if rgi >= 0:
                    var r = _parse_range(te.obj_v[rgi].value)
                    if r:
                        rs_line = r.value()[0]
                        rs_char = r.value()[1]
                        re_line = r.value()[2]
                        re_char = r.value()[3]
                        has_range = True
            if not got_te:
                insert_text = json_get_string(entry, String("insertText"), insert_text)
        var sort_text = label
        sort_text = json_get_string(entry, String("sortText"), sort_text)
        # ``additionalTextEdits``: array of TextEdits applied alongside
        # the primary edit (typically the auto-import line). Often empty
        # on the initial list and only filled in by ``completionItem/
        # resolve`` — see ``_parse_additional_text_edits``.
        var aux_edits = _parse_additional_text_edits(entry)
        # ``data``: opaque server-defined payload echoed back verbatim in
        # ``completionItem/resolve``. Keep its raw JSON so we can re-emit
        # it unchanged — the server keys the resolve lookup off it, and a
        # resolve without it returns nothing useful.
        var data_raw = String("")
        var di = entry.object_index(String("data"))
        if di >= 0:
            data_raw = encode_json(entry.obj_v[di].value)
        out.append(CompletionItem(
            label, insert_text, kind, detail, sort_text,
            has_range, rs_line, rs_char, re_line, re_char,
            aux_edits^, data_raw^,
        ))


def _parse_hover_result(v: JsonValue) -> String:
    """Extract a single human-readable string from a ``textDocument/hover``
    response. The response is ``{ contents: MarkupContent | MarkedString |
    MarkedString[] }`` where ``MarkupContent`` is ``{ kind, value }``,
    ``MarkedString`` is either a plain string or ``{ language, value }``,
    and the array form is a list of those. We accept all of them and
    return the joined ``value`` strings (newline-separated). Returns the
    empty string when the result has no usable text — the host treats
    that as 'nothing to show'."""
    var ci = v.object_index(String("contents"))
    if ci < 0:
        return String("")
    return _hover_contents_to_string(v.obj_v[ci].value)


def _hover_contents_to_string(v: JsonValue) -> String:
    """Recursive helper for ``_parse_hover_result``: walks the polymorphic
    ``contents`` shape and concatenates the text segments."""
    if v.is_string():
        return v.as_str()
    if v.is_object():
        # MarkupContent ({kind, value}) or MarkedString ({language, value}).
        return json_get_string(v, String("value"))
    if v.is_array():
        var parts = List[String]()
        for i in range(len(v.arr_v)):
            var piece = _hover_contents_to_string(v.arr_v[i])
            if len(piece.as_bytes()) > 0:
                parts.append(piece^)
        if len(parts) == 0:
            return String("")
        var out = parts[0]
        for i in range(1, len(parts)):
            out = out + String("\n") + parts[i]
        return out^
    return String("")


def _code_action_edit_of(v: JsonValue) -> JsonValue:
    """The ``edit`` object of a CodeAction, or JSON null. Split out so the
    resolve path reads it the same way the initial parse does."""
    if not v.is_object():
        return json_null()
    var e = v.object_get(String("edit"))
    if e and e.value().is_object():
        return e.value().copy()
    return json_null()


def _code_action_command_of(
    v: JsonValue,
) -> Tuple[String, Optional[JsonValue]]:
    """The ``(command, arguments)`` of a CodeAction. ``command`` is a string
    when the entry *is* a Command and an object when it's a CodeAction
    literal carrying one — both shapes are accepted."""
    var cmd = String("")
    var args = Optional[JsonValue]()
    if not v.is_object():
        return (cmd^, args^)
    var c_opt = v.object_get(String("command"))
    if c_opt and c_opt.value().is_string():
        cmd = c_opt.value().as_str()
        var a = v.object_get(String("arguments"))
        if a and a.value().is_array():
            args = Optional[JsonValue](a.value().copy())
    elif c_opt and c_opt.value().is_object():
        var inner = c_opt.value().copy()
        cmd = json_get_string(inner, String("command"), cmd)
        var a2 = inner.object_get(String("arguments"))
        if a2 and a2.value().is_array():
            args = Optional[JsonValue](a2.value().copy())
    return (cmd^, args^)


def _parse_code_action_result(v: JsonValue) -> List[CodeAction]:
    """Parse the result of ``textDocument/codeAction``.

    The result is ``(Command | CodeAction)[] | null``. ``Command``
    entries (no ``edit`` field — the action is opaquely server-side)
    are skipped: we have no way to apply them without a follow-up
    ``workspace/executeCommand`` round-trip we don't model yet.
    ``CodeAction`` literals are accepted; their ``edit`` is normalized
    into ``CodeActionFileEdit`` groups via ``_parse_workspace_edit``,
    which handles both the ``changes`` map and the 3.13+
    ``documentChanges`` array. An action whose WorkspaceEdit also carries
    ``CreateFile`` / ``RenameFile`` / ``DeleteFile`` comes through with an
    empty ``file_edits`` list on purpose — see ``WorkspaceEditParse``.

    An action with no ``edit`` at all but a ``data`` field needs a
    ``codeAction/resolve`` round-trip; ``data`` is preserved for that.
    """
    var out = List[CodeAction]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var entry = v.array_at(i)
        if not entry.is_object():
            continue
        # Skip raw ``Command`` entries: spec-wise they have a ``command``
        # field at top level and no ``edit``. A ``CodeAction`` literal
        # may also carry a ``command`` *plus* an edit; we accept those
        # by checking for ``edit`` or ``kind``/``title`` shape.
        var title_opt = entry.object_get(String("title"))
        if not title_opt or not title_opt.value().is_string():
            continue
        var title = title_opt.value().as_str()
        var kind_str = json_get_string(entry, String("kind"))
        var is_preferred = False
        is_preferred = json_get_bool(entry, String("isPreferred"), is_preferred)
        var file_edits = List[CodeActionFileEdit]()
        var edit_opt = entry.object_get(String("edit"))
        var has_inline_edit = False
        if edit_opt and edit_opt.value().is_object():
            has_inline_edit = True
            file_edits = _parse_workspace_edit_changes(edit_opt.value())
        # No inline edit → the action may be resolvable. Keep the entry so
        # ``_resolve_code_actions`` can hand it back verbatim.
        var unresolved = Optional[JsonValue]()
        if not has_inline_edit:
            unresolved = Optional[JsonValue](entry.copy())
        # Extract a Command, if any — shared with the resolve path, which
        # is another place a Command can first appear.
        var cmd_pair = _code_action_command_of(entry)
        var cmd = cmd_pair[0]
        var cmd_args = cmd_pair[1].copy()
        out.append(CodeAction(
            title, kind_str, is_preferred, file_edits^, cmd^, cmd_args^,
            unresolved^,
        ))
    return out^


@fieldwise_init
struct WorkspaceEditParse(Copyable, Movable):
    """The outcome of parsing an LSP ``WorkspaceEdit``.

    ``unsupported_ops`` counts ``CreateFile`` / ``RenameFile`` /
    ``DeleteFile`` entries in a ``documentChanges`` array. It exists because
    those change the shape of a *correct* failure: a WorkspaceEdit that
    renames a file and rewrites its references is one atomic refactor, so
    applying only the text edits leaves the project broken in a way that
    doing nothing does not. When ``unsupported_ops > 0`` the parse
    deliberately returns **no** file edits — refuse the whole thing, don't
    half-apply it.
    """
    var file_edits: List[CodeActionFileEdit]
    var unsupported_ops: Int


def _parse_workspace_edit(edit: JsonValue) -> WorkspaceEditParse:
    """Normalize an LSP ``WorkspaceEdit`` into per-file edit groups.

    Both spec forms are handled:

    * ``changes`` — a ``{uri: TextEdit[]}`` map.
    * ``documentChanges`` — an array of ``TextDocumentEdit``
      (``{textDocument: {uri, version}, edits}``), optionally interleaved
      with ``CreateFile`` / ``RenameFile`` / ``DeleteFile`` entries, which
      are identified by a ``kind`` string and counted as unsupported.

    ``documentChanges`` is the form rust-analyzer and gopls prefer, so
    parsing it is what makes their renames and quickfixes work at all.
    A server may only use it when the client advertised
    ``workspace.workspaceEdit.documentChanges`` — which we now do (see
    ``lsp_initialize_params``). We deliberately do *not* advertise
    ``resourceOperations``, so a compliant server will never send the file
    operations; the counting exists for the ones that do anyway.

    When both forms are present the spec says ``documentChanges`` wins.
    """
    var file_edits = List[CodeActionFileEdit]()
    if not edit.is_object():
        return WorkspaceEditParse(file_edits^, 0)

    var dc_opt = edit.object_get(String("documentChanges"))
    if dc_opt and dc_opt.value().is_array():
        var dc = dc_opt.value().copy()
        var unsupported = 0
        for i in range(dc.array_len()):
            var entry = dc.array_at(i)
            if not entry.is_object():
                continue
            # A ``kind`` string marks a resource operation (create / rename
            # / delete). A TextDocumentEdit has no ``kind``.
            var kind_opt = entry.object_get(String("kind"))
            if kind_opt and kind_opt.value().is_string():
                unsupported += 1
                continue
            var td_opt = entry.object_get(String("textDocument"))
            if not td_opt or not td_opt.value().is_object():
                continue
            var uri_opt = td_opt.value().object_get(String("uri"))
            if not uri_opt or not uri_opt.value().is_string():
                continue
            var edits_opt = entry.object_get(String("edits"))
            if not edits_opt:
                continue
            var edits = _parse_text_edits(edits_opt.value())
            if len(edits) > 0:
                file_edits.append(
                    CodeActionFileEdit(uri_opt.value().as_str(), edits^),
                )
        if unsupported > 0:
            # Refuse the whole edit — see ``WorkspaceEditParse``.
            return WorkspaceEditParse(List[CodeActionFileEdit](), unsupported)
        return WorkspaceEditParse(file_edits^, 0)

    var changes_opt = edit.object_get(String("changes"))
    if not changes_opt or not changes_opt.value().is_object():
        return WorkspaceEditParse(file_edits^, 0)
    var changes = changes_opt.value().copy()
    # ``changes`` is an object keyed by URI.
    for k in range(changes.object_len()):
        var uri = changes.object_key_at(k)
        var edits = _parse_text_edits(changes.object_value_at(k))
        if len(edits) > 0:
            file_edits.append(CodeActionFileEdit(uri, edits^))
    return WorkspaceEditParse(file_edits^, 0)


def _parse_workspace_edit_changes(edit: JsonValue) -> List[CodeActionFileEdit]:
    """``_parse_workspace_edit``'s file-edit groups, discarding the
    unsupported-operation count. Callers that need to tell "no edits" from
    "refused because it also moves files" use the full parse instead."""
    # ``.copy()``, not ``^``: moving a field out of the middle of a struct
    # leaves the rest undestroyable.
    var parsed = _parse_workspace_edit(edit)
    return parsed.file_edits.copy()


def _parse_diagnostics_array(v: JsonValue) -> List[Diagnostic]:
    """Parse the ``diagnostics`` array of a ``publishDiagnostics``
    notification into normalized buffer-relative entries. Skips
    malformed entries (missing range/severity is not fatal — the
    spec actually allows omitting severity, in which case we default
    to ``DIAG_SEVERITY_INFO`` so the diagnostic still surfaces)."""
    var out = List[Diagnostic]()
    if not v.is_array():
        return out^
    for i in range(len(v.arr_v)):
        ref entry = v.arr_v[i]
        if not entry.is_object():
            continue
        var ri = entry.object_index(String("range"))
        if ri < 0:
            continue
        var r = _parse_range(entry.obj_v[ri].value)
        if not r:
            continue
        var rt = r.value()
        var severity = json_get_int(entry, String("severity"), DIAG_SEVERITY_INFO)
        var message = json_get_string(entry, String("message"))
        var source = json_get_string(entry, String("source"))
        # ``code`` is required for code-action lookups (servers match
        # quickfix rules by code) — preserve whatever the server sent.
        # The spec allows either a string or an integer; we coerce to
        # string and echo back as-is.
        var code = String("")
        var ci = entry.object_index(String("code"))
        if ci >= 0:
            ref cv = entry.obj_v[ci].value
            if cv.is_string():
                code = cv.str_v
            elif cv.is_int():
                code = String(cv.int_v)
        out.append(Diagnostic(
            rt[0], rt[1], rt[2], rt[3], severity, message^, source^, code^,
        ))
    return out^


def _position_of(v: JsonValue) -> Optional[Tuple[Int, Int]]:
    """``(line, character)`` of an LSP ``Position`` object, or empty when
    it isn't one."""
    if not v.is_object():
        return None
    var ln = v.object_index(String("line"))
    var ch = v.object_index(String("character"))
    if ln < 0 or ch < 0 or not v.obj_v[ln].value.is_int() \
            or not v.obj_v[ch].value.is_int():
        return None
    return (v.obj_v[ln].value.int_v, v.obj_v[ch].value.int_v)


def _parse_range(v: JsonValue) -> Optional[Tuple[Int, Int, Int, Int]]:
    """``(start_line, start_char, end_line, end_char)`` of an LSP ``Range``,
    or empty unless both ends are well-formed Positions. The one place a
    Range is taken apart — every result parser that carries one goes
    through here."""
    if not v.is_object():
        return None
    var si = v.object_index(String("start"))
    var ei = v.object_index(String("end"))
    if si < 0 or ei < 0:
        return None
    var sp = _position_of(v.obj_v[si].value)
    var ep = _position_of(v.obj_v[ei].value)
    if not sp or not ep:
        return None
    return (sp.value()[0], sp.value()[1], ep.value()[0], ep.value()[1])


def _start_pos_of(rng: JsonValue) -> Tuple[Int, Int]:
    """Extract ``(line, character)`` from a Range's ``start``. Returns
    ``(-1, -1)`` when the shape doesn't match — caller filters those out."""
    var si = rng.object_index(String("start"))
    if si < 0:
        return (-1, -1)
    var p = _position_of(rng.obj_v[si].value)
    if not p:
        return (-1, -1)
    return p.value()


# --- URI <-> path ----------------------------------------------------------


def _first_nonempty_line(s: String) -> String:
    """Return the first line of ``s`` that has at least one non-whitespace
    byte. Lets the FAILED state row in the LSP info window show a punchy
    one-liner from a multi-line stderr blob (the full thing is rendered
    in a dedicated block below)."""
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            var seg = String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=b.unsafe_ptr().unsafe_offset(start), length=i - start)))
            var trimmed = strip_trailing_newlines(seg)
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
        return strip_trailing_newlines(String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=b.unsafe_ptr().unsafe_offset(start), length=len(b) - start))))
    return String("")


def _lsp_range(sl: Int, sc: Int, el: Int, ec: Int) -> JsonValue:
    """An LSP ``{"start", "end"}`` Range object (0-based)."""
    var rng = json_object()
    rng.put(String("start"), _lsp_position(sl, sc))
    rng.put(String("end"), _lsp_position(el, ec))
    return rng^


def _lsp_position(line: Int, character: Int) -> JsonValue:
    """An LSP ``{"line", "character"}`` Position object (0-based)."""
    var pos = json_object()
    pos.put(String("line"), json_int(line))
    pos.put(String("character"), json_int(character))
    return pos^


def _formatting_options(tab_size: Int, insert_spaces: Bool) -> JsonValue:
    """The ``FormattingOptions`` object required by the formatting
    requests. Only the two mandatory fields are sent."""
    var opts = json_object()
    opts.put(String("tabSize"), json_int(tab_size))
    opts.put(String("insertSpaces"), json_bool(insert_spaces))
    return opts^


def _parse_inlay_hints(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``InlayHint[] | null`` into (row, label) carriers. ``label``
    is either a string or an array of ``InlayHintLabelPart`` objects with
    a ``value`` field — both are flattened to one string."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(len(v.arr_v)):
        ref e = v.arr_v[i]
        var pi = e.object_index(String("position"))
        if pi < 0:
            continue
        var row = json_get_int(e.obj_v[pi].value, String("line"), -1)
        if row < 0:
            continue
        var label = String("")
        var lbi = e.object_index(String("label"))
        if lbi >= 0:
            ref lab = e.obj_v[lbi].value
            if lab.is_string():
                label = lab.as_str()
            elif lab.is_array():
                for k in range(len(lab.arr_v)):
                    label += json_get_string(lab.arr_v[k], String("value"))
        if len(label.as_bytes()) == 0:
            continue
        out.append(TextEditEntry(row, 0, row, 0, label))
    return out^


def _parse_code_lens(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``CodeLens[] | null`` into (row, title) carriers. Only lenses
    carrying a resolved ``command.title`` are kept — unresolved lenses
    (no command) need a ``codeLens/resolve`` round-trip we don't do here,
    so they're skipped rather than shown blank."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(len(v.arr_v)):
        ref e = v.arr_v[i]
        var ri = e.object_index(String("range"))
        if ri < 0:
            continue
        var row = _start_pos_of(e.obj_v[ri].value)[0]
        if row < 0:
            continue
        var ci = e.object_index(String("command"))
        if ci < 0:
            continue
        var title = json_get_string(e.obj_v[ci].value, String("title"))
        if len(title.as_bytes()) == 0:
            continue
        out.append(TextEditEntry(row, 0, row, 0, String("‹") + title + String("›")))
    return out^


def _parse_inline_value_exprs(v: JsonValue) -> List[TextEditEntry]:
    """Parse the non-text ``InlineValue`` variants into (row, expr)
    carriers the host evaluates via the debugger: ``InlineValueVariable
    Lookup`` contributes its ``variableName``, ``InlineValueEvaluable
    Expression`` its ``expression``. Entries that already carry ``text``
    (handled by ``_parse_inline_values``) are skipped."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var t_opt = e.object_get(String("text"))
        if t_opt and t_opt.value().is_string():
            continue  # InlineValueText — already rendered directly
        var vn_opt = e.object_get(String("variableName"))
        var expr = vn_opt.value().as_str() \
            if vn_opt and vn_opt.value().is_string() \
            else json_get_string(e, String("expression"))
        if len(expr.as_bytes()) == 0:
            continue
        var rng_opt = e.object_get(String("range"))
        if not rng_opt or not rng_opt.value().is_object():
            continue
        var sp = _start_pos_of(rng_opt.value())
        if sp[0] < 0:
            continue
        out.append(TextEditEntry(sp[0], 0, sp[0], 0, expr))
    return out^


def _parse_folding_ranges(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``FoldingRange[] | null`` into range carriers
    (``start_line``..``end_line``; characters unused — folding is
    line-based). Entries needing both a startLine and endLine; the
    optional ``kind`` is ignored."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(len(v.arr_v)):
        ref e = v.arr_v[i]
        var sl = json_get_int(e, String("startLine"), -1)
        var el = json_get_int(e, String("endLine"), -1)
        if sl < 0 or el <= sl:
            continue  # not a multi-line region
        out.append(TextEditEntry(sl, 0, el, 0, String("")))
    return out^


def _parse_inline_values(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``InlineValue[] | null`` into (row, text) carriers, keeping the
    ``InlineValueText`` variant (which carries ``text`` directly). The
    variable-lookup / evaluable-expression variants would need a DAP
    ``evaluate`` round-trip we don't do here, so they're skipped."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var t_opt = e.object_get(String("text"))
        if not t_opt or not t_opt.value().is_string():
            continue  # not an InlineValueText
        var txt = t_opt.value().as_str()
        if len(txt.as_bytes()) == 0:
            continue
        var rng_opt = e.object_get(String("range"))
        if not rng_opt or not rng_opt.value().is_object():
            continue
        var sp = _start_pos_of(rng_opt.value())
        if sp[0] < 0:
            continue
        out.append(TextEditEntry(sp[0], 0, sp[0], 0, txt))
    return out^


def _parse_linked_ranges(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``LinkedEditingRanges`` (``{ranges: Range[], wordPattern?}``)
    into range carriers (``new_text`` unused). A malformed Range is
    skipped, not carried with a ``-1`` end."""
    var out = List[TextEditEntry]()
    if not v.is_object():
        return out^
    var ri = v.object_index(String("ranges"))
    if ri < 0 or not v.obj_v[ri].value.is_array():
        return out^
    for ref rng in v.obj_v[ri].value.arr_v:
        var r = _parse_range(rng)
        if not r:
            continue
        var t = r.value()
        out.append(TextEditEntry(t[0], t[1], t[2], t[3], String("")))
    return out^


def _parse_inline_completion(v: JsonValue) -> String:
    """Pull the first suggestion's insert text out of an
    ``InlineCompletionList`` (``{items: [...]}``) or a bare
    ``InlineCompletionItem[]``. ``insertText`` is a string (or, in the
    snippet form we don't render, an object with ``value``)."""
    var items = v.copy()
    if v.is_object():
        var it_opt = v.object_get(String("items"))
        if it_opt and it_opt.value().is_array():
            items = it_opt.value().copy()
        else:
            return String("")
    if not items.is_array() or items.array_len() == 0:
        return String("")
    var first = items.array_at(0)
    if not first.is_object():
        return String("")
    var ins_opt = first.object_get(String("insertText"))
    if not ins_opt:
        return String("")
    var ins = ins_opt.value().copy()
    if ins.is_string():
        return ins.as_str()
    if ins.is_object():
        var val = ins.object_get(String("value"))
        if val and val.value().is_string():
            return val.value().as_str()
    return String("")


def _parse_monikers(v: JsonValue) -> String:
    """Join a ``Moniker[] | null`` result into a ``scheme:identifier``
    status string (comma-separated), or empty when none."""
    if not v.is_array():
        return String("")
    var out = String("")
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var id_opt = e.object_get(String("identifier"))
        if not id_opt or not id_opt.value().is_string():
            continue
        var ident = id_opt.value().as_str()
        var scheme = json_get_string(e, String("scheme"))
        var entry = (scheme + String(":") + ident) if len(
            scheme.as_bytes()
        ) > 0 else ident
        if len(out.as_bytes()) > 0:
            out = out + String(", ")
        out = out + entry
    return out^


def _document_link_target_of(v: JsonValue) -> String:
    """The ``target`` uri of a DocumentLink, or "" when the server deferred
    it to ``documentLink/resolve``."""
    if not v.is_object():
        return String("")
    var t = v.object_get(String("target"))
    if t and t.value().is_string():
        return t.value().as_str()
    return String("")


struct DocumentLinkParse(Copyable, Movable):
    """One walk of a ``DocumentLink[]``, carrying what both the display path
    and the resolve path need.

    ``links`` holds **every** well-formed link, targetless ones included with
    an empty ``new_text``, so an index into it is a stable slot a
    ``documentLink/resolve`` response can fill. ``unresolved_slots`` are the
    indices of those targetless entries and ``unresolved_raw`` the original
    JSON for each, index-parallel with it.

    One function rather than two because the alternative — a parse and a
    separate "which ones need resolving" scan — has to apply the *same*
    well-formedness filter in two places to keep its indices aligned, and a
    later edit to one of them silently pairs resolved targets with the wrong
    links. Computing the slot during the single walk removes the
    possibility.
    """
    var links: List[TextEditEntry]
    var unresolved_slots: List[Int]
    var unresolved_raw: List[JsonValue]

    def __init__(out self):
        self.links = List[TextEditEntry]()
        self.unresolved_slots = List[Int]()
        self.unresolved_raw = List[JsonValue]()


def _parse_document_links_full(v: JsonValue) -> DocumentLinkParse:
    """Parse ``DocumentLink[] | null`` in one pass. See
    ``DocumentLinkParse``."""
    var out = DocumentLinkParse()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var rng_opt = e.object_get(String("range"))
        if not rng_opt:
            continue
        var r = _parse_range(rng_opt.value())
        if not r:
            continue
        var t = r.value()
        var target = _document_link_target_of(e)
        if len(target.as_bytes()) == 0:
            out.unresolved_slots.append(len(out.links))
            out.unresolved_raw.append(e.copy())
        out.links.append(TextEditEntry(t[0], t[1], t[2], t[3], target))
    return out^


def _parse_document_links(v: JsonValue) -> List[TextEditEntry]:
    """Range carriers whose ``new_text`` is the link ``target``, for links
    that have one.

    Targetless links are dropped here — the server deferred them to
    ``documentLink/resolve``, and an underlined range that does nothing on
    click is worse than no underline. The resolve path uses
    ``_parse_document_links_full`` instead, which keeps them as fillable
    slots, and re-publishes through this same filter once the targets land.
    """
    var parsed = _parse_document_links_full(v)
    var out = List[TextEditEntry]()
    for i in range(len(parsed.links)):
        if len(parsed.links[i].new_text.as_bytes()) > 0:
            out.append(parsed.links[i])
    return out^


def _codelens_row_of(lens: JsonValue) -> Int:
    """The ``range.start.line`` of a CodeLens object (0 on any mismatch)."""
    if not lens.is_object():
        return 0
    var rng = lens.object_get(String("range"))
    if not rng:
        return 0
    return max(0, _start_pos_of(rng.value())[0])


def _codelens_title_of(lens: JsonValue) -> String:
    """The ``command.title`` of a (resolved) CodeLens, or empty."""
    if not lens.is_object():
        return String("")
    var cmd = lens.object_get(String("command"))
    if not cmd or not cmd.value().is_object():
        return String("")
    var t = cmd.value().object_get(String("title"))
    if t and t.value().is_string():
        return t.value().as_str()
    return String("")


def _collect_unresolved_lenses(v: JsonValue) -> List[JsonValue]:
    """Return the raw CodeLens objects that have a ``range`` but no
    title-bearing ``command`` — they need a ``codeLens/resolve`` to fill
    in the title, and are otherwise dropped by ``_parse_code_lens``."""
    var out = List[JsonValue]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object() or not e.object_has(String("range")):
            continue
        if len(_codelens_title_of(e).as_bytes()) == 0:
            out.append(e.copy())
    return out^


def _unit_text(n: Int) -> String:
    """Format a 0..255 channel value as a 0..1 decimal string for an LSP
    color component (e.g. 128 → ``"0.501..."``, 255 → ``"1.0"``)."""
    if n <= 0:
        return String("0.0")
    if n >= 255:
        return String("1.0")
    return String(Float64(n) / 255.0)


def _color_unit_to_255(v: JsonValue) -> Int:
    """Convert an LSP color component (0..1, a JSON float stored as raw
    text, or an int 0/1) to a 0..255 channel value."""
    if v.is_int():
        var n = v.as_int() * 255
        if n < 0:
            return 0
        if n > 255:
            return 255
        return n
    if not v.is_float():
        return 0
    var b = v.as_str().as_bytes()
    var i = 0
    if len(b) > 0 and (b[0] == 0x2D):  # leading '-': clamp to 0
        return 0
    if len(b) > 0 and b[0] == 0x2B:
        i = 1
    var intpart = 0
    while i < len(b) and Int(b[i]) >= 0x30 and Int(b[i]) <= 0x39:
        intpart = intpart * 10 + (Int(b[i]) - 0x30)
        i += 1
    var frac = Float64(0.0)
    var scale = Float64(0.1)
    if i < len(b) and b[i] == 0x2E:  # '.'
        i += 1
        while i < len(b) and Int(b[i]) >= 0x30 and Int(b[i]) <= 0x39:
            frac += Float64(Int(b[i]) - 0x30) * scale
            scale *= 0.1
            i += 1
    var val = Float64(intpart) + frac
    var out = Int(val * 255.0 + 0.5)
    if out < 0:
        return 0
    if out > 255:
        return 255
    return out


def _parse_document_colors(v: JsonValue) -> List[Highlight]:
    """Parse ``ColorInformation[] | null`` into swatch ``Highlight``s: the
    color literal's range recolored with the literal's actual color as a
    truecolor background (fg auto-picked for contrast)."""
    var out = List[Highlight]()
    if not v.is_array():
        return out^
    for i in range(len(v.arr_v)):
        ref e = v.arr_v[i]
        var ci = e.object_index(String("color"))
        var rni = e.object_index(String("range"))
        if ci < 0 or not e.obj_v[ci].value.is_object() or rni < 0:
            continue
        ref col = e.obj_v[ci].value
        var ri = col.object_index(String("red"))
        var gi = col.object_index(String("green"))
        var bi = col.object_index(String("blue"))
        if ri < 0 or gi < 0 or bi < 0:
            continue
        var r = _color_unit_to_255(col.obj_v[ri].value)
        var g = _color_unit_to_255(col.obj_v[gi].value)
        var b = _color_unit_to_255(col.obj_v[bi].value)
        var rgb = UInt32((r << 16) | (g << 8) | b)
        # Contrast foreground: dark text on light swatches, light on dark.
        var lum = (r * 299 + g * 587 + b * 114) // 1000
        var fg = BLACK if lum > 140 else WHITE
        var span = _parse_range(e.obj_v[rni].value)
        if not span:
            continue
        # Single-row swatch (color literals don't span lines).
        out.append(Highlight(
            span.value()[0], span.value()[1], span.value()[3],
            Attr(fg, EDITOR_BG).with_bg_rgb(rgb),
        ))
    return out^


def _hierarchy_item_location(item: JsonValue) -> Optional[DefinitionResolved]:
    """A CallHierarchyItem / TypeHierarchyItem → a jump location, using its
    ``uri`` + ``selectionRange`` (falling back to ``range``).start."""
    if not item.is_object():
        return Optional[DefinitionResolved]()
    var uri_opt = item.object_get(String("uri"))
    if not uri_opt or not uri_opt.value().is_string():
        return Optional[DefinitionResolved]()
    var path = _uri_to_path(uri_opt.value().as_str())
    if len(path.as_bytes()) == 0:
        return Optional[DefinitionResolved]()
    var rng_opt = item.object_get(String("selectionRange"))
    if not rng_opt or not rng_opt.value().is_object():
        rng_opt = item.object_get(String("range"))
    if not rng_opt or not rng_opt.value().is_object():
        return Optional[DefinitionResolved]()
    var start = _start_pos_of(rng_opt.value())
    if start[0] < 0:
        return Optional[DefinitionResolved]()
    return Optional[DefinitionResolved](DefinitionResolved(
        path, start[0], start[1],
    ))


def _parse_hierarchy_result(v: JsonValue) -> List[DefinitionResolved]:
    """Parse a hierarchy follow-up result into jump locations. Handles
    ``CallHierarchyIncomingCall[]`` (each wraps a ``from`` item),
    ``CallHierarchyOutgoingCall[]`` (each wraps a ``to`` item), and a bare
    item array (``typeHierarchy/supertypes`` / ``subtypes``)."""
    var out = List[DefinitionResolved]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var item = e.copy()
        var from_opt = e.object_get(String("from"))
        if from_opt and from_opt.value().is_object():
            item = from_opt.value().copy()
        else:
            var to_opt = e.object_get(String("to"))
            if to_opt and to_opt.value().is_object():
                item = to_opt.value().copy()
        var loc = _hierarchy_item_location(item)
        if loc:
            out.append(loc.value())
    return out^


def _parse_selection_ranges(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``SelectionRange[] | null`` for a single requested position.
    Walks the ``parent`` chain of the first entry, collecting ranges
    innermost→outermost (range carriers). Bounded to 128 levels."""
    var out = List[TextEditEntry]()
    if not v.is_array() or v.array_len() == 0:
        return out^
    _collect_selection_ranges(v.arr_v[0], 0, out)
    return out^


def _collect_selection_ranges(
    cur: JsonValue, depth: Int, mut out: List[TextEditEntry],
):
    """One link of a ``SelectionRange`` parent chain, then its parent —
    each read in place."""
    if not cur.is_object() or depth >= 128:
        return
    var ri = cur.object_index(String("range"))
    if ri >= 0:
        var r = _parse_range(cur.obj_v[ri].value)
        if r:
            var t = r.value()
            out.append(TextEditEntry(t[0], t[1], t[2], t[3], String("")))
    var pi = cur.object_index(String("parent"))
    if pi >= 0:
        _collect_selection_ranges(cur.obj_v[pi].value, depth + 1, out)


def _parse_signature_help(v: JsonValue) -> String:
    """Render the active signature of a ``SignatureHelp`` result to a
    one-line status string. Returns the signature ``label`` and, when an
    active parameter with a string ``label`` is resolvable, appends
    ``  ▸ <param>``. Empty string for ``null`` / no signatures."""
    var si = v.object_index(String("signatures"))
    if si < 0 or not v.obj_v[si].value.is_array():
        return String("")
    ref sigs = v.obj_v[si].value.arr_v
    if len(sigs) == 0:
        return String("")
    var active = json_get_int(v, String("activeSignature"), 0)
    if active < 0 or active >= len(sigs):
        active = 0
    ref sig = sigs[active]
    var li = sig.object_index(String("label"))
    if li < 0 or not sig.obj_v[li].value.is_string():
        return String("")
    var label = sig.obj_v[li].value.as_str()
    # Resolve the active parameter's string label if present.
    var ap = json_get_int(v, String("activeParameter"), -1)
    ap = json_get_int(sig, String("activeParameter"), ap)
    var pi = sig.object_index(String("parameters"))
    if ap >= 0 and pi >= 0 and ap < sig.obj_v[pi].value.array_len():
        ref p = sig.obj_v[pi].value.arr_v[ap]
        var pl = p.object_index(String("label"))
        if pl >= 0 and p.obj_v[pl].value.is_string():
            return label + String("   ▸ ") + p.obj_v[pl].value.as_str()
    return label


def _parse_document_highlights(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``DocumentHighlight[] | null`` into range carriers
    (``TextEditEntry`` with empty ``new_text``). Each entry has a
    ``range``; the optional ``kind`` (text/read/write) is ignored — we
    paint all occurrences the same."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(len(v.arr_v)):
        ref e = v.arr_v[i]
        var ri = e.object_index(String("range"))
        if ri < 0:
            continue
        var r = _parse_range(e.obj_v[ri].value)
        if not r:
            continue
        var t = r.value()
        out.append(TextEditEntry(t[0], t[1], t[2], t[3], String("")))
    return out^


def _parse_text_edits(v: JsonValue) -> List[TextEditEntry]:
    """Parse a ``(TextEdit | AnnotatedTextEdit | SnippetTextEdit)[] | null``
    into ``TextEditEntry`` rows, skipping malformed entries. The formatting
    response shape, and shared by the ``changes`` map and
    ``documentChanges`` forms of a WorkspaceEdit.

    ``AnnotatedTextEdit`` adds only an ``annotationId``, so it parses as a
    plain TextEdit. A ``SnippetTextEdit`` carries ``snippet`` instead of
    ``newText`` and is skipped — inserting its raw ``$1`` placeholders as
    literal text would be worse than not applying it."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for j in range(len(v.arr_v)):
        ref te = v.arr_v[j]
        var ni = te.object_index(String("newText"))
        var ri = te.object_index(String("range"))
        if ni < 0 or not te.obj_v[ni].value.is_string() or ri < 0:
            continue
        var r = _parse_range(te.obj_v[ri].value)
        if not r:
            continue
        var t = r.value()
        out.append(TextEditEntry(
            t[0], t[1], t[2], t[3], te.obj_v[ni].value.as_str(),
        ))
    return out^


def _path_to_uri(path: String) -> String:
    """``/abs/path`` → ``file:///abs/path``. Resolves through realpath when
    possible so the server sees the same canonical form across calls.
    Percent-encodes bytes outside the RFC 3986 unreserved set (keeping
    ``/``) so paths with spaces / non-ASCII round-trip through
    ``_uri_to_path`` and match what spec-compliant servers expect."""
    return String("file://") + percent_encode_uri_path(realpath_or_self(path))


def uri_to_path(uri: String) -> String:
    """Public wrapper over ``_uri_to_path`` for hosts (e.g. the rename
    edit-application path) that need to map a WorkspaceEdit's file URIs
    back to on-disk paths."""
    return _uri_to_path(uri)


def _uri_to_path(uri: String) -> String:
    return file_uri_to_path(uri)


def _watched_changes_params(
    paths: List[String], types: List[Int],
) -> JsonValue:
    """Build the ``workspace/didChangeWatchedFiles`` params for parallel
    ``paths`` / ``types`` (LSP ``FileChangeType``: 1 created, 2 changed,
    3 deleted): one ``changes`` array, so N files cost one notification.
    A missing type defaults to "changed"."""
    var params = json_object()
    var changes = json_array()
    for i in range(len(paths)):
        var change = json_object()
        change.put(String("uri"), json_str(_path_to_uri(paths[i])))
        change.put(
            String("type"), json_int(types[i] if i < len(types) else 2),
        )
        changes.append(change)
    params.put(String("changes"), changes)
    return params^
