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
    JsonValue, encode_json, json_array, json_bool, json_float, json_int,
    json_object, json_str, parse_json,
)
from .file_io import basename, join_path, parent_path, stat_file
from .lsp import (
    LSP_NOTIFICATION, LSP_REQUEST, LSP_RESPONSE, LspClient, LspIncoming,
    LspProcess, json_null_v, lsp_initialize_params,
)
from .posix import getcwd_path, getenv_value, monotonic_ms, realpath, which
from .highlight import Highlight
from .colors import (
    Attr, BLACK, EDITOR_BG, EDITOR_FG, SYN_COMMENT, SYN_DECORATOR, SYN_IDENT,
    SYN_KEYWORD, SYN_NUMBER, SYN_OPERATOR, SYN_STRING, WHITE,
)


def _lsp_debug_log(line: String):
    """Append ``line`` (plus a trailing newline) to ``/tmp/turbokod-lsp.log``
    when that file already exists, or when ``TURBOKOD_LSP_LOG`` is set.
    No-op otherwise — ``touch /tmp/turbokod-lsp.log`` to enable, delete
    the file to disable.

    Opens with ``O_APPEND`` and writes one line per call so cost stays
    O(line) regardless of how large the log has grown. The previous
    read-modify-write was O(N) per call, i.e. O(N²) over a session —
    enabling debug logging on a busy LSP session would itself add
    multi-second latency to completion responses.
    """
    var path = String("/tmp/turbokod-lsp.log")
    var info = stat_file(path)
    if not info.ok \
            and len(getenv_value(String("TURBOKOD_LSP_LOG")).as_bytes()) == 0:
        return
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
        Int(fd), bytes.unsafe_ptr(), UInt(len(bytes)),
    )
    _ = external_call["close", Int32](fd)


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

    def __copyinit__(mut self, copy: Self):
        self.label = copy.label
        self.insert_text = copy.insert_text
        self.kind = copy.kind
        self.detail = copy.detail
        self.sort_text = copy.sort_text
        self.has_range = copy.has_range
        self.range_start_line = copy.range_start_line
        self.range_start_char = copy.range_start_char
        self.range_end_line = copy.range_end_line
        self.range_end_char = copy.range_end_char
        self.additional_text_edits = copy.additional_text_edits.copy()
        self.data = copy.data
        self.resolved = copy.resolved


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

    def __copyinit__(mut self, copy: Self):
        self.path = copy.path
        self.diags = copy.diags.copy()
        self.consumed = copy.consumed


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

    def __copyinit__(mut self, copy: Self):
        self.uri = copy.uri
        self.edits = copy.edits.copy()


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
    a more advanced ``documentChanges`` form we don't parse yet, and
    the host should skip / ignore the entry.
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

    def __init__(
        out self, var title: String, var kind: String, is_preferred: Bool,
        var file_edits: List[CodeActionFileEdit],
        var command: String = String(""),
        var command_args: Optional[JsonValue] = Optional[JsonValue](),
    ):
        self.title = title^
        self.kind = kind^
        self.is_preferred = is_preferred
        self.file_edits = file_edits^
        self.command = command^
        self.command_args = command_args^

    def __copyinit__(mut self, copy: Self):
        self.title = copy.title
        self.kind = copy.kind
        self.is_preferred = copy.is_preferred
        self.file_edits = copy.file_edits.copy()
        self.command = copy.command
        self.command_args = copy.command_args


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
    # spec-mandated default ``utf-16``; recorded here so it's observable.
    var _position_encoding: String

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
    # Generic "navigate to a location" request (typeDefinition /
    # implementation / declaration). Parked target + origin word, kept
    # separate from the definition slot so it never triggers the
    # cmd-click → references chaining the definition path does.
    var _inflight_nav_id: String
    var _nav_word: String
    var _resolved_nav: Optional[DefinitionResolved]
    var _has_resolved_nav: Bool
    # ``textDocument/prepareRename`` round-trip that gates the rename
    # flow. ``_prepare_rename_state``: 0 = unsupported / errored (host
    # falls back to a direct prompt), 1 = renameable (seed prompt with
    # ``_prepare_rename_placeholder``), 2 = not renameable (null result).
    var _inflight_prepare_rename_id: String
    var _has_resolved_prepare_rename: Bool
    var _prepare_rename_state: Int
    var _prepare_rename_placeholder: String
    # ``textDocument/references`` — list-of-locations form of definition.
    # Parked as ``DefinitionResolved`` rows (same shape, different list).
    # ``_has_resolved_references`` distinguishes "no response yet" from
    # "empty list".
    var _inflight_ref_id: String
    var _ref_word: String
    var _resolved_references: List[DefinitionResolved]
    var _has_resolved_references: Bool
    var _inflight_symbol_id: String
    var _resolved_symbols: List[SymbolItem]  # parked between tick() and consume_symbols()
    var _has_resolved_symbols: Bool          # distinguishes "no result yet" from "empty list"
    var _symbols_empty: Bool                 # latched when the last response was empty
    # ``workspace/symbol`` — parallel to the document-symbol fields but
    # scoped to a workspace-wide query rather than a single document.
    # Used by the Find Symbol picker to disambiguate same-named symbols.
    var _inflight_ws_symbol_id: String
    var _resolved_ws_symbols: List[WorkspaceSymbolItem]
    var _has_resolved_ws_symbols: Bool
    # Pending ``textDocument/completion`` request state. ``_completion_path``
    # / ``_completion_row`` / ``_completion_col`` are echoed back via
    # ``pending_completion_*`` accessors so the host can drop a stale
    # response when the cursor has moved (or the user has switched
    # buffers) by the time it lands. ``_completion_manual`` records
    # whether the request was a user-invoked Ctrl+Space (vs. the as-you-
    # type auto-trigger) so the host can decide whether an empty
    # response should surface a ``<no completion found>`` message.
    var _inflight_completion_id: String
    var _completion_path: String
    var _completion_row: Int
    var _completion_col: Int
    var _completion_manual: Bool
    var _resolved_completions: List[CompletionItem]
    var _has_resolved_completions: Bool
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
    # completion fields: ``_hover_path``/``_hover_row``/``_hover_col``
    # are echoed via ``pending_hover_*`` so the host can drop a stale
    # response when the cursor has moved off the symbol. ``_resolved_hover``
    # is the rendered hover text (already joined into a single string) and
    # ``_has_resolved_hover`` is the parked-and-waiting-for-consumption flag.
    var _inflight_hover_id: String
    var _hover_path: String
    var _hover_row: Int
    var _hover_col: Int
    var _resolved_hover: String
    var _has_resolved_hover: Bool
    # Pending ``textDocument/codeAction`` request state. Pattern matches
    # the other request kinds: ``_inflight_code_action_id`` is "" when no
    # request is outstanding; ``_resolved_code_actions`` parks the parsed
    # action list until ``take_code_actions`` consumes it. ``_code_action_path``
    # is echoed via ``pending_code_action_path`` so the host can tell when
    # the response is for a stale diagnostic menu (the user moved on).
    var _inflight_code_action_id: String
    var _code_action_path: String
    var _resolved_code_actions: List[CodeAction]
    var _has_resolved_code_actions: Bool
    # Pending ``textDocument/rename`` request state. Same shape as the
    # code-action slots: an inflight id, an echoed origin path so a stale
    # response can be dropped, and a parked ``WorkspaceEdit`` (reusing the
    # ``CodeActionFileEdit`` grouping since rename returns the same shape).
    var _inflight_rename_id: String
    var _rename_path: String
    var _resolved_rename_edits: List[CodeActionFileEdit]
    var _has_resolved_rename: Bool
    # ``textDocument/formatting`` + ``rangeFormatting`` — both return a flat
    # ``TextEdit[]`` for one file, parked here for the host to apply via
    # the same edit-application path rename/code-actions use.
    var _inflight_formatting_id: String
    var _formatting_path: String
    var _resolved_formatting_edits: List[TextEditEntry]
    var _has_resolved_formatting: Bool
    # ``textDocument/onTypeFormatting`` — format-as-you-type. Fired when a
    # server-declared trigger char (``}``/``;``/newline/…) is typed; the
    # returned ``TextEdit[]`` (typically a reindent) is parked here and
    # applied without saving (distinct from the on-save formatting slot).
    var _inflight_ontype_id: String
    var _ontype_path: String
    var _resolved_ontype_edits: List[TextEditEntry]
    var _has_resolved_ontype: Bool
    # ``textDocument/moniker`` — cross-repo symbol identity (scheme +
    # identifier). Rendered as a one-line status string; parked here.
    var _inflight_moniker_id: String
    var _moniker_note: String
    var _has_moniker: Bool
    # ``textDocument/colorPresentation`` — given a color + its range, the
    # server returns alternate textual forms (hex / rgb() / named). Parked
    # as parallel ``_colorpres_labels`` / ``_colorpres_edits`` (label[i] ↔
    # the TextEdit that rewrites the literal to that form). ``_colorpres_*``
    # range fields remember the requested span so a label-only presentation
    # (no textEdit) can synthesize one.
    var _inflight_colorpres_id: String
    var _colorpres_labels: List[String]
    var _colorpres_edits: List[TextEditEntry]
    var _has_colorpres: Bool
    var _colorpres_sl: Int
    var _colorpres_sc: Int
    var _colorpres_el: Int
    var _colorpres_ec: Int
    # ``textDocument/inlineCompletion`` — ghost-text suggestion. Parked text
    # + the request position (so the editor anchors the ghost there).
    var _inflight_inlinecomp_id: String
    var _inlinecomp_text: String
    var _inlinecomp_row: Int
    var _inlinecomp_col: Int
    var _has_inlinecomp: Bool
    # ``textDocument/linkedEditingRange`` — the set of ranges that should be
    # edited together (e.g. an HTML open/close tag pair). Parked as range
    # carriers; the host places synchronized carets at them for co-editing.
    var _inflight_linked_id: String
    var _linked_ranges: List[TextEditEntry]
    var _has_linked: Bool
    # ``textDocument/inlineValue`` — values to show inline at the stopped
    # debug frame. We render the ``InlineValueText`` variant (server gives
    # the text directly) as end-of-line annotations, parked here as (row,
    # text) carriers. (The variable-lookup / evaluable-expression variants
    # would need a DAP ``evaluate`` round-trip — not wired yet.)
    var _inflight_inlineval_id: String
    var _inlinevals: List[TextEditEntry]
    var _has_inlinevals: Bool
    # The variable-lookup / evaluable-expression inline values: (row, expr)
    # carriers the host evaluates via DAP, then renders as ``expr = value``.
    var _inlineval_exprs: List[TextEditEntry]
    # ``textDocument/foldingRange`` — collapsible regions. Parked as range
    # carriers (start_line..end_line). The editor marks region starts; full
    # collapse (which needs fold-aware cursor/scroll/layout) is deferred.
    var _inflight_folding_id: String
    var _folding_path: String
    var _folding_ranges: List[TextEditEntry]
    var _has_folding: Bool
    # ``textDocument/documentHighlight`` — occurrences of the symbol at the
    # cursor, parked as range carriers (``TextEditEntry`` with empty
    # ``new_text``) for the host to push into the editor overlay.
    var _inflight_doc_highlight_id: String
    var _doc_highlight_path: String
    var _resolved_doc_highlights: List[TextEditEntry]
    var _has_resolved_doc_highlight: Bool
    # ``textDocument/signatureHelp`` — the active signature's rendered label
    # (with the active parameter marked), parked for the status bar.
    var _inflight_signature_id: String
    var _resolved_signature: String
    var _has_resolved_signature: Bool
    # ``textDocument/inlayHint`` + ``codeLens`` — rendered as end-of-line
    # annotations. Parked as (row, text) carriers (``TextEditEntry`` with
    # ``start_line`` = row, ``new_text`` = the label).
    var _inflight_inlay_id: String
    var _inlay_path: String
    var _resolved_inlay: List[TextEditEntry]
    var _has_resolved_inlay: Bool
    var _inflight_codelens_id: String
    var _codelens_path: String
    var _resolved_codelens: List[TextEditEntry]
    var _has_resolved_codelens: Bool
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
    var _inflight_doclink_id: String
    var _doclink_path: String
    var _resolved_doclinks: List[TextEditEntry]
    var _has_resolved_doclinks: Bool
    # ``textDocument/semanticTokens/full`` — the server's token-type legend
    # (from ``semanticTokensProvider.legend.tokenTypes``) plus the decoded
    # per-row recolor ``Highlight``s parked for the editor overlay.
    var _sem_token_types: List[String]
    var _inflight_semantic_id: String
    var _semantic_path: String
    var _resolved_semantic: List[Highlight]
    var _has_resolved_semantic: Bool
    # ``semanticTokens/full/delta`` state: the last ``resultId`` and the raw
    # flat token-int array it corresponds to, keyed by path. A subsequent
    # request for the same path sends ``/full/delta`` with the previous
    # resultId; the delta's ``edits`` splice into ``_sem_data`` and we
    # re-decode — far cheaper than re-tokenizing the whole file on a large
    # buffer. Cleared / bypassed when the path changes or no resultId yet.
    var _sem_result_id: String
    var _sem_data: List[Int]
    var _sem_data_path: String
    # Server-initiated status: ``$/progress`` (work-done progress) and
    # ``window/showMessage``. Parked for the host to surface in the status
    # bar — progress only when ``lsp_server_progress`` is on.
    var _progress_note: String
    var _has_progress_note: Bool
    var _server_message: String
    var _has_server_message: Bool
    # ``textDocument/selectionRange`` — the cursor's range hierarchy
    # (innermost→outermost), parked for the editor's smart-select grow.
    var _inflight_selrange_id: String
    var _selrange_path: String
    var _resolved_selrange: List[TextEditEntry]
    var _has_resolved_selrange: Bool
    # Call / type hierarchy: a two-step flow (prepare → incomingCalls /
    # supertypes) auto-chained in ``tick``. ``_hierarchy_followup`` is the
    # method to fire on the prepared item; the final locations are parked
    # in ``_resolved_hierarchy`` and surfaced through the references picker.
    var _inflight_hier_prepare_id: String
    var _inflight_hier_followup_id: String
    var _hierarchy_followup: String
    var _hierarchy_word: String
    var _resolved_hierarchy: List[DefinitionResolved]
    var _has_resolved_hierarchy: Bool
    # ``textDocument/documentColor`` — per-color swatch ``Highlight``s
    # (truecolor bg) parked for the editor overlay.
    var _inflight_color_id: String
    var _color_path: String
    var _resolved_colors: List[Highlight]
    var _has_resolved_colors: Bool
    # ``textDocument/diagnostic`` — the pull-diagnostics model (LSP 3.17).
    # Servers that advertise ``diagnosticProvider`` don't push
    # ``publishDiagnostics``; we request a report per document instead.
    # Single in-flight slot (``_pull_diag_path`` echoes which path it's
    # for); the parsed items land in the same ``_diagnostic_buckets`` the
    # push path uses. ``_pulled_paths`` records every path we've requested
    # so the host can fire the *initial* pull exactly once per buffer
    # (subsequent pulls are edit-driven).
    var _inflight_pull_diag_id: String
    var _pull_diag_path: String
    var _pulled_paths: List[String]
    # ``textDocument/willSaveWaitUntil`` — the server returns a
    # ``TextEdit[]`` to apply before the buffer is written (e.g. organize
    # imports / final-newline). Parked like the formatting edits; the host
    # applies them then writes (see ``_drain_willsave``).
    var _inflight_willsave_id: String
    var _willsave_path: String
    var _resolved_willsave_edits: List[TextEditEntry]
    var _has_resolved_willsave: Bool
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
    var _stderr_log: String
    # Rolling capture of the server's protocol-level log: ``window/
    # logMessage`` lines (prefixed by severity) and ``telemetry/event``
    # payloads, both of which the spec otherwise drops on the floor.
    # Surfaced in the LSP info window alongside stderr so a server that
    # explains a problem via logMessage (rather than crashing) is visible.
    # Capped at 16 KB like the stderr capture.
    var _log_capture: String

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
        self._inflight_nav_id = String("")
        self._nav_word = String("")
        self._resolved_nav = Optional[DefinitionResolved]()
        self._has_resolved_nav = False
        self._inflight_prepare_rename_id = String("")
        self._has_resolved_prepare_rename = False
        self._prepare_rename_state = 0
        self._prepare_rename_placeholder = String("")
        self._inflight_ref_id = String("")
        self._ref_word = String("")
        self._resolved_references = List[DefinitionResolved]()
        self._has_resolved_references = False
        self._inflight_symbol_id = String("")
        self._resolved_symbols = List[SymbolItem]()
        self._has_resolved_symbols = False
        self._symbols_empty = False
        self._inflight_ws_symbol_id = String("")
        self._resolved_ws_symbols = List[WorkspaceSymbolItem]()
        self._has_resolved_ws_symbols = False
        self._inflight_completion_id = String("")
        self._completion_path = String("")
        self._completion_row = 0
        self._completion_col = 0
        self._completion_manual = False
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
        self._inflight_resolve_id = String("")
        self._resolve_aux = List[TextEditEntry]()
        self._resolve_detail = String("")
        self._has_resolve_result = False
        self._inflight_hover_id = String("")
        self._hover_path = String("")
        self._hover_row = 0
        self._hover_col = 0
        self._resolved_hover = String("")
        self._has_resolved_hover = False
        self._inflight_code_action_id = String("")
        self._code_action_path = String("")
        self._resolved_code_actions = List[CodeAction]()
        self._has_resolved_code_actions = False
        self._inflight_rename_id = String("")
        self._rename_path = String("")
        self._resolved_rename_edits = List[CodeActionFileEdit]()
        self._has_resolved_rename = False
        self._inflight_formatting_id = String("")
        self._formatting_path = String("")
        self._resolved_formatting_edits = List[TextEditEntry]()
        self._has_resolved_formatting = False
        self._inflight_ontype_id = String("")
        self._ontype_path = String("")
        self._resolved_ontype_edits = List[TextEditEntry]()
        self._has_resolved_ontype = False
        self._inflight_moniker_id = String("")
        self._moniker_note = String("")
        self._has_moniker = False
        self._inflight_colorpres_id = String("")
        self._colorpres_labels = List[String]()
        self._colorpres_edits = List[TextEditEntry]()
        self._has_colorpres = False
        self._colorpres_sl = 0
        self._colorpres_sc = 0
        self._colorpres_el = 0
        self._colorpres_ec = 0
        self._inflight_inlinecomp_id = String("")
        self._inlinecomp_text = String("")
        self._inlinecomp_row = 0
        self._inlinecomp_col = 0
        self._has_inlinecomp = False
        self._inflight_linked_id = String("")
        self._linked_ranges = List[TextEditEntry]()
        self._has_linked = False
        self._inflight_inlineval_id = String("")
        self._inlinevals = List[TextEditEntry]()
        self._has_inlinevals = False
        self._inlineval_exprs = List[TextEditEntry]()
        self._inflight_folding_id = String("")
        self._folding_path = String("")
        self._folding_ranges = List[TextEditEntry]()
        self._has_folding = False
        self._inflight_doc_highlight_id = String("")
        self._doc_highlight_path = String("")
        self._resolved_doc_highlights = List[TextEditEntry]()
        self._has_resolved_doc_highlight = False
        self._inflight_signature_id = String("")
        self._resolved_signature = String("")
        self._has_resolved_signature = False
        self._inflight_inlay_id = String("")
        self._inlay_path = String("")
        self._resolved_inlay = List[TextEditEntry]()
        self._has_resolved_inlay = False
        self._inflight_codelens_id = String("")
        self._codelens_path = String("")
        self._resolved_codelens = List[TextEditEntry]()
        self._has_resolved_codelens = False
        self._inflight_codelens_resolve_id = String("")
        self._codelens_resolve_queue = List[JsonValue]()
        self._codelens_resolve_row = 0
        self._codelens_accum = List[TextEditEntry]()
        self._inflight_doclink_id = String("")
        self._doclink_path = String("")
        self._resolved_doclinks = List[TextEditEntry]()
        self._has_resolved_doclinks = False
        self._sem_token_types = List[String]()
        self._inflight_semantic_id = String("")
        self._semantic_path = String("")
        self._resolved_semantic = List[Highlight]()
        self._has_resolved_semantic = False
        self._sem_result_id = String("")
        self._sem_data = List[Int]()
        self._sem_data_path = String("")
        self._progress_note = String("")
        self._has_progress_note = False
        self._server_message = String("")
        self._has_server_message = False
        self._inflight_selrange_id = String("")
        self._selrange_path = String("")
        self._resolved_selrange = List[TextEditEntry]()
        self._has_resolved_selrange = False
        self._inflight_hier_prepare_id = String("")
        self._inflight_hier_followup_id = String("")
        self._hierarchy_followup = String("")
        self._hierarchy_word = String("")
        self._resolved_hierarchy = List[DefinitionResolved]()
        self._has_resolved_hierarchy = False
        self._inflight_color_id = String("")
        self._color_path = String("")
        self._resolved_colors = List[Highlight]()
        self._has_resolved_colors = False
        self._inflight_pull_diag_id = String("")
        self._pull_diag_path = String("")
        self._pulled_paths = List[String]()
        self._inflight_willsave_id = String("")
        self._willsave_path = String("")
        self._resolved_willsave_edits = List[TextEditEntry]()
        self._has_resolved_willsave = False
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
        self._doc_paths = List[String]()
        self._doc_versions = List[Int]()
        self._pending_open_paths = List[String]()
        self._pending_open_texts = List[String]()
        self._diagnostic_buckets = List[_DiagnosticBucket]()
        self._diag_inflight_paths = List[String]()
        self._diag_inflight_versions = List[Int]()
        self._diag_inflight_since_ms = List[Int]()
        self._stderr_log = String("")
        self._log_capture = String("")

    def __copyinit__(mut self, copy: Self):
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
        self._position_encoding = String("utf-16")
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
        self._inflight_nav_id = String("")
        self._nav_word = String("")
        self._resolved_nav = Optional[DefinitionResolved]()
        self._has_resolved_nav = False
        self._inflight_prepare_rename_id = String("")
        self._has_resolved_prepare_rename = False
        self._prepare_rename_state = 0
        self._prepare_rename_placeholder = String("")
        self._inflight_ref_id = String("")
        self._ref_word = String("")
        self._resolved_references = List[DefinitionResolved]()
        self._has_resolved_references = False
        self._inflight_symbol_id = String("")
        self._resolved_symbols = List[SymbolItem]()
        self._has_resolved_symbols = False
        self._symbols_empty = False
        self._inflight_ws_symbol_id = String("")
        self._resolved_ws_symbols = List[WorkspaceSymbolItem]()
        self._has_resolved_ws_symbols = False
        self._inflight_completion_id = String("")
        self._completion_path = String("")
        self._completion_row = 0
        self._completion_col = 0
        self._completion_manual = False
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
        self._inflight_resolve_id = String("")
        self._resolve_aux = List[TextEditEntry]()
        self._resolve_detail = String("")
        self._has_resolve_result = False
        self._inflight_hover_id = String("")
        self._hover_path = String("")
        self._hover_row = 0
        self._hover_col = 0
        self._resolved_hover = String("")
        self._has_resolved_hover = False
        self._inflight_code_action_id = String("")
        self._code_action_path = String("")
        self._resolved_code_actions = List[CodeAction]()
        self._has_resolved_code_actions = False
        self._inflight_rename_id = String("")
        self._rename_path = String("")
        self._resolved_rename_edits = List[CodeActionFileEdit]()
        self._has_resolved_rename = False
        self._inflight_formatting_id = String("")
        self._formatting_path = String("")
        self._resolved_formatting_edits = List[TextEditEntry]()
        self._has_resolved_formatting = False
        self._inflight_ontype_id = String("")
        self._ontype_path = String("")
        self._resolved_ontype_edits = List[TextEditEntry]()
        self._has_resolved_ontype = False
        self._inflight_moniker_id = String("")
        self._moniker_note = String("")
        self._has_moniker = False
        self._inflight_colorpres_id = String("")
        self._colorpres_labels = List[String]()
        self._colorpres_edits = List[TextEditEntry]()
        self._has_colorpres = False
        self._colorpres_sl = 0
        self._colorpres_sc = 0
        self._colorpres_el = 0
        self._colorpres_ec = 0
        self._inflight_inlinecomp_id = String("")
        self._inlinecomp_text = String("")
        self._inlinecomp_row = 0
        self._inlinecomp_col = 0
        self._has_inlinecomp = False
        self._inflight_linked_id = String("")
        self._linked_ranges = List[TextEditEntry]()
        self._has_linked = False
        self._inflight_inlineval_id = String("")
        self._inlinevals = List[TextEditEntry]()
        self._has_inlinevals = False
        self._inlineval_exprs = List[TextEditEntry]()
        self._inflight_folding_id = String("")
        self._folding_path = String("")
        self._folding_ranges = List[TextEditEntry]()
        self._has_folding = False
        self._inflight_doc_highlight_id = String("")
        self._doc_highlight_path = String("")
        self._resolved_doc_highlights = List[TextEditEntry]()
        self._has_resolved_doc_highlight = False
        self._inflight_signature_id = String("")
        self._resolved_signature = String("")
        self._has_resolved_signature = False
        self._inflight_inlay_id = String("")
        self._inlay_path = String("")
        self._resolved_inlay = List[TextEditEntry]()
        self._has_resolved_inlay = False
        self._inflight_codelens_id = String("")
        self._codelens_path = String("")
        self._resolved_codelens = List[TextEditEntry]()
        self._has_resolved_codelens = False
        self._inflight_codelens_resolve_id = String("")
        self._codelens_resolve_queue = List[JsonValue]()
        self._codelens_resolve_row = 0
        self._codelens_accum = List[TextEditEntry]()
        self._inflight_doclink_id = String("")
        self._doclink_path = String("")
        self._resolved_doclinks = List[TextEditEntry]()
        self._has_resolved_doclinks = False
        self._sem_token_types = List[String]()
        self._inflight_semantic_id = String("")
        self._semantic_path = String("")
        self._resolved_semantic = List[Highlight]()
        self._has_resolved_semantic = False
        self._sem_result_id = String("")
        self._sem_data = List[Int]()
        self._sem_data_path = String("")
        self._progress_note = String("")
        self._has_progress_note = False
        self._server_message = String("")
        self._has_server_message = False
        self._inflight_selrange_id = String("")
        self._selrange_path = String("")
        self._resolved_selrange = List[TextEditEntry]()
        self._has_resolved_selrange = False
        self._inflight_hier_prepare_id = String("")
        self._inflight_hier_followup_id = String("")
        self._hierarchy_followup = String("")
        self._hierarchy_word = String("")
        self._resolved_hierarchy = List[DefinitionResolved]()
        self._has_resolved_hierarchy = False
        self._inflight_color_id = String("")
        self._color_path = String("")
        self._resolved_colors = List[Highlight]()
        self._has_resolved_colors = False
        self._inflight_pull_diag_id = String("")
        self._pull_diag_path = String("")
        self._pulled_paths = List[String]()
        self._inflight_willsave_id = String("")
        self._willsave_path = String("")
        self._resolved_willsave_edits = List[TextEditEntry]()
        self._has_resolved_willsave = False
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
        self._doc_paths = List[String]()
        self._doc_versions = List[Int]()
        self._pending_open_paths = List[String]()
        self._pending_open_texts = List[String]()
        self._diagnostic_buckets = List[_DiagnosticBucket]()
        self._diag_inflight_paths = List[String]()
        self._diag_inflight_versions = List[Int]()
        self._diag_inflight_since_ms = List[Int]()
        self._stderr_log = String("")
        self._log_capture = String("")

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

    def inflight_symbols(self) -> Bool:
        return len(self._inflight_symbol_id.as_bytes()) > 0

    def symbols_empty(self) -> Bool:
        return self._symbols_empty

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
        return self._stderr_log

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

    def peek_diagnostics_for(self, path: String) -> List[Diagnostic]:
        """Return the latest published diagnostic list for ``path``
        without flipping the consumed flag. Used when a fresh editor
        opens against an already-published path so it picks up the
        cached set without round-tripping the server."""
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                return self._diagnostic_buckets[k].diags.copy()
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
        push path writes, so the host consumes them identically. Single
        in-flight slot — a fresh pull shadows any prior one (per-path
        races just defer the older path's refresh to its next pull).
        No-op unless ready and the server advertises ``diagnosticProvider``;
        assumes the document is already open (caller pre-flights via the
        normal didOpen/didChange path)."""
        if self.state != _STATE_READY or not self.supports_pull_diagnostics():
            return False
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        try:
            self._inflight_pull_diag_id = self.client.send_request(
                String("textDocument/diagnostic"), params,
            )
        except:
            self._inflight_pull_diag_id = String("")
            return False
        self._pull_diag_path = path
        if not self.has_pulled(path):
            self._pulled_paths.append(path)
        return True

    # --- lifecycle ---------------------------------------------------------

    def start_with(
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

    def start_mojo(mut self, root_path: String, include_dirs: List[String]):
        """Spawn ``mojo-lsp-server``. ``include_dirs`` map to ``-I <dir>``
        CLI flags — without these the server can't resolve project
        imports and every Cmd+click comes back empty."""
        var argv = List[String]()
        argv.append(String("mojo-lsp-server"))
        for i in range(len(include_dirs)):
            argv.append(String("-I"))
            argv.append(include_dirs[i])
        self.start_with(String("mojo"), argv, root_path)

    def start_python(mut self, root_path: String) -> Bool:
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

    def shutdown(mut self):
        """Best-effort: terminate the child if alive. Idempotent."""
        if self.state == _STATE_NOT_STARTED:
            return
        self.client.terminate()
        self.state = _STATE_NOT_STARTED

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
            self._pending_open_paths.append(path)
            self._pending_open_texts.append(text^)
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
        var opened = False
        for k in range(len(self._doc_paths)):
            if self._doc_paths[k] == path:
                opened = True
                break
        if not opened:
            return
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        if self.save_includes_text():
            params.put(String("text"), json_str(text^))
        try:
            self.client.send_notification(
                String("textDocument/didSave"), params,
            )
        except e:
            print("lsp: didSave", path, ":", String(e))

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
            while j < len(self._pending_open_paths):
                if self._pending_open_paths[j] == path:
                    _ = self._pending_open_paths.pop(j)
                    _ = self._pending_open_texts.pop(j)
                else:
                    j += 1
            return
        var idx = -1
        for k in range(len(self._doc_paths)):
            if self._doc_paths[k] == path:
                idx = k
                break
        if idx < 0:
            return
        _ = self._doc_paths.pop(idx)
        _ = self._doc_versions.pop(idx)
        # Drop any "analyzing edits…" spinner state — a closed buffer
        # must not keep one spinning.
        self._clear_diag_inflight(path, 0)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        try:
            self.client.send_notification(
                String("textDocument/didClose"), params,
            )
        except e:
            print("lsp: didClose", path, ":", String(e))

    def notify_watched_changed(mut self, path: String, change_type: Int):
        """Send ``workspace/didChangeWatchedFiles`` for one on-disk change
        (``change_type``: 1=created, 2=changed, 3=deleted), but only when
        ready and the server actually registered a watcher. Lets servers
        re-index files that changed outside an open buffer — e.g.
        rust-analyzer reacting to a saved ``Cargo.toml`` or a sibling
        module the buffer imports. We don't model the registered glob
        patterns, so a watcher may receive events for paths outside its
        set; that's spec-legal (servers ignore paths they don't track)
        and far cheaper than mirroring the matcher."""
        if self.state != _STATE_READY or not self._watches_files:
            return
        var params = json_object()
        var changes = json_array()
        var change = json_object()
        change.put(String("uri"), json_str(_path_to_uri(path)))
        change.put(String("type"), json_int(change_type))
        changes.append(change^)
        params.put(String("changes"), changes^)
        try:
            self.client.send_notification(
                String("workspace/didChangeWatchedFiles"), params,
            )
        except e:
            print("lsp: didChangeWatchedFiles", path, ":", String(e))

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
        try:
            self.client.send_notification(
                String("workspace/didChangeConfiguration"), params,
            )
        except e:
            print("lsp: didChangeConfiguration", ":", String(e))

    def server_wants_did_create(self) -> Bool:
        """True iff the server advertised
        ``workspace.fileOperations.didCreate`` — it wants a
        ``workspace/didCreateFiles`` notification when files are created
        (so it can fix up imports / index the new file)."""
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var ws_opt = caps.object_get(String("workspace"))
        if not ws_opt or not ws_opt.value().is_object():
            return False
        var fo_opt = ws_opt.value().copy().object_get(
            String("fileOperations"),
        )
        if not fo_opt or not fo_opt.value().is_object():
            return False
        var dc_opt = fo_opt.value().copy().object_get(String("didCreate"))
        if not dc_opt:
            return False
        var dc = dc_opt.value().copy()
        if dc.is_bool():
            return dc.as_bool()
        return dc.is_object()

    def notify_did_create_files(mut self, path: String):
        """Send ``workspace/didCreateFiles`` for one newly-created file, but
        only when ready and the server registered interest. We don't model
        the registered glob filters — a server still receives events for
        paths outside its set, which it ignores (spec-legal)."""
        if self.state != _STATE_READY or not self.server_wants_did_create():
            return
        var params = json_object()
        var files = json_array()
        var f = json_object()
        f.put(String("uri"), json_str(_path_to_uri(path)))
        files.append(f^)
        params.put(String("files"), files^)
        try:
            self.client.send_notification(
                String("workspace/didCreateFiles"), params,
            )
        except e:
            print("lsp: didCreateFiles", path, ":", String(e))

    def notify_will_save(mut self, path: String, reason: Int):
        """Send ``textDocument/willSave`` (``reason``: 1=manual, 2=after-
        delay, 3=focus-out) so the server can react before the buffer is
        written. Fire-and-forget; no-op unless ready and the server set
        ``textDocumentSync.willSave``."""
        if self.state != _STATE_READY or not self.server_supports_will_save():
            return
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        params.put(String("reason"), json_int(reason))
        try:
            self.client.send_notification(
                String("textDocument/willSave"), params,
            )
        except e:
            print("lsp: willSave", path, ":", String(e))

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
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        params.put(String("reason"), json_int(reason))
        try:
            self._inflight_willsave_id = self.client.send_request(
                String("textDocument/willSaveWaitUntil"), params,
            )
        except:
            self._inflight_willsave_id = String("")
            return False
        self._willsave_path = path
        self._resolved_willsave_edits = List[TextEditEntry]()
        self._has_resolved_willsave = False
        return True

    def has_pending_willsave(self) -> Bool:
        return self._has_resolved_willsave

    def pending_willsave_path(self) -> String:
        return self._willsave_path

    def take_willsave_edits(mut self) -> List[TextEditEntry]:
        var out = self._resolved_willsave_edits^
        self._resolved_willsave_edits = List[TextEditEntry]()
        self._has_resolved_willsave = False
        return out^

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
        _lsp_debug_log(
            String("→ request_definition lang=") + self._language_id
            + String(" path=") + path
            + String(" line=") + String(line)
            + String(" character=") + String(character)
            + String(" word=") + word
            + String(" text_len=") + String(len(text.as_bytes())),
        )
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_def_id = self.client.send_request(
                String("textDocument/definition"), params,
            )
        except:
            self._inflight_def_id = String("")
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

    def server_supports(self, key: String) -> Bool:
        """True iff the server advertised the capability named ``key`` in
        its initialize response (e.g. ``implementationProvider``,
        ``documentFormattingProvider``, ``inlayHintProvider``). A boolean
        ``true`` or any registration-options object/string counts as
        supported; absent or ``false`` counts as unsupported."""
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var v_opt = caps.object_get(key)
        if not v_opt:
            return False
        var v = v_opt.value().copy()
        if v.is_bool():
            return v.as_bool()
        return v.is_object() or v.is_string() or v.is_array()

    def server_supports_prepare_rename(self) -> Bool:
        """True iff ``renameProvider`` is an object with
        ``prepareProvider: true`` — i.e. the server implements
        ``textDocument/prepareRename``. Plain ``renameProvider: true``
        means rename works but prepare does not."""
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var rp_opt = caps.object_get(String("renameProvider"))
        if not rp_opt or not rp_opt.value().is_object():
            return False
        var pp_opt = rp_opt.value().copy().object_get(String("prepareProvider"))
        if pp_opt and pp_opt.value().is_bool():
            return pp_opt.value().as_bool()
        return False

    def save_includes_text(self) -> Bool:
        """True iff the server's ``textDocumentSync.save`` is an object
        with ``includeText: true`` — i.e. it wants the full buffer text
        on ``didSave``. A plain ``save: true`` (or an int sync kind)
        means notify-only, so we send just the URI."""
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var sync_opt = caps.object_get(String("textDocumentSync"))
        if not sync_opt or not sync_opt.value().is_object():
            return False
        var save_opt = sync_opt.value().copy().object_get(String("save"))
        if not save_opt or not save_opt.value().is_object():
            return False
        var inc_opt = save_opt.value().copy().object_get(String("includeText"))
        if inc_opt and inc_opt.value().is_bool():
            return inc_opt.value().as_bool()
        return False

    def _text_sync_bool(self, key: String) -> Bool:
        """Read a boolean flag (``willSave`` / ``willSaveWaitUntil``) off
        the object form of ``textDocumentSync``. The int / absent forms
        mean the feature is unsupported."""
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var sync_opt = caps.object_get(String("textDocumentSync"))
        if not sync_opt or not sync_opt.value().is_object():
            return False
        var f_opt = sync_opt.value().copy().object_get(key)
        if f_opt and f_opt.value().is_bool():
            return f_opt.value().as_bool()
        return False

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
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var cp_opt = caps.object_get(String("completionProvider"))
        if not cp_opt or not cp_opt.value().is_object():
            return False
        var rp_opt = cp_opt.value().copy().object_get(String("resolveProvider"))
        if rp_opt and rp_opt.value().is_bool():
            return rp_opt.value().as_bool()
        return False

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
        _lsp_debug_log(
            String("→ request_navigation ") + method
            + String(" lang=") + self._language_id
            + String(" line=") + String(line)
            + String(" character=") + String(character),
        )
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_nav_id = self.client.send_request(method, params)
        except:
            self._inflight_nav_id = String("")
            return False
        self._nav_word = word^
        self._resolved_nav = Optional[DefinitionResolved]()
        self._has_resolved_nav = False
        return True

    def has_pending_nav(self) -> Bool:
        """True iff a navigation response is parked. The parked target may
        still be empty (server found nothing) — distinguish via
        ``take_nav_target`` returning None."""
        return self._has_resolved_nav

    def nav_word(self) -> String:
        return self._nav_word

    def take_nav_target(mut self) -> Optional[DefinitionResolved]:
        """Move out the parked navigation target (None if the server
        returned no location). Clears the pending flag either way."""
        var out = self._resolved_nav
        self._resolved_nav = Optional[DefinitionResolved]()
        self._has_resolved_nav = False
        return out

    # --- prepareRename ----------------------------------------------------

    def request_prepare_rename(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/prepareRename`` to validate the symbol at
        ``(line, character)`` and fetch its placeholder before prompting.
        Parks a tri-state result drained via ``take_prepare_rename``."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_prepare_rename_id = self.client.send_request(
                String("textDocument/prepareRename"), params,
            )
        except:
            self._inflight_prepare_rename_id = String("")
            return False
        self._has_resolved_prepare_rename = False
        self._prepare_rename_state = 0
        self._prepare_rename_placeholder = String("")
        return True

    def has_pending_prepare_rename(self) -> Bool:
        return self._has_resolved_prepare_rename

    def take_prepare_rename(mut self) -> Tuple[Int, String]:
        """Return ``(state, placeholder)`` and clear the pending flag.
        ``state``: 0 unsupported/error, 1 renameable, 2 not renameable."""
        var st = self._prepare_rename_state
        var ph = self._prepare_rename_placeholder
        self._has_resolved_prepare_rename = False
        self._prepare_rename_state = 0
        self._prepare_rename_placeholder = String("")
        return (st, ph)

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
        _lsp_debug_log(
            String("→ request_references lang=") + self._language_id
            + String(" path=") + path
            + String(" line=") + String(line)
            + String(" character=") + String(character)
            + String(" word=") + word,
        )
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        var ctx = json_object()
        ctx.put(String("includeDeclaration"), json_bool(True))
        params.put(String("context"), ctx^)
        try:
            self._inflight_ref_id = self.client.send_request(
                String("textDocument/references"), params,
            )
        except:
            self._inflight_ref_id = String("")
            return False
        self._ref_word = word^
        self._has_resolved_references = False
        self._resolved_references = List[DefinitionResolved]()
        return True

    def has_pending_references(self) -> Bool:
        """True iff a parsed references response is parked for ``take``."""
        return self._has_resolved_references

    def take_references(mut self) -> List[DefinitionResolved]:
        """Move the parked references list out of the manager. Pair with
        ``has_pending_references()`` — the flag is cleared either way."""
        var out = self._resolved_references^
        self._resolved_references = List[DefinitionResolved]()
        self._has_resolved_references = False
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
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        try:
            self._inflight_symbol_id = self.client.send_request(
                String("textDocument/documentSymbol"), params,
            )
        except:
            self._inflight_symbol_id = String("")
            return False
        self._has_resolved_symbols = False
        self._resolved_symbols = List[SymbolItem]()
        self._symbols_empty = False
        return True

    def has_pending_symbols(self) -> Bool:
        """True iff a parsed symbol response is parked, ready for ``take``."""
        return self._has_resolved_symbols

    def take_symbols(mut self) -> List[SymbolItem]:
        """Move the parked symbol list out of the manager.

        Pair with ``has_pending_symbols()`` — calling this when nothing is
        parked just hands back an empty list. The flag is cleared either
        way so a subsequent call returns empty.
        """
        var out = self._resolved_symbols^
        self._resolved_symbols = List[SymbolItem]()
        self._has_resolved_symbols = False
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
        try:
            self._inflight_ws_symbol_id = self.client.send_request(
                String("workspace/symbol"), params,
            )
        except:
            self._inflight_ws_symbol_id = String("")
            return False
        self._has_resolved_ws_symbols = False
        self._resolved_ws_symbols = List[WorkspaceSymbolItem]()
        return True

    def inflight_workspace_symbols(self) -> Bool:
        return len(self._inflight_ws_symbol_id.as_bytes()) > 0

    def has_pending_workspace_symbols(self) -> Bool:
        """True iff a parsed workspace-symbol response is parked."""
        return self._has_resolved_ws_symbols

    def take_workspace_symbols(
        mut self,
    ) -> List[WorkspaceSymbolItem]:
        """Move the parked workspace-symbol list out of the manager.
        Pair with ``has_pending_workspace_symbols()`` to distinguish
        "no response yet" from "empty list"."""
        var out = self._resolved_ws_symbols^
        self._resolved_ws_symbols = List[WorkspaceSymbolItem]()
        self._has_resolved_ws_symbols = False
        return out^

    def _send_cancel(mut self, var request_id: String, context: String):
        """Best-effort ``$/cancelRequest`` for ``request_id``. The cancel is
        a notification (no response), so a send failure is logged with
        ``context`` and otherwise ignored — if the server already returned,
        the cancel is a no-op anyway."""
        var cancel_params = json_object()
        cancel_params.put(String("id"), json_str(request_id))
        try:
            self.client.send_notification(
                String("$/cancelRequest"), cancel_params,
            )
        except e:
            print("lsp: cancelRequest (" + context + "):", String(e))

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
        _lsp_debug_log(
            String("→ request_completion lang=") + self._language_id
            + String(" path=") + path
            + String(" line=") + String(line)
            + String(" character=") + String(character),
        )
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
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
        if len(self._inflight_completion_id.as_bytes()) > 0:
            self._send_cancel(
                self._inflight_completion_id, String("completion"),
            )
        try:
            self._inflight_completion_id = self.client.send_request(
                String("textDocument/completion"), params,
            )
        except:
            self._inflight_completion_id = String("")
            return False
        self._completion_path = path
        self._completion_row = line
        self._completion_col = character
        self._completion_manual = manual
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
        return True

    def cancel_completion(mut self):
        """Cancel any in-flight completion request.

        Sends ``$/cancelRequest`` so the server can drop work it has
        already started, and clears ``_inflight_completion_id`` so a
        late response — if one slips in before the cancel propagates —
        is ignored by the response handler instead of being parked
        for the host. Also clears any parked-but-unconsumed completion
        list (the user dismissed the popup; that list is irrelevant).
        No-op when nothing is in flight."""
        if len(self._inflight_completion_id.as_bytes()) == 0 \
                and not self._has_resolved_completions:
            return
        if len(self._inflight_completion_id.as_bytes()) > 0:
            _lsp_debug_log(
                String("→ cancel_completion id=")
                + self._inflight_completion_id
                + String(" lang=") + self._language_id,
            )
            self._send_cancel(
                self._inflight_completion_id, String("cancel_completion"),
            )
            self._inflight_completion_id = String("")
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False

    def has_pending_completions(self) -> Bool:
        """True iff a parsed completion response is parked for ``take``."""
        return self._has_resolved_completions

    def pending_completion_path(self) -> String:
        return self._completion_path

    def pending_completion_row(self) -> Int:
        return self._completion_row

    def pending_completion_col(self) -> Int:
        return self._completion_col

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
        var out = self._resolved_completions^
        self._resolved_completions = List[CompletionItem]()
        self._has_resolved_completions = False
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
        try:
            self._inflight_resolve_id = self.client.send_request(
                String("completionItem/resolve"), ci,
            )
        except:
            self._inflight_resolve_id = String("")
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
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        # Cancel any prior in-flight hover so the server doesn't keep
        # working on a stale position. Mirrors ``request_completion``.
        if len(self._inflight_hover_id.as_bytes()) > 0:
            self._send_cancel(self._inflight_hover_id, String("hover"))
        try:
            self._inflight_hover_id = self.client.send_request(
                String("textDocument/hover"), params,
            )
        except:
            self._inflight_hover_id = String("")
            return False
        self._hover_path = path
        self._hover_row = line
        self._hover_col = character
        self._resolved_hover = String("")
        self._has_resolved_hover = False
        return True

    def has_pending_hover(self) -> Bool:
        """True iff a parsed hover response is parked for ``take``."""
        return self._has_resolved_hover

    def pending_hover_path(self) -> String:
        return self._hover_path

    def pending_hover_row(self) -> Int:
        return self._hover_row

    def pending_hover_col(self) -> Int:
        return self._hover_col

    def take_hover_text(mut self) -> String:
        """Move the parked hover text out of the manager. Pair with
        ``has_pending_hover()`` — the flag is cleared either way."""
        var out = self._resolved_hover^
        self._resolved_hover = String("")
        self._has_resolved_hover = False
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
        _lsp_debug_log(
            String("→ request_code_actions lang=") + self._language_id
            + String(" path=") + path
            + String(" range=(") + String(diag.start_row)
            + String(",") + String(diag.start_col)
            + String(")-(") + String(diag.end_row)
            + String(",") + String(diag.end_col) + String(")"),
        )
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        var rng = json_object()
        rng.put(String("start"), _lsp_position(diag.start_row, diag.start_col))
        rng.put(String("end"), _lsp_position(diag.end_row, diag.end_col))
        params.put(String("range"), rng^)
        var ctx = json_object()
        var diag_obj = json_object()
        var d_rng = json_object()
        d_rng.put(String("start"), _lsp_position(diag.start_row, diag.start_col))
        d_rng.put(String("end"), _lsp_position(diag.end_row, diag.end_col))
        diag_obj.put(String("range"), d_rng^)
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
        diags_arr.append(diag_obj^)
        ctx.put(String("diagnostics"), diags_arr^)
        params.put(String("context"), ctx^)
        try:
            self._inflight_code_action_id = self.client.send_request(
                String("textDocument/codeAction"), params,
            )
        except:
            self._inflight_code_action_id = String("")
            return False
        self._code_action_path = path
        self._resolved_code_actions = List[CodeAction]()
        self._has_resolved_code_actions = False
        return True

    def has_pending_code_actions(self) -> Bool:
        """True iff a parsed code-action response is parked for ``take``.
        Pair with ``pending_code_action_path()`` to distinguish "still
        waiting" from "empty list for this file"."""
        return self._has_resolved_code_actions

    def pending_code_action_path(self) -> String:
        """Path the most recent code-action request was issued for. Lets
        the host drop a stale response when the user has dismissed the
        diagnostic menu before the server replied."""
        return self._code_action_path

    def take_code_actions(mut self) -> List[CodeAction]:
        """Move the parked code-action list out of the manager. Pair
        with ``has_pending_code_actions()`` — the flag is cleared either
        way so a follow-up call returns empty."""
        var out = self._resolved_code_actions^
        self._resolved_code_actions = List[CodeAction]()
        self._has_resolved_code_actions = False
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
            _ = self.client.send_request(
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
        _lsp_debug_log(
            String("→ request_rename lang=") + self._language_id
            + String(" path=") + path
            + String(" line=") + String(line)
            + String(" character=") + String(character)
            + String(" new_name=") + new_name,
        )
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        params.put(String("newName"), json_str(new_name))
        try:
            self._inflight_rename_id = self.client.send_request(
                String("textDocument/rename"), params,
            )
        except:
            self._inflight_rename_id = String("")
            return False
        self._rename_path = path
        self._resolved_rename_edits = List[CodeActionFileEdit]()
        self._has_resolved_rename = False
        return True

    def has_pending_rename(self) -> Bool:
        """True iff a parsed rename ``WorkspaceEdit`` is parked for ``take``.
        An empty list with the flag set means "server replied but had no
        edits" (rename unsupported / nothing to rename)."""
        return self._has_resolved_rename

    def pending_rename_path(self) -> String:
        """Path the most recent rename request was issued for."""
        return self._rename_path

    def take_rename_edits(mut self) -> List[CodeActionFileEdit]:
        """Move the parked rename edits out of the manager. Clears the
        pending flag either way."""
        var out = self._resolved_rename_edits^
        self._resolved_rename_edits = List[CodeActionFileEdit]()
        self._has_resolved_rename = False
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
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        params.put(String("options"), _formatting_options(tab_size, insert_spaces))
        try:
            self._inflight_formatting_id = self.client.send_request(
                String("textDocument/formatting"), params,
            )
        except:
            self._inflight_formatting_id = String("")
            return False
        self._formatting_path = path
        self._resolved_formatting_edits = List[TextEditEntry]()
        self._has_resolved_formatting = False
        return True

    def request_range_formatting(
        mut self, path: String, start_line: Int, start_char: Int,
        end_line: Int, end_char: Int, var text: String,
        tab_size: Int = 4, insert_spaces: Bool = True,
    ) -> Bool:
        """Send ``textDocument/rangeFormatting`` for the given range."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        var rng = json_object()
        rng.put(String("start"), _lsp_position(start_line, start_char))
        rng.put(String("end"), _lsp_position(end_line, end_char))
        params.put(String("range"), rng^)
        params.put(String("options"), _formatting_options(tab_size, insert_spaces))
        try:
            self._inflight_formatting_id = self.client.send_request(
                String("textDocument/rangeFormatting"), params,
            )
        except:
            self._inflight_formatting_id = String("")
            return False
        self._formatting_path = path
        self._resolved_formatting_edits = List[TextEditEntry]()
        self._has_resolved_formatting = False
        return True

    def has_pending_formatting(self) -> Bool:
        return self._has_resolved_formatting

    def pending_formatting_path(self) -> String:
        return self._formatting_path

    def take_formatting_edits(mut self) -> List[TextEditEntry]:
        """Move out the parked formatting ``TextEdit[]``. Clears the flag."""
        var out = self._resolved_formatting_edits^
        self._resolved_formatting_edits = List[TextEditEntry]()
        self._has_resolved_formatting = False
        return out^

    def on_type_trigger_chars(self) -> String:
        """The concatenated set of characters that trigger
        ``onTypeFormatting`` (``firstTriggerCharacter`` +
        ``moreTriggerCharacter[]``), or empty when unsupported. The host
        only fires a request when the just-typed char is in this set."""
        if not self._capabilities:
            return String("")
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return String("")
        var p_opt = caps.object_get(String("documentOnTypeFormattingProvider"))
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
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        params.put(String("position"), _lsp_position(line, character))
        params.put(String("ch"), json_str(ch))
        params.put(String("options"), _formatting_options(tab_size, insert_spaces))
        try:
            self._inflight_ontype_id = self.client.send_request(
                String("textDocument/onTypeFormatting"), params,
            )
        except:
            self._inflight_ontype_id = String("")
            return False
        self._ontype_path = path
        self._resolved_ontype_edits = List[TextEditEntry]()
        self._has_resolved_ontype = False
        return True

    def has_pending_ontype(self) -> Bool:
        return self._has_resolved_ontype

    def pending_ontype_path(self) -> String:
        return self._ontype_path

    def take_ontype_edits(mut self) -> List[TextEditEntry]:
        var out = self._resolved_ontype_edits^
        self._resolved_ontype_edits = List[TextEditEntry]()
        self._has_resolved_ontype = False
        return out^

    def request_moniker(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/moniker`` for the symbol at ``(line,
        character)``. The parsed ``scheme:identifier`` list is parked as a
        status string."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_moniker_id = self.client.send_request(
                String("textDocument/moniker"), params,
            )
        except:
            self._inflight_moniker_id = String("")
            return False
        self._moniker_note = String("")
        self._has_moniker = False
        return True

    def has_moniker(self) -> Bool:
        return self._has_moniker

    def take_moniker(mut self) -> String:
        var out = self._moniker_note^
        self._moniker_note = String("")
        self._has_moniker = False
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
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var color = json_object()
        color.put(String("red"), json_float(_unit_text(r)))
        color.put(String("green"), json_float(_unit_text(g)))
        color.put(String("blue"), json_float(_unit_text(b)))
        color.put(String("alpha"), json_float(String("1.0")))
        var rng = json_object()
        rng.put(String("start"), _lsp_position(start_line, start_char))
        rng.put(String("end"), _lsp_position(end_line, end_char))
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        params.put(String("color"), color^)
        params.put(String("range"), rng^)
        try:
            self._inflight_colorpres_id = self.client.send_request(
                String("textDocument/colorPresentation"), params,
            )
        except:
            self._inflight_colorpres_id = String("")
            return False
        self._colorpres_sl = start_line
        self._colorpres_sc = start_char
        self._colorpres_el = end_line
        self._colorpres_ec = end_char
        self._colorpres_labels = List[String]()
        self._colorpres_edits = List[TextEditEntry]()
        self._has_colorpres = False
        return True

    def has_color_presentations(self) -> Bool:
        return self._has_colorpres

    def color_presentation_labels(self) -> List[String]:
        return self._colorpres_labels.copy()

    def take_color_presentation_edit(
        mut self, index: Int,
    ) -> List[TextEditEntry]:
        """Return the chosen presentation's edit (as a one-element list) and
        clear all parked presentations. Empty list for an out-of-range
        index."""
        var out = List[TextEditEntry]()
        if 0 <= index and index < len(self._colorpres_edits):
            out.append(self._colorpres_edits[index])
        self._colorpres_labels = List[String]()
        self._colorpres_edits = List[TextEditEntry]()
        self._has_colorpres = False
        return out^

    def request_inline_completion(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/inlineCompletion`` at ``(line, character)``
        (manually invoked). The first item's insert text is parked as a
        ghost-text suggestion anchored at the request position."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        params.put(String("position"), _lsp_position(line, character))
        var ctx = json_object()
        ctx.put(String("triggerKind"), json_int(1))  # Invoked
        params.put(String("context"), ctx^)
        try:
            self._inflight_inlinecomp_id = self.client.send_request(
                String("textDocument/inlineCompletion"), params,
            )
        except:
            self._inflight_inlinecomp_id = String("")
            return False
        self._inlinecomp_row = line
        self._inlinecomp_col = character
        self._inlinecomp_text = String("")
        self._has_inlinecomp = False
        return True

    def has_inline_completion(self) -> Bool:
        return self._has_inlinecomp

    def inline_completion_text(self) -> String:
        return self._inlinecomp_text

    def inline_completion_row(self) -> Int:
        return self._inlinecomp_row

    def inline_completion_col(self) -> Int:
        return self._inlinecomp_col

    def clear_inline_completion(mut self):
        self._has_inlinecomp = False
        self._inlinecomp_text = String("")

    def request_linked_editing(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/linkedEditingRange`` at ``(line, character)``.
        Parks the linked ranges (range carriers) for the host to place
        synchronized carets at."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_linked_id = self.client.send_request(
                String("textDocument/linkedEditingRange"), params,
            )
        except:
            self._inflight_linked_id = String("")
            return False
        self._linked_ranges = List[TextEditEntry]()
        self._has_linked = False
        return True

    def has_linked_editing(self) -> Bool:
        return self._has_linked

    def take_linked_ranges(mut self) -> List[TextEditEntry]:
        var out = self._linked_ranges^
        self._linked_ranges = List[TextEditEntry]()
        self._has_linked = False
        return out^

    def request_inline_values(
        mut self, path: String, start_line: Int, end_line: Int,
        stopped_line: Int, frame_id: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/inlineValue`` for the ``[start_line,
        end_line]`` range with the debugger's stopped context. Parks the
        ``InlineValueText`` entries as (row, text) carriers for end-of-line
        rendering."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        var rng = json_object()
        rng.put(String("start"), _lsp_position(start_line, 0))
        rng.put(String("end"), _lsp_position(end_line, 0))
        params.put(String("range"), rng^)
        var ctx = json_object()
        ctx.put(String("frameId"), json_int(frame_id))
        var stopped = json_object()
        stopped.put(String("start"), _lsp_position(stopped_line, 0))
        stopped.put(String("end"), _lsp_position(stopped_line, 0))
        ctx.put(String("stoppedLocation"), stopped^)
        params.put(String("context"), ctx^)
        try:
            self._inflight_inlineval_id = self.client.send_request(
                String("textDocument/inlineValue"), params,
            )
        except:
            self._inflight_inlineval_id = String("")
            return False
        self._inlinevals = List[TextEditEntry]()
        self._has_inlinevals = False
        self._inlineval_exprs = List[TextEditEntry]()
        return True

    def has_inline_values(self) -> Bool:
        return self._has_inlinevals

    def take_inline_values(mut self) -> List[TextEditEntry]:
        var out = self._inlinevals^
        self._inlinevals = List[TextEditEntry]()
        self._has_inlinevals = False
        return out^

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
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        try:
            self._inflight_folding_id = self.client.send_request(
                String("textDocument/foldingRange"), params,
            )
        except:
            self._inflight_folding_id = String("")
            return False
        self._folding_path = path
        self._folding_ranges = List[TextEditEntry]()
        self._has_folding = False
        return True

    def has_pending_folding(self) -> Bool:
        return self._has_folding

    def pending_folding_path(self) -> String:
        return self._folding_path

    def take_folding_ranges(mut self) -> List[TextEditEntry]:
        var out = self._folding_ranges^
        self._folding_ranges = List[TextEditEntry]()
        self._has_folding = False
        return out^

    # --- document highlight ----------------------------------------------

    def request_document_highlight(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/documentHighlight`` for the symbol at
        ``(line, character)``. Parks the occurrence ranges."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_doc_highlight_id = self.client.send_request(
                String("textDocument/documentHighlight"), params,
            )
        except:
            self._inflight_doc_highlight_id = String("")
            return False
        self._doc_highlight_path = path
        self._resolved_doc_highlights = List[TextEditEntry]()
        self._has_resolved_doc_highlight = False
        return True

    def has_pending_doc_highlights(self) -> Bool:
        return self._has_resolved_doc_highlight

    def pending_doc_highlight_path(self) -> String:
        return self._doc_highlight_path

    def take_doc_highlights(mut self) -> List[TextEditEntry]:
        var out = self._resolved_doc_highlights^
        self._resolved_doc_highlights = List[TextEditEntry]()
        self._has_resolved_doc_highlight = False
        return out^

    # --- signature help ---------------------------------------------------

    def request_signature_help(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/signatureHelp`` at ``(line, character)``.
        Parks the rendered active-signature label for the status bar."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_signature_id = self.client.send_request(
                String("textDocument/signatureHelp"), params,
            )
        except:
            self._inflight_signature_id = String("")
            return False
        self._resolved_signature = String("")
        self._has_resolved_signature = False
        return True

    def has_pending_signature(self) -> Bool:
        return self._has_resolved_signature

    def take_signature(mut self) -> String:
        """Move out the parked signature label (empty if the server had no
        signature here). Clears the pending flag."""
        var out = self._resolved_signature^
        self._resolved_signature = String("")
        self._has_resolved_signature = False
        return out^

    # --- inlay hints / code lens -----------------------------------------

    def request_inlay_hints(
        mut self, path: String, start_line: Int, end_line: Int,
        var text: String,
    ) -> Bool:
        """Send ``textDocument/inlayHint`` for the ``[start_line, end_line]``
        range (typically the visible rows). Parks (row, label) carriers."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        var rng = json_object()
        rng.put(String("start"), _lsp_position(start_line, 0))
        rng.put(String("end"), _lsp_position(end_line, 0))
        params.put(String("range"), rng^)
        try:
            self._inflight_inlay_id = self.client.send_request(
                String("textDocument/inlayHint"), params,
            )
        except:
            self._inflight_inlay_id = String("")
            return False
        self._inlay_path = path
        self._resolved_inlay = List[TextEditEntry]()
        self._has_resolved_inlay = False
        return True

    def has_pending_inlay(self) -> Bool:
        return self._has_resolved_inlay

    def pending_inlay_path(self) -> String:
        return self._inlay_path

    def take_inlay(mut self) -> List[TextEditEntry]:
        var out = self._resolved_inlay^
        self._resolved_inlay = List[TextEditEntry]()
        self._has_resolved_inlay = False
        return out^

    def request_code_lens(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Send ``textDocument/codeLens`` for the whole file. Parks
        (row, title) carriers for lenses that carry a resolved command."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        try:
            self._inflight_codelens_id = self.client.send_request(
                String("textDocument/codeLens"), params,
            )
        except:
            self._inflight_codelens_id = String("")
            return False
        self._codelens_path = path
        self._resolved_codelens = List[TextEditEntry]()
        self._has_resolved_codelens = False
        self._inflight_codelens_resolve_id = String("")
        self._codelens_resolve_queue = List[JsonValue]()
        self._codelens_accum = List[TextEditEntry]()
        return True

    def server_supports_codelens_resolve(self) -> Bool:
        """True iff ``codeLensProvider.resolveProvider`` — lenses arrive
        without a ``command`` and need a ``codeLens/resolve`` to fill the
        title."""
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var cl_opt = caps.object_get(String("codeLensProvider"))
        if not cl_opt or not cl_opt.value().is_object():
            return False
        var rp_opt = cl_opt.value().copy().object_get(String("resolveProvider"))
        if rp_opt and rp_opt.value().is_bool():
            return rp_opt.value().as_bool()
        return False

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
            self._inflight_codelens_resolve_id = self.client.send_request(
                String("codeLens/resolve"), lens,
            )
        except:
            self._inflight_codelens_resolve_id = String("")

    def has_pending_codelens(self) -> Bool:
        return self._has_resolved_codelens

    def pending_codelens_path(self) -> String:
        return self._codelens_path

    def take_codelens(mut self) -> List[TextEditEntry]:
        var out = self._resolved_codelens^
        self._resolved_codelens = List[TextEditEntry]()
        self._has_resolved_codelens = False
        return out^

    # --- document links ---------------------------------------------------

    def request_document_links(mut self, path: String, var text: String) -> Bool:
        """Send ``textDocument/documentLink`` for the whole file. Parks
        range carriers (``new_text`` = target uri) for links the server
        returned with an inline target."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        try:
            self._inflight_doclink_id = self.client.send_request(
                String("textDocument/documentLink"), params,
            )
        except:
            self._inflight_doclink_id = String("")
            return False
        self._doclink_path = path
        self._resolved_doclinks = List[TextEditEntry]()
        self._has_resolved_doclinks = False
        return True

    def has_pending_doclinks(self) -> Bool:
        return self._has_resolved_doclinks

    def pending_doclink_path(self) -> String:
        return self._doclink_path

    def take_doclinks(mut self) -> List[TextEditEntry]:
        var out = self._resolved_doclinks^
        self._resolved_doclinks = List[TextEditEntry]()
        self._has_resolved_doclinks = False
        return out^

    # --- semantic tokens --------------------------------------------------

    def request_semantic_tokens(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Request semantic tokens for the whole file. When we have a
        cached ``resultId`` for this same path and the server supports
        delta, send ``semanticTokens/full/delta`` (the response is a small
        edit set spliced into the cached token array); otherwise send the
        full ``semanticTokens/full``. Either way the decoded recolor
        ``Highlight``s are parked for the editor."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        var use_delta = self._sem_data_path == path \
            and len(self._sem_result_id.as_bytes()) > 0 \
            and self.server_supports_semantic_delta()
        var method = String("textDocument/semanticTokens/full")
        if use_delta:
            method = String("textDocument/semanticTokens/full/delta")
            params.put(
                String("previousResultId"), json_str(self._sem_result_id),
            )
        else:
            # New file (or no prior result): drop any stale cache so a
            # delta-shaped response can't splice against the wrong array.
            self._sem_result_id = String("")
            self._sem_data = List[Int]()
        try:
            self._inflight_semantic_id = self.client.send_request(method, params)
        except:
            self._inflight_semantic_id = String("")
            return False
        self._semantic_path = path
        self._sem_data_path = path
        self._resolved_semantic = List[Highlight]()
        self._has_resolved_semantic = False
        return True

    def server_supports_semantic_delta(self) -> Bool:
        """True iff ``semanticTokensProvider.full.delta`` — the server can
        return token deltas keyed off a previous ``resultId``."""
        if not self._capabilities:
            return False
        var caps = self._capabilities.value().copy()
        if not caps.is_object():
            return False
        var sp_opt = caps.object_get(String("semanticTokensProvider"))
        if not sp_opt or not sp_opt.value().is_object():
            return False
        var full_opt = sp_opt.value().copy().object_get(String("full"))
        if not full_opt or not full_opt.value().is_object():
            return False
        var d_opt = full_opt.value().copy().object_get(String("delta"))
        if d_opt and d_opt.value().is_bool():
            return d_opt.value().as_bool()
        return False

    def has_pending_semantic(self) -> Bool:
        return self._has_resolved_semantic

    def pending_semantic_path(self) -> String:
        return self._semantic_path

    def take_semantic(mut self) -> List[Highlight]:
        var out = self._resolved_semantic^
        self._resolved_semantic = List[Highlight]()
        self._has_resolved_semantic = False
        return out^

    # --- selection range --------------------------------------------------

    def request_selection_range(
        mut self, path: String, line: Int, character: Int, var text: String,
    ) -> Bool:
        """Send ``textDocument/selectionRange`` for one position. Parks the
        flattened range hierarchy (innermost→outermost)."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        var positions = json_array()
        positions.append(_lsp_position(line, character))
        params.put(String("positions"), positions^)
        try:
            self._inflight_selrange_id = self.client.send_request(
                String("textDocument/selectionRange"), params,
            )
        except:
            self._inflight_selrange_id = String("")
            return False
        self._selrange_path = path
        self._resolved_selrange = List[TextEditEntry]()
        self._has_resolved_selrange = False
        return True

    def has_pending_selrange(self) -> Bool:
        return self._has_resolved_selrange

    def pending_selrange_path(self) -> String:
        return self._selrange_path

    def take_selrange(mut self) -> List[TextEditEntry]:
        var out = self._resolved_selrange^
        self._resolved_selrange = List[TextEditEntry]()
        self._has_resolved_selrange = False
        return out^

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
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = _text_document_position_params(path, line, character)
        try:
            self._inflight_hier_prepare_id = self.client.send_request(
                prepare_method, params,
            )
        except:
            self._inflight_hier_prepare_id = String("")
            return False
        self._hierarchy_followup = followup_method
        self._hierarchy_word = word^
        self._inflight_hier_followup_id = String("")
        self._resolved_hierarchy = List[DefinitionResolved]()
        self._has_resolved_hierarchy = False
        return True

    def has_pending_hierarchy(self) -> Bool:
        return self._has_resolved_hierarchy

    def hierarchy_word(self) -> String:
        return self._hierarchy_word

    def take_hierarchy(mut self) -> List[DefinitionResolved]:
        var out = self._resolved_hierarchy^
        self._resolved_hierarchy = List[DefinitionResolved]()
        self._has_resolved_hierarchy = False
        return out^

    # --- document color ---------------------------------------------------

    def request_document_colors(
        mut self, path: String, var text: String,
    ) -> Bool:
        """Send ``textDocument/documentColor``. Parks swatch highlights."""
        if self.state != _STATE_READY:
            return False
        self._send_open_or_change(path, text^)
        var params = json_object()
        params.put(String("textDocument"), _text_document(path))
        try:
            self._inflight_color_id = self.client.send_request(
                String("textDocument/documentColor"), params,
            )
        except:
            self._inflight_color_id = String("")
            return False
        self._color_path = path
        self._resolved_colors = List[Highlight]()
        self._has_resolved_colors = False
        return True

    def has_pending_colors(self) -> Bool:
        return self._has_resolved_colors

    def pending_color_path(self) -> String:
        return self._color_path

    def take_colors(mut self) -> List[Highlight]:
        var out = self._resolved_colors^
        self._resolved_colors = List[Highlight]()
        self._has_resolved_colors = False
        return out^

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
                maybe = self.client.poll(Int32(0))
            except:
                return resolved
            if not maybe:
                return resolved
            var msg = maybe.value().copy()
            if msg.kind == LSP_NOTIFICATION:
                if msg.method and msg.params:
                    var method = msg.method.value()
                    if method == String("textDocument/publishDiagnostics"):
                        self._on_publish_diagnostics(msg.params.value())
                    elif method == String("$/progress"):
                        self._on_progress(msg.params.value())
                    elif method == String("window/showMessage"):
                        self._on_show_message(msg.params.value())
                    elif method == String("window/logMessage"):
                        self._on_log_message(msg.params.value())
                    elif method == String("telemetry/event"):
                        self._append_log(
                            String("[telemetry] ")
                            + encode_json(msg.params.value()),
                        )
                continue
            if msg.kind == LSP_REQUEST:
                self._handle_server_request(msg)
                continue
            if msg.kind != LSP_RESPONSE:
                continue
            if not msg.id:
                continue
            var id = _id_to_string(msg.id.value())
            if len(id.as_bytes()) == 0:
                continue
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
            if id == self._inflight_ref_id:
                var refs = List[DefinitionResolved]()
                if msg.result:
                    refs = _parse_references_result(msg.result.value())
                _lsp_debug_log(
                    String("← references response id=") + id
                    + String(" lang=") + self._language_id
                    + String(" count=") + String(len(refs)),
                )
                self._resolved_references = refs^
                self._has_resolved_references = True
                self._inflight_ref_id = String("")
                continue
            if id == self._inflight_symbol_id:
                var items = List[SymbolItem]()
                if msg.result:
                    items = _parse_symbols_result(msg.result.value())
                self._resolved_symbols = items^
                self._has_resolved_symbols = True
                self._symbols_empty = (len(self._resolved_symbols) == 0)
                self._inflight_symbol_id = String("")
                continue
            if id == self._inflight_ws_symbol_id:
                var ws_items = List[WorkspaceSymbolItem]()
                if msg.result:
                    ws_items = _parse_workspace_symbols_result(
                        msg.result.value(),
                    )
                self._resolved_ws_symbols = ws_items^
                self._has_resolved_ws_symbols = True
                self._inflight_ws_symbol_id = String("")
                continue
            if id == self._inflight_completion_id:
                var comps = List[CompletionItem]()
                if msg.result:
                    comps = _parse_completion_result(msg.result.value())
                _lsp_debug_log(
                    String("← completion response id=") + id
                    + String(" lang=") + self._language_id
                    + String(" count=") + String(len(comps)),
                )
                self._resolved_completions = comps^
                self._has_resolved_completions = True
                self._inflight_completion_id = String("")
                continue
            if id == self._inflight_resolve_id:
                var r_aux = List[TextEditEntry]()
                var r_detail = String("")
                if msg.result and msg.result.value().is_object():
                    r_aux = _parse_additional_text_edits(msg.result.value())
                    var d_opt = msg.result.value().object_get(String("detail"))
                    if d_opt and d_opt.value().is_string():
                        r_detail = d_opt.value().as_str()
                _lsp_debug_log(
                    String("← resolve response id=") + id
                    + String(" lang=") + self._language_id
                    + String(" aux=") + String(len(r_aux)),
                )
                self._resolve_aux = r_aux^
                self._resolve_detail = r_detail^
                self._has_resolve_result = True
                self._inflight_resolve_id = String("")
                continue
            if id == self._inflight_hover_id:
                var hover_text = String("")
                if msg.result:
                    hover_text = _parse_hover_result(msg.result.value())
                _lsp_debug_log(
                    String("← hover response id=") + id
                    + String(" lang=") + self._language_id
                    + String(" len=") + String(len(hover_text.as_bytes())),
                )
                self._resolved_hover = hover_text^
                self._has_resolved_hover = True
                self._inflight_hover_id = String("")
                continue
            if id == self._inflight_code_action_id:
                var actions = List[CodeAction]()
                if msg.result:
                    actions = _parse_code_action_result(msg.result.value())
                _lsp_debug_log(
                    String("← codeAction response id=") + id
                    + String(" lang=") + self._language_id
                    + String(" count=") + String(len(actions)),
                )
                self._resolved_code_actions = actions^
                self._has_resolved_code_actions = True
                self._inflight_code_action_id = String("")
                continue
            if id == self._inflight_rename_id:
                var rename_edits = List[CodeActionFileEdit]()
                if msg.result and msg.result.value().is_object():
                    rename_edits = _parse_workspace_edit_changes(
                        msg.result.value(),
                    )
                _lsp_debug_log(
                    String("← rename response id=") + id
                    + String(" lang=") + self._language_id
                    + String(" files=") + String(len(rename_edits)),
                )
                self._resolved_rename_edits = rename_edits^
                self._has_resolved_rename = True
                self._inflight_rename_id = String("")
                continue
            if id == self._inflight_nav_id:
                var nav = Optional[DefinitionResolved]()
                if msg.result:
                    nav = _parse_definition_result(msg.result.value())
                var nav_found = String("no")
                if nav:
                    nav_found = String("yes")
                _lsp_debug_log(
                    String("← navigation response id=") + id
                    + String(" found=") + nav_found,
                )
                self._resolved_nav = nav
                self._has_resolved_nav = True
                self._inflight_nav_id = String("")
                continue
            if id == self._inflight_prepare_rename_id:
                # Success with a range/placeholder → renameable (1);
                # success with null → not renameable (2); an error
                # response (method unsupported) → fall back (0).
                var st = 0
                var ph = String("")
                if msg.result:
                    var rv = msg.result.value().copy()
                    if rv.is_null():
                        st = 2
                    elif rv.is_object():
                        st = 1
                        ph = _parse_prepare_rename_placeholder(rv)
                self._prepare_rename_state = st
                self._prepare_rename_placeholder = ph^
                self._has_resolved_prepare_rename = True
                self._inflight_prepare_rename_id = String("")
                continue
            if id == self._inflight_formatting_id:
                var fmt_edits = List[TextEditEntry]()
                if msg.result:
                    fmt_edits = _parse_text_edits(msg.result.value())
                _lsp_debug_log(
                    String("← formatting response id=") + id
                    + String(" edits=") + String(len(fmt_edits)),
                )
                self._resolved_formatting_edits = fmt_edits^
                self._has_resolved_formatting = True
                self._inflight_formatting_id = String("")
                continue
            if id == self._inflight_ontype_id:
                var ot_edits = List[TextEditEntry]()
                if msg.result:
                    ot_edits = _parse_text_edits(msg.result.value())
                self._resolved_ontype_edits = ot_edits^
                self._has_resolved_ontype = True
                self._inflight_ontype_id = String("")
                continue
            if id == self._inflight_moniker_id:
                var mnote = String("")
                if msg.result:
                    mnote = _parse_monikers(msg.result.value())
                self._moniker_note = mnote^
                self._has_moniker = True
                self._inflight_moniker_id = String("")
                continue
            if id == self._inflight_colorpres_id:
                var cp_labels = List[String]()
                var cp_edits = List[TextEditEntry]()
                if msg.result and msg.result.value().is_array():
                    var arr = msg.result.value().copy()
                    for k in range(arr.array_len()):
                        var e = arr.array_at(k)
                        if not e.is_object():
                            continue
                        var lab_opt = e.object_get(String("label"))
                        if not lab_opt or not lab_opt.value().is_string():
                            continue
                        var label = lab_opt.value().as_str()
                        cp_labels.append(label)
                        # Rewrite the color literal's range with the chosen
                        # form. (We use the label as the new text — for color
                        # literals the server's textEdit range matches the
                        # requested span and its text is the label.)
                        cp_edits.append(TextEditEntry(
                            self._colorpres_sl, self._colorpres_sc,
                            self._colorpres_el, self._colorpres_ec, label,
                        ))
                self._colorpres_labels = cp_labels^
                self._colorpres_edits = cp_edits^
                self._has_colorpres = True
                self._inflight_colorpres_id = String("")
                continue
            if id == self._inflight_inlinecomp_id:
                var ic = String("")
                if msg.result:
                    ic = _parse_inline_completion(msg.result.value())
                self._inlinecomp_text = ic^
                self._has_inlinecomp = True
                self._inflight_inlinecomp_id = String("")
                continue
            if id == self._inflight_linked_id:
                var lr = List[TextEditEntry]()
                if msg.result:
                    lr = _parse_linked_ranges(msg.result.value())
                self._linked_ranges = lr^
                self._has_linked = True
                self._inflight_linked_id = String("")
                continue
            if id == self._inflight_inlineval_id:
                var iv = List[TextEditEntry]()
                var ive = List[TextEditEntry]()
                if msg.result:
                    iv = _parse_inline_values(msg.result.value())
                    ive = _parse_inline_value_exprs(msg.result.value())
                self._inlinevals = iv^
                self._inlineval_exprs = ive^
                self._has_inlinevals = True
                self._inflight_inlineval_id = String("")
                continue
            if id == self._inflight_folding_id:
                var fr = List[TextEditEntry]()
                if msg.result:
                    fr = _parse_folding_ranges(msg.result.value())
                self._folding_ranges = fr^
                self._has_folding = True
                self._inflight_folding_id = String("")
                continue
            if id == self._inflight_doc_highlight_id:
                var occ = List[TextEditEntry]()
                if msg.result:
                    occ = _parse_document_highlights(msg.result.value())
                self._resolved_doc_highlights = occ^
                self._has_resolved_doc_highlight = True
                self._inflight_doc_highlight_id = String("")
                continue
            if id == self._inflight_signature_id:
                var sig = String("")
                if msg.result:
                    sig = _parse_signature_help(msg.result.value())
                self._resolved_signature = sig^
                self._has_resolved_signature = True
                self._inflight_signature_id = String("")
                continue
            if id == self._inflight_inlay_id:
                var ih = List[TextEditEntry]()
                if msg.result:
                    ih = _parse_inlay_hints(msg.result.value())
                self._resolved_inlay = ih^
                self._has_resolved_inlay = True
                self._inflight_inlay_id = String("")
                continue
            if id == self._inflight_codelens_id:
                self._codelens_accum = List[TextEditEntry]()
                self._codelens_resolve_queue = List[JsonValue]()
                if msg.result:
                    self._codelens_accum = _parse_code_lens(msg.result.value())
                    if self.server_supports_codelens_resolve():
                        self._codelens_resolve_queue = \
                            _collect_unresolved_lenses(msg.result.value())
                self._resolved_codelens = self._codelens_accum.copy()
                self._has_resolved_codelens = True
                self._inflight_codelens_id = String("")
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
                        self._resolved_codelens = self._codelens_accum.copy()
                        self._has_resolved_codelens = True
                # Chain the next queued lens, if any.
                self._send_next_codelens_resolve()
                continue
            if id == self._inflight_doclink_id:
                var dls = List[TextEditEntry]()
                if msg.result:
                    dls = _parse_document_links(msg.result.value())
                self._resolved_doclinks = dls^
                self._has_resolved_doclinks = True
                self._inflight_doclink_id = String("")
                continue
            if id == self._inflight_semantic_id:
                if msg.result and msg.result.value().is_object():
                    var r = msg.result.value().copy()
                    var edits_opt = r.object_get(String("edits"))
                    if edits_opt and edits_opt.value().is_array():
                        # Delta: splice the edits into the cached array.
                        self._sem_data = _apply_semantic_edits(
                            self._sem_data, edits_opt.value(),
                        )
                    else:
                        # Full: the response carries the whole token array.
                        self._sem_data = _semantic_data_ints(r)
                    var rid_opt = r.object_get(String("resultId"))
                    if rid_opt and rid_opt.value().is_string():
                        self._sem_result_id = rid_opt.value().as_str()
                    else:
                        self._sem_result_id = String("")
                    self._resolved_semantic = _decode_semantic_data(
                        self._sem_data, self._sem_token_types,
                    )
                else:
                    self._resolved_semantic = List[Highlight]()
                self._has_resolved_semantic = True
                self._inflight_semantic_id = String("")
                continue
            if id == self._inflight_selrange_id:
                var sr = List[TextEditEntry]()
                if msg.result:
                    sr = _parse_selection_ranges(msg.result.value())
                self._resolved_selrange = sr^
                self._has_resolved_selrange = True
                self._inflight_selrange_id = String("")
                continue
            if id == self._inflight_hier_prepare_id:
                # Prepare done → fire the follow-up (incomingCalls /
                # supertypes) with the first prepared item echoed back.
                self._inflight_hier_prepare_id = String("")
                var item0 = Optional[JsonValue]()
                if msg.result and msg.result.value().is_array() \
                        and msg.result.value().array_len() > 0:
                    item0 = Optional[JsonValue](
                        msg.result.value().array_at(0),
                    )
                if item0:
                    var fp = json_object()
                    fp.put(String("item"), item0.value().copy())
                    try:
                        self._inflight_hier_followup_id = \
                            self.client.send_request(
                                self._hierarchy_followup, fp,
                            )
                    except:
                        self._inflight_hier_followup_id = String("")
                        self._resolved_hierarchy = List[DefinitionResolved]()
                        self._has_resolved_hierarchy = True
                else:
                    # No symbol here → empty result so the host can notice.
                    self._resolved_hierarchy = List[DefinitionResolved]()
                    self._has_resolved_hierarchy = True
                continue
            if id == self._inflight_hier_followup_id:
                var hits = List[DefinitionResolved]()
                if msg.result:
                    hits = _parse_hierarchy_result(msg.result.value())
                self._resolved_hierarchy = hits^
                self._has_resolved_hierarchy = True
                self._inflight_hier_followup_id = String("")
                continue
            if id == self._inflight_color_id:
                var cols = List[Highlight]()
                if msg.result:
                    cols = _parse_document_colors(msg.result.value())
                self._resolved_colors = cols^
                self._has_resolved_colors = True
                self._inflight_color_id = String("")
                continue
            if id == self._inflight_pull_diag_id:
                # Pull-diagnostics report. A "full" report (or any object
                # carrying ``items``) replaces the bucket — an empty
                # ``items`` array is a valid "all clear". An "unchanged"
                # report means reuse what we have, so leave the bucket be.
                var ppath = self._pull_diag_path
                self._inflight_pull_diag_id = String("")
                if msg.result and msg.result.value().is_object():
                    var rep = msg.result.value().copy()
                    var kind = String("")
                    var kind_opt = rep.object_get(String("kind"))
                    if kind_opt and kind_opt.value().is_string():
                        kind = kind_opt.value().as_str()
                    if kind != String("unchanged"):
                        var items_opt = rep.object_get(String("items"))
                        var pdiags = List[Diagnostic]()
                        if items_opt and items_opt.value().is_array():
                            pdiags = _parse_diagnostics_array(items_opt.value())
                        _lsp_debug_log(
                            String("← pull diagnostic response id=") + id
                            + String(" path=") + ppath
                            + String(" count=") + String(len(pdiags)),
                        )
                        self._store_diagnostics(ppath, pdiags^)
                self._clear_diag_inflight(ppath, 0)
                continue
            if id == self._inflight_willsave_id:
                var wse = List[TextEditEntry]()
                if msg.result:
                    wse = _parse_text_edits(msg.result.value())
                _lsp_debug_log(
                    String("← willSaveWaitUntil response id=") + id
                    + String(" edits=") + String(len(wse)),
                )
                self._resolved_willsave_edits = wse^
                self._has_resolved_willsave = True
                self._inflight_willsave_id = String("")
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
        sphinx.put(String("pythonCommand"), python_arr^)
        var build_arr = json_array()
        build_arr.append(json_str(String("sphinx-build")))
        build_arr.append(json_str(String("-M")))
        build_arr.append(json_str(String("dirhtml")))
        build_arr.append(json_str(src_dir))
        # Output dir under /tmp so we don't pollute the project tree
        # with build artefacts. esbonio uses this for diagnostics, not
        # for actually serving HTML.
        var out_dir = String("/tmp/turbokod-esbonio-")
        out_dir = out_dir + basename(src_dir) + String("-build")
        build_arr.append(json_str(out_dir))
        sphinx.put(String("buildCommand"), build_arr^)
        var cfg = json_object()
        cfg.put(String("sphinx"), sphinx^)
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
        var pub_version = 0  # 0 ⇒ server didn't echo a version
        var version_opt = params.object_get(String("version"))
        if version_opt and version_opt.value().is_int():
            pub_version = version_opt.value().as_int()
            for k in range(len(self._doc_paths)):
                if self._doc_paths[k] == path:
                    if pub_version < self._doc_versions[k]:
                        _lsp_debug_log(
                            String("← publishDiagnostics (dropped stale) lang=")
                            + self._language_id
                            + String(" path=") + path
                            + String(" pub_version=") + String(pub_version)
                            + String(" latest_version=")
                            + String(self._doc_versions[k]),
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
        var diags = _parse_diagnostics_array(diags_opt.value())
        _lsp_debug_log(
            String("← publishDiagnostics lang=") + self._language_id
            + String(" path=") + path
            + String(" count=") + String(len(diags)),
        )
        self._store_diagnostics(path, diags^)

    def _store_diagnostics(mut self, path: String, var diags: List[Diagnostic]):
        """Replace (not merge) the diagnostic bucket for ``path`` and mark
        it unconsumed so the host re-applies on the next frame. Shared by
        the push (``publishDiagnostics``) and pull (``textDocument/
        diagnostic``) paths."""
        for k in range(len(self._diagnostic_buckets)):
            if self._diagnostic_buckets[k].path == path:
                self._diagnostic_buckets[k].diags = diags^
                self._diagnostic_buckets[k].consumed = False
                return
        self._diagnostic_buckets.append(
            _DiagnosticBucket(path, diags^, False),
        )

    def _on_progress(mut self, params: JsonValue):
        """Parse a ``$/progress`` notification's ``value`` (a WorkDone
        progress payload). ``begin`` / ``report`` build a one-line note
        (``title — message (pct%)``); ``end`` clears it. Non-WorkDone
        progress (partial results) is ignored."""
        if not params.is_object():
            return
        var val_opt = params.object_get(String("value"))
        if not val_opt or not val_opt.value().is_object():
            return
        var val = val_opt.value().copy()
        var kind_opt = val.object_get(String("kind"))
        var kind = String("")
        if kind_opt and kind_opt.value().is_string():
            kind = kind_opt.value().as_str()
        if kind == String("end"):
            self._progress_note = String("")
            self._has_progress_note = True
            return
        if kind != String("begin") and kind != String("report"):
            return
        var note = self._language_id
        var title_opt = val.object_get(String("title"))
        if title_opt and title_opt.value().is_string() \
                and len(title_opt.value().as_str().as_bytes()) > 0:
            note = note + String(": ") + title_opt.value().as_str()
        var msg_opt = val.object_get(String("message"))
        if msg_opt and msg_opt.value().is_string() \
                and len(msg_opt.value().as_str().as_bytes()) > 0:
            note = note + String(" — ") + msg_opt.value().as_str()
        var pct_opt = val.object_get(String("percentage"))
        if pct_opt and pct_opt.value().is_int():
            note = note + String(" (") + String(pct_opt.value().as_int()) \
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

    def _on_log_message(mut self, params: JsonValue):
        """Append a ``window/logMessage`` to the rolling log capture,
        prefixed by severity (E/W/I/L for error/warning/info/log). Unlike
        ``showMessage`` this is log-stream output, not a user toast — it
        lives in the LSP info window, not the status bar."""
        if not params.is_object():
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
        capture; once full, new lines are dropped (the head is usually the
        most useful)."""
        comptime CAP: Int = 16 * 1024
        var have = len(self._log_capture.as_bytes())
        if have >= CAP:
            return
        self._log_capture = self._log_capture + line + String("\n")

    def captured_log(self) -> String:
        """The server's protocol-level log (``window/logMessage`` +
        ``telemetry/event``) captured since spawn, capped at 16 KB."""
        return self._log_capture

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
        var result = json_null_v()
        if 0 <= action_index and action_index < len(self._msgreq_actions):
            var item = json_object()
            item.put(
                String("title"),
                json_str(self._msgreq_actions[action_index]),
            )
            result = item^
        try:
            self.client.send_response(id, result^)
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

    def _capture_semantic_legend(mut self, provider: JsonValue):
        """Pull ``legend.tokenTypes`` out of a ``semanticTokensProvider``
        object (from the initialize capabilities *or* a dynamic
        ``client/registerCapability``) into ``_sem_token_types``, indexed
        by each decoded token's ``tokenType`` field. Shared so both the
        static and the dynamic-registration paths build the same legend —
        rust-analyzer ships its legend only on the dynamic registration."""
        if not provider.is_object():
            return
        var legend_opt = provider.object_get(String("legend"))
        if not legend_opt or not legend_opt.value().is_object():
            return
        var tt_opt = legend_opt.value().object_get(String("tokenTypes"))
        if not tt_opt or not tt_opt.value().is_array():
            return
        var tt = tt_opt.value().copy()
        var types = List[String]()
        for ti in range(tt.array_len()):
            var tv = tt.array_at(ti)
            if tv.is_string():
                types.append(tv.as_str())
            else:
                types.append(String(""))
        self._sem_token_types = types^

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
        if method == String("textDocument/semanticTokens") \
                and options.is_object():
            self._capture_semantic_legend(options)

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
        var id_label = _id_to_string(id)
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
                            var sec = item.object_get(String("section"))
                            if sec and sec.value().is_string():
                                section = sec.value().as_str()
                        if section == String("esbonio"):
                            var cfg_opt = self._esbonio_config()
                            if cfg_opt:
                                result.append(cfg_opt.value().copy())
                                continue
                        result.append(json_null_v())
                _lsp_debug_log(
                    String("← server request workspace/configuration id=")
                    + id_label + String(" items=") + String(n),
                )
                self.client.send_response(id, result^)
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
                                else json_null_v()
                            self._apply_capability_registration(
                                m_opt.value().as_str(), options,
                            )
                            merged += 1
                _lsp_debug_log(
                    String("← server request client/registerCapability id=")
                    + id_label + String(" merged=") + String(merged),
                )
                self.client.send_response(id, json_null_v())
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
                _lsp_debug_log(
                    String("← server request client/unregisterCapability id=")
                    + id_label + String(" (removed)"),
                )
                self.client.send_response(id, json_null_v())
                return
            if method == String("window/workDoneProgress/create"):
                # Acknowledge with success. We don't track the progress
                # token itself, but accepting lets the server proceed
                # instead of stalling on the probe.
                _lsp_debug_log(
                    String("← server request ") + method
                    + String(" id=") + id_label + String(" (acked)"),
                )
                self.client.send_response(id, json_null_v())
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
                _lsp_debug_log(
                    String("← server request workspace/applyEdit id=")
                    + id_label + String(" files=") + String(edit_count),
                )
                self.client.send_response(id, resp^)
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
                    var m_opt = p.object_get(String("message"))
                    if m_opt and m_opt.value().is_string():
                        rmsg = m_opt.value().as_str()
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
                    self.client.send_response(id, json_null_v())
                    return
                self._msgreq_id = Optional[JsonValue](id.copy())
                self._msgreq_message = rmsg^
                self._msgreq_actions = ractions^
                self._msgreq_pending = True
                _lsp_debug_log(
                    String("← server request window/showMessageRequest id=")
                    + id_label + String(" actions=")
                    + String(len(self._msgreq_actions)),
                )
                return
            if method == String("workspace/workspaceFolders"):
                # The server asks for the open workspace folders. Reply with
                # our single root (or an empty array if none — spec-legal).
                # Some servers (pyright) gate module resolution on this.
                var folders = json_array()
                if len(self._root_uri.as_bytes()) > 0:
                    var f = json_object()
                    f.put(String("uri"), json_str(self._root_uri))
                    f.put(
                        String("name"),
                        json_str(basename(_uri_to_path(self._root_uri))),
                    )
                    folders.append(f^)
                _lsp_debug_log(
                    String("← server request workspace/workspaceFolders id=")
                    + id_label,
                )
                self.client.send_response(id, folders^)
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
                    var u_opt = p.object_get(String("uri"))
                    if u_opt and u_opt.value().is_string():
                        uri = u_opt.value().as_str()
                    var ext_opt = p.object_get(String("external"))
                    if ext_opt and ext_opt.value().is_bool():
                        external = ext_opt.value().as_bool()
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
                _lsp_debug_log(
                    String("← server request window/showDocument id=")
                    + id_label + String(" external=") + String(external),
                )
                self.client.send_response(id, ok^)
                return
            # Unknown method: MethodNotFound (-32601) so the server
            # stops waiting.
            _lsp_debug_log(
                String("← server request ") + method
                + String(" id=") + id_label
                + String(" (MethodNotFound)"),
            )
            self.client.send_error(
                id, -32601,
                String("method not implemented by turbokod: ") + method,
            )
        except e:
            print("lsp: send_error (MethodNotFound) id=", id_label, ":", String(e))

    def _on_initialize_response(mut self, msg: LspIncoming):
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
                # Semantic-tokens legend: the token-type names, indexed by
                # the ``tokenType`` field of each decoded token.
                var stp_opt = caps_opt.value().object_get(
                    String("semanticTokensProvider"),
                )
                if stp_opt and stp_opt.value().is_object():
                    self._capture_semantic_legend(stp_opt.value())
        if self._position_encoding != String("utf-8"):
            _lsp_debug_log(
                String("position encoding negotiated as '")
                + self._position_encoding
                + String("' (not utf-8); multibyte columns may be off"),
            )
        # Drain the queue of opens that arrived before we were ready.
        var paths = self._pending_open_paths^
        var texts = self._pending_open_texts^
        self._pending_open_paths = List[String]()
        self._pending_open_texts = List[String]()
        for k in range(len(paths)):
            self._send_open_or_change(paths[k], texts[k])

    def _send_open_or_change(mut self, path: String, var text: String):
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
        _lsp_debug_log(
            String("→ didOpen lang=") + self._language_id
            + String(" path=") + path
            + String(" uri=") + _path_to_uri(path)
            + String(" text_len=") + String(len(text.as_bytes())),
        )
        var params = json_object()
        var doc = _text_document(path)
        doc.put(String("languageId"), json_str(self._language_id))
        doc.put(String("version"), json_int(1))
        doc.put(String("text"), json_str(text^))
        params.put(String("textDocument"), doc)
        try:
            self.client.send_notification(
                String("textDocument/didOpen"), params,
            )
        except e:
            print("lsp: didOpen", path, ":", String(e))
        self._mark_diag_inflight(path, 1)

    def _send_did_change(mut self, path: String, version: Int, var text: String):
        _lsp_debug_log(
            String("→ didChange lang=") + self._language_id
            + String(" path=") + path
            + String(" uri=") + _path_to_uri(path)
            + String(" version=") + String(version)
            + String(" text_len=") + String(len(text.as_bytes())),
        )
        var params = json_object()
        var doc = _text_document(path)
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
        except e:
            print("lsp: didChange", path, "v=", version, ":", String(e))
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
    if method == String("textDocument/semanticTokens"):
        return String("semanticTokensProvider")
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


def _id_to_string(v: JsonValue) -> String:
    """Canonicalize a JSON-RPC id (``integer | string``) to a String so
    callers can compare against ``_inflight_*_id`` (always String).

    Our own outgoing requests already stringify their ids in
    ``LspClient.send_request``, so any response paired with a request
    we issued comes back as a string the server echoed verbatim. But a
    server free to interpret-and-rewrite would still be spec-compliant
    re-emitting the same digits as a JSON integer — so we accept both
    shapes. Returns ``""`` for ids of any other JSON type (null,
    object, array — none are legal, but better to skip than crash).
    """
    if v.is_string():
        return v.as_str()
    if v.is_int():
        return String(v.as_int())
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
        return _parse_one_definition(v.array_at(0))
    if v.is_object():
        return _parse_one_definition(v)
    return Optional[DefinitionResolved]()


def _parse_one_definition(v: JsonValue) -> Optional[DefinitionResolved]:
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
    var rng = range_opt.value().copy()
    var start_opt = rng.object_get(String("start"))
    if not start_opt:
        return Optional[DefinitionResolved]()
    var start = start_opt.value().copy()
    var line_opt = start.object_get(String("line"))
    var char_opt = start.object_get(String("character"))
    if not line_opt or not char_opt:
        return Optional[DefinitionResolved]()
    if not line_opt.value().is_int() or not char_opt.value().is_int():
        return Optional[DefinitionResolved]()
    return Optional[DefinitionResolved](DefinitionResolved(
        path, line_opt.value().as_int(), char_opt.value().as_int(),
    ))


def _parse_references_result(v: JsonValue) -> List[DefinitionResolved]:
    """``textDocument/references`` returns ``Location[] | null``. Each
    entry has the same shape ``_parse_one_definition`` accepts (uri +
    range, no LocationLink variant in the spec), so we reuse that
    parser per element and skip malformed entries silently."""
    var out = List[DefinitionResolved]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var one = _parse_one_definition(v.array_at(i))
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
    var kind = 0
    var kind_opt = v.object_get(String("kind"))
    if kind_opt and kind_opt.value().is_int():
        kind = kind_opt.value().as_int()
    var container = String("")
    var cont_opt = v.object_get(String("containerName"))
    if cont_opt and cont_opt.value().is_string():
        container = cont_opt.value().as_str()
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
    var aux_edits = List[TextEditEntry]()
    var aux_opt = entry.object_get(String("additionalTextEdits"))
    if aux_opt and aux_opt.value().is_array():
        var aux_arr = aux_opt.value().copy()
        var aux_n = aux_arr.array_len()
        for j in range(aux_n):
            var aux = aux_arr.array_at(j)
            if not aux.is_object():
                continue
            var nt_opt = aux.object_get(String("newText"))
            if not nt_opt or not nt_opt.value().is_string():
                continue
            var aux_new_text = nt_opt.value().as_str()
            var aux_rng_opt = aux.object_get(String("range"))
            if not aux_rng_opt or not aux_rng_opt.value().is_object():
                continue
            var aux_rng = aux_rng_opt.value().copy()
            var as_opt = aux_rng.object_get(String("start"))
            var ae_opt = aux_rng.object_get(String("end"))
            if not as_opt or not ae_opt \
                    or not as_opt.value().is_object() \
                    or not ae_opt.value().is_object():
                continue
            var asl_opt = as_opt.value().object_get(String("line"))
            var asc_opt = as_opt.value().object_get(String("character"))
            var ael_opt = ae_opt.value().object_get(String("line"))
            var aec_opt = ae_opt.value().object_get(String("character"))
            if not asl_opt or not asc_opt or not ael_opt or not aec_opt \
                    or not asl_opt.value().is_int() \
                    or not asc_opt.value().is_int() \
                    or not ael_opt.value().is_int() \
                    or not aec_opt.value().is_int():
                continue
            aux_edits.append(TextEditEntry(
                asl_opt.value().as_int(),
                asc_opt.value().as_int(),
                ael_opt.value().as_int(),
                aec_opt.value().as_int(),
                aux_new_text,
            ))
    return aux_edits^


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
    var arr: JsonValue
    if v.is_array():
        arr = v.copy()
    elif v.is_object():
        var items_opt = v.object_get(String("items"))
        if not items_opt or not items_opt.value().is_array():
            return out^
        arr = items_opt.value().copy()
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
                var te = te_opt.value().copy()
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
                    var rng_obj = rng_obj_opt.value().copy()
                    var s_opt = rng_obj.object_get(String("start"))
                    var e_opt = rng_obj.object_get(String("end"))
                    if Bool(s_opt) and Bool(e_opt) \
                            and s_opt.value().is_object() \
                            and e_opt.value().is_object():
                        var sl_opt = s_opt.value().object_get(String("line"))
                        var sc_opt = s_opt.value().object_get(String("character"))
                        var el_opt = e_opt.value().object_get(String("line"))
                        var ec_opt = e_opt.value().object_get(String("character"))
                        if Bool(sl_opt) and Bool(sc_opt) and Bool(el_opt) and Bool(ec_opt) \
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
        var data_opt = entry.object_get(String("data"))
        if data_opt:
            data_raw = encode_json(data_opt.value())
        out.append(CompletionItem(
            label, insert_text, kind, detail, sort_text,
            has_range, rs_line, rs_char, re_line, re_char,
            aux_edits^, data_raw^,
        ))
    # Stable insertion sort by sort_text — typical completion lists are
    # under ~200 items so quadratic worst-case is fine here. Sort an index
    # array (cheap Int swaps) instead of the items, then reorder once so each
    # CompletionItem (with its additional_text_edits) is moved at most once.
    var m = len(out)
    var order = List[Int]()
    for i in range(m):
        order.append(i)
    for i in range(1, m):
        var j = i
        while j > 0 and out[order[j]].sort_text < out[order[j - 1]].sort_text:
            var tmp = order[j]
            order[j] = order[j - 1]
            order[j - 1] = tmp
            j -= 1
    var sorted = List[CompletionItem]()
    for i in range(m):
        sorted.append(out[order[i]].copy())
    return sorted^


def _parse_hover_result(v: JsonValue) -> String:
    """Extract a single human-readable string from a ``textDocument/hover``
    response. The response is ``{ contents: MarkupContent | MarkedString |
    MarkedString[] }`` where ``MarkupContent`` is ``{ kind, value }``,
    ``MarkedString`` is either a plain string or ``{ language, value }``,
    and the array form is a list of those. We accept all of them and
    return the joined ``value`` strings (newline-separated). Returns the
    empty string when the result has no usable text — the host treats
    that as 'nothing to show'."""
    if not v.is_object():
        return String("")
    var contents_opt = v.object_get(String("contents"))
    if not contents_opt:
        return String("")
    var contents = contents_opt.value().copy()
    return _hover_contents_to_string(contents)


def _hover_contents_to_string(v: JsonValue) -> String:
    """Recursive helper for ``_parse_hover_result``: walks the polymorphic
    ``contents`` shape and concatenates the text segments."""
    if v.is_string():
        return v.as_str()
    if v.is_object():
        # MarkupContent ({kind, value}) or MarkedString ({language, value}).
        var value_opt = v.object_get(String("value"))
        if value_opt and value_opt.value().is_string():
            return value_opt.value().as_str()
        return String("")
    if v.is_array():
        var parts = List[String]()
        for i in range(v.array_len()):
            var piece = _hover_contents_to_string(v.array_at(i))
            if len(piece.as_bytes()) > 0:
                parts.append(piece^)
        if len(parts) == 0:
            return String("")
        var out = parts[0]
        for i in range(1, len(parts)):
            out = out + String("\n") + parts[i]
        return out^
    return String("")


def _parse_code_action_result(v: JsonValue) -> List[CodeAction]:
    """Parse the result of ``textDocument/codeAction``.

    The result is ``(Command | CodeAction)[] | null``. ``Command``
    entries (no ``edit`` field — the action is opaquely server-side)
    are skipped: we have no way to apply them without a follow-up
    ``workspace/executeCommand`` round-trip we don't model yet.
    ``CodeAction`` literals are accepted; their ``edit.changes`` map
    is normalized into ``CodeActionFileEdit`` groups. ``documentChanges``
    (the LSP 3.13+ form that carries text-document versions and supports
    ``CreateFile`` / ``RenameFile`` / ``DeleteFile``) is not parsed yet —
    actions that only carry ``documentChanges`` come through with an
    empty ``file_edits`` list so the caller can detect and skip them.
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
        var kind_str = String("")
        var kind_opt = entry.object_get(String("kind"))
        if kind_opt and kind_opt.value().is_string():
            kind_str = kind_opt.value().as_str()
        var is_preferred = False
        var pref_opt = entry.object_get(String("isPreferred"))
        if pref_opt and pref_opt.value().is_bool():
            is_preferred = pref_opt.value().as_bool()
        var file_edits = List[CodeActionFileEdit]()
        var edit_opt = entry.object_get(String("edit"))
        if edit_opt and edit_opt.value().is_object():
            file_edits = _parse_workspace_edit_changes(edit_opt.value())
        # Extract a Command, if any. ``command`` is either a string (this
        # entry *is* a Command: title + command + arguments at top level)
        # or an object (a CodeAction literal with a nested Command).
        var cmd = String("")
        var cmd_args = Optional[JsonValue]()
        var cmd_opt = entry.object_get(String("command"))
        if cmd_opt and cmd_opt.value().is_string():
            cmd = cmd_opt.value().as_str()
            var a = entry.object_get(String("arguments"))
            if a and a.value().is_array():
                cmd_args = Optional[JsonValue](a.value().copy())
        elif cmd_opt and cmd_opt.value().is_object():
            var inner = cmd_opt.value().copy()
            var c2 = inner.object_get(String("command"))
            if c2 and c2.value().is_string():
                cmd = c2.value().as_str()
            var a2 = inner.object_get(String("arguments"))
            if a2 and a2.value().is_array():
                cmd_args = Optional[JsonValue](a2.value().copy())
        out.append(CodeAction(
            title, kind_str, is_preferred, file_edits^, cmd^, cmd_args^,
        ))
    return out^


def _parse_workspace_edit_changes(edit: JsonValue) -> List[CodeActionFileEdit]:
    """Normalize a LSP ``WorkspaceEdit``'s ``changes`` map into per-file
    ``CodeActionFileEdit`` groups.

    Shared by ``textDocument/codeAction`` (where the WorkspaceEdit sits
    under each action's ``edit`` field) and ``textDocument/rename`` (where
    the response *is* the WorkspaceEdit). Only the ``changes`` form is
    parsed; ``documentChanges`` (LSP 3.13+ versioned edits / file
    create/rename/delete) come through empty, so a rename that only emits
    ``documentChanges`` yields no file edits and the caller reports it as
    unsupported rather than silently doing nothing wrong."""
    var file_edits = List[CodeActionFileEdit]()
    if not edit.is_object():
        return file_edits^
    var changes_opt = edit.object_get(String("changes"))
    if not changes_opt or not changes_opt.value().is_object():
        return file_edits^
    var changes = changes_opt.value().copy()
    # ``changes`` is an object keyed by URI; the JsonValue exposes its
    # members through obj_v. We don't have a public iterator yet, but we
    # can walk obj_v directly since this module knows the internals.
    for k in range(len(changes.obj_v)):
        var uri = changes.obj_v[k].key
        var edits_val = changes.obj_v[k].value.copy()
        if not edits_val.is_array():
            continue
        var edits = List[TextEditEntry]()
        for j in range(edits_val.array_len()):
            var te = edits_val.array_at(j)
            if not te.is_object():
                continue
            var nt_opt = te.object_get(String("newText"))
            if not nt_opt or not nt_opt.value().is_string():
                continue
            var nt = nt_opt.value().as_str()
            var rng_opt = te.object_get(String("range"))
            if not rng_opt or not rng_opt.value().is_object():
                continue
            var rng = rng_opt.value().copy()
            var s_opt = rng.object_get(String("start"))
            var e_opt = rng.object_get(String("end"))
            if not s_opt or not e_opt \
                    or not s_opt.value().is_object() \
                    or not e_opt.value().is_object():
                continue
            var sl_opt = s_opt.value().object_get(String("line"))
            var sc_opt = s_opt.value().object_get(String("character"))
            var el_opt = e_opt.value().object_get(String("line"))
            var ec_opt = e_opt.value().object_get(String("character"))
            if not sl_opt or not sc_opt or not el_opt or not ec_opt \
                    or not sl_opt.value().is_int() \
                    or not sc_opt.value().is_int() \
                    or not el_opt.value().is_int() \
                    or not ec_opt.value().is_int():
                continue
            edits.append(TextEditEntry(
                sl_opt.value().as_int(),
                sc_opt.value().as_int(),
                el_opt.value().as_int(),
                ec_opt.value().as_int(),
                nt,
            ))
        if len(edits) > 0:
            file_edits.append(CodeActionFileEdit(uri, edits^))
    return file_edits^


def _parse_diagnostics_array(v: JsonValue) -> List[Diagnostic]:
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
        var rng = range_opt.value().copy()
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
        # ``code`` is required for code-action lookups (servers match
        # quickfix rules by code) — preserve whatever the server sent.
        # The spec allows either a string or an integer; we coerce to
        # string and echo back as-is.
        var code = String("")
        var code_opt = entry.object_get(String("code"))
        if code_opt:
            if code_opt.value().is_string():
                code = code_opt.value().as_str()
            elif code_opt.value().is_int():
                code = String(code_opt.value().as_int())
        out.append(Diagnostic(
            sl_opt.value().as_int(), sc_opt.value().as_int(),
            el_opt.value().as_int(), ec_opt.value().as_int(),
            severity, message^, source^, code^,
        ))
    return out^


def _start_pos_of(rng: JsonValue) -> Tuple[Int, Int]:
    """Extract ``(line, character)`` from a Range's ``start``. Returns
    ``(-1, -1)`` when the shape doesn't match — caller filters those out."""
    if not rng.is_object():
        return (-1, -1)
    var start_opt = rng.object_get(String("start"))
    if not start_opt:
        return (-1, -1)
    var start = start_opt.value().copy()
    var line_opt = start.object_get(String("line"))
    var char_opt = start.object_get(String("character"))
    if not line_opt or not char_opt:
        return (-1, -1)
    if not line_opt.value().is_int() or not char_opt.value().is_int():
        return (-1, -1)
    return (line_opt.value().as_int(), char_opt.value().as_int())


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


def _trim_trailing_newline(s: String) -> String:
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


def _text_document(path: String) -> JsonValue:
    """The ``{"uri": ...}`` TextDocumentIdentifier object for ``path``.
    Callers that need a richer TextDocumentItem (languageId / version) add
    those fields to the returned object."""
    var doc = json_object()
    doc.put(String("uri"), json_str(_path_to_uri(path)))
    return doc^


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


def _semantic_attr_for_type(t: String) -> Attr:
    """Map an LSP semantic token-type name to one of the editor's reserved
    ``SYN_*`` color roles (so the active theme controls the hue). Unknown
    types fall back to the default editor foreground."""
    if t == String("keyword") or t == String("modifier"):
        return Attr(SYN_KEYWORD, EDITOR_BG)
    if t == String("string"):
        return Attr(SYN_STRING, EDITOR_BG)
    if t == String("number"):
        return Attr(SYN_NUMBER, EDITOR_BG)
    if t == String("comment"):
        return Attr(SYN_COMMENT, EDITOR_BG)
    if t == String("operator"):
        return Attr(SYN_OPERATOR, EDITOR_BG)
    if t == String("decorator") or t == String("macro"):
        return Attr(SYN_DECORATOR, EDITOR_BG)
    # type-like and callable-like names share the identifier role (the
    # palette only reserves so many slots; this keeps semantic coloring
    # consistent with the TextMate scheme).
    if t == String("function") or t == String("method") \
            or t == String("type") or t == String("class") \
            or t == String("struct") or t == String("enum") \
            or t == String("interface") or t == String("namespace") \
            or t == String("typeParameter") or t == String("enumMember"):
        return Attr(SYN_IDENT, EDITOR_BG)
    return Attr(EDITOR_FG, EDITOR_BG)


def _decode_semantic_tokens(
    v: JsonValue, legend: List[String],
) -> List[Highlight]:
    """Decode a ``SemanticTokens`` result's delta-encoded ``data`` array
    into per-row ``Highlight``s. Each token is 5 integers
    ``(deltaLine, deltaStart, length, tokenType, tokenModifiers)`` relative
    to the previous token; the absolute row/start are accumulated. Tokens
    whose ``tokenType`` indexes outside the legend, or with zero length,
    are skipped. (Multi-line tokens are uncommon for the highlighted
    types; a token's span is treated as single-row, which is what the
    overlay paints.)"""
    if not v.is_object():
        return List[Highlight]()
    return _decode_semantic_data(_semantic_data_ints(v), legend)


def _semantic_data_ints(v: JsonValue) -> List[Int]:
    """Pull the flat integer ``data`` array out of a ``SemanticTokens``
    object (empty when absent / malformed)."""
    var out = List[Int]()
    if not v.is_object():
        return out^
    var data_opt = v.object_get(String("data"))
    if not data_opt or not data_opt.value().is_array():
        return out^
    var data = data_opt.value().copy()
    for i in range(data.array_len()):
        var e = data.array_at(i)
        out.append(e.as_int() if e.is_int() else 0)
    return out^


def _decode_semantic_data(data: List[Int], legend: List[String]) -> List[Highlight]:
    """Decode a flat ``(deltaLine, deltaStart, length, tokenType,
    tokenModifiers)`` token array (accumulated relative to the previous
    token) into per-row ``Highlight``s. Shared by the ``/full`` and the
    ``/full/delta`` paths (the latter reconstructs ``data`` first)."""
    var out = List[Highlight]()
    var n = len(data)
    var line = 0
    var start = 0
    var i = 0
    while i + 5 <= n:
        var d_line = data[i]
        var d_start = data[i + 1]
        var length = data[i + 2]
        var ttype = data[i + 3]
        if d_line == 0:
            start = start + d_start
        else:
            line = line + d_line
            start = d_start
        i += 5
        if length <= 0:
            continue
        if ttype < 0 or ttype >= len(legend):
            continue
        out.append(Highlight(
            line, start, start + length,
            _semantic_attr_for_type(legend[ttype]),
        ))
    return out^


def _apply_semantic_edits(data: List[Int], edits: JsonValue) -> List[Int]:
    """Apply a ``SemanticTokensDelta`` ``edits`` array to the previous flat
    token-int ``data`` and return the new array. Each edit is
    ``{start, deleteCount, data?}`` describing a splice of the *original*
    array; the spec guarantees edits are sorted ascending and
    non-overlapping, so a single forward pass — copy the gap, insert the
    replacement, skip the deleted run — rebuilds the result."""
    var out = List[Int]()
    if not edits.is_array():
        return data.copy()
    var pos = 0
    for i in range(edits.array_len()):
        var e = edits.array_at(i)
        if not e.is_object():
            continue
        var s_opt = e.object_get(String("start"))
        if not s_opt or not s_opt.value().is_int():
            continue
        var start = s_opt.value().as_int()
        var delc = 0
        var dc_opt = e.object_get(String("deleteCount"))
        if dc_opt and dc_opt.value().is_int():
            delc = dc_opt.value().as_int()
        var j = pos
        while j < start and j < len(data):
            out.append(data[j])
            j += 1
        var d_opt = e.object_get(String("data"))
        if d_opt and d_opt.value().is_array():
            var dd = d_opt.value().copy()
            for k in range(dd.array_len()):
                var ev = dd.array_at(k)
                out.append(ev.as_int() if ev.is_int() else 0)
        pos = start + delc
    var t = pos
    while t < len(data):
        out.append(data[t])
        t += 1
    return out^


def _parse_inlay_hints(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``InlayHint[] | null`` into (row, label) carriers. ``label``
    is either a string or an array of ``InlayHintLabelPart`` objects with
    a ``value`` field — both are flattened to one string."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var pos_opt = e.object_get(String("position"))
        if not pos_opt or not pos_opt.value().is_object():
            continue
        var ln = pos_opt.value().object_get(String("line"))
        if not ln or not ln.value().is_int():
            continue
        var row = ln.value().as_int()
        var label = String("")
        var lab_opt = e.object_get(String("label"))
        if lab_opt:
            var lab = lab_opt.value().copy()
            if lab.is_string():
                label = lab.as_str()
            elif lab.is_array():
                for k in range(lab.array_len()):
                    var part = lab.array_at(k)
                    if part.is_object():
                        var pv = part.object_get(String("value"))
                        if pv and pv.value().is_string():
                            label = label + pv.value().as_str()
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
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var rng_opt = e.object_get(String("range"))
        if not rng_opt or not rng_opt.value().is_object():
            continue
        var s_opt = rng_opt.value().object_get(String("start"))
        if not s_opt or not s_opt.value().is_object():
            continue
        var ln = s_opt.value().object_get(String("line"))
        if not ln or not ln.value().is_int():
            continue
        var row = ln.value().as_int()
        var cmd_opt = e.object_get(String("command"))
        if not cmd_opt or not cmd_opt.value().is_object():
            continue
        var title_opt = cmd_opt.value().object_get(String("title"))
        if not title_opt or not title_opt.value().is_string():
            continue
        var title = title_opt.value().as_str()
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
        var expr = String("")
        var vn_opt = e.object_get(String("variableName"))
        if vn_opt and vn_opt.value().is_string():
            expr = vn_opt.value().as_str()
        else:
            var ex_opt = e.object_get(String("expression"))
            if ex_opt and ex_opt.value().is_string():
                expr = ex_opt.value().as_str()
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
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var sl_opt = e.object_get(String("startLine"))
        var el_opt = e.object_get(String("endLine"))
        if not sl_opt or not el_opt or not sl_opt.value().is_int() \
                or not el_opt.value().is_int():
            continue
        var sl = sl_opt.value().as_int()
        var el = el_opt.value().as_int()
        if el <= sl:
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
    into range carriers (``new_text`` unused)."""
    var out = List[TextEditEntry]()
    if not v.is_object():
        return out^
    var r_opt = v.object_get(String("ranges"))
    if not r_opt or not r_opt.value().is_array():
        return out^
    var arr = r_opt.value().copy()
    for i in range(arr.array_len()):
        var rng = arr.array_at(i)
        if not rng.is_object():
            continue
        var en_opt = rng.object_get(String("end"))
        if not en_opt or not en_opt.value().is_object():
            continue
        var sp = _start_pos_of(rng)
        var el_opt = en_opt.value().object_get(String("line"))
        var ec_opt = en_opt.value().object_get(String("character"))
        if not el_opt or not ec_opt or not el_opt.value().is_int() \
                or not ec_opt.value().is_int():
            continue
        out.append(TextEditEntry(
            sp[0], sp[1], el_opt.value().as_int(), ec_opt.value().as_int(),
            String(""),
        ))
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
        var scheme = String("")
        var sc_opt = e.object_get(String("scheme"))
        if sc_opt and sc_opt.value().is_string():
            scheme = sc_opt.value().as_str()
        var entry = (scheme + String(":") + ident) if len(
            scheme.as_bytes()
        ) > 0 else ident
        if len(out.as_bytes()) > 0:
            out = out + String(", ")
        out = out + entry
    return out^


def _parse_document_links(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``DocumentLink[] | null`` into range carriers whose
    ``new_text`` is the link ``target`` uri. Links without an inline
    target (deferred to ``documentLink/resolve``, which we don't do) are
    skipped rather than shown as dead ranges."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var tgt_opt = e.object_get(String("target"))
        if not tgt_opt or not tgt_opt.value().is_string():
            continue
        var target = tgt_opt.value().as_str()
        if len(target.as_bytes()) == 0:
            continue
        var rng_opt = e.object_get(String("range"))
        if not rng_opt or not rng_opt.value().is_object():
            continue
        var rng = rng_opt.value().copy()
        var s_opt = rng.object_get(String("start"))
        var en_opt = rng.object_get(String("end"))
        if not s_opt or not en_opt or not s_opt.value().is_object() \
                or not en_opt.value().is_object():
            continue
        var sp = _start_pos_of(rng)
        var el_opt = en_opt.value().object_get(String("line"))
        var ec_opt = en_opt.value().object_get(String("character"))
        if not el_opt or not ec_opt or not el_opt.value().is_int() \
                or not ec_opt.value().is_int():
            continue
        out.append(TextEditEntry(
            sp[0], sp[1], el_opt.value().as_int(), ec_opt.value().as_int(),
            target,
        ))
    return out^


def _codelens_row_of(lens: JsonValue) -> Int:
    """The ``range.start.line`` of a CodeLens object (0 on any mismatch)."""
    if not lens.is_object():
        return 0
    var rng = lens.object_get(String("range"))
    if not rng or not rng.value().is_object():
        return 0
    var s = rng.value().object_get(String("start"))
    if not s or not s.value().is_object():
        return 0
    var ln = s.value().object_get(String("line"))
    if ln and ln.value().is_int():
        return ln.value().as_int()
    return 0


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
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var col_opt = e.object_get(String("color"))
        var rng_opt = e.object_get(String("range"))
        if not col_opt or not col_opt.value().is_object():
            continue
        if not rng_opt or not rng_opt.value().is_object():
            continue
        var col = col_opt.value().copy()
        var r_opt = col.object_get(String("red"))
        var g_opt = col.object_get(String("green"))
        var b_opt = col.object_get(String("blue"))
        if not r_opt or not g_opt or not b_opt:
            continue
        var r = _color_unit_to_255(r_opt.value())
        var g = _color_unit_to_255(g_opt.value())
        var b = _color_unit_to_255(b_opt.value())
        var rgb = UInt32((r << 16) | (g << 8) | b)
        # Contrast foreground: dark text on light swatches, light on dark.
        var lum = (r * 299 + g * 587 + b * 114) // 1000
        var fg = BLACK if lum > 140 else WHITE
        var rng = rng_opt.value().copy()
        var s_opt = rng.object_get(String("start"))
        var e2_opt = rng.object_get(String("end"))
        if not s_opt or not e2_opt or not s_opt.value().is_object() \
                or not e2_opt.value().is_object():
            continue
        var sl = s_opt.value().object_get(String("line"))
        var sc = s_opt.value().object_get(String("character"))
        var el = e2_opt.value().object_get(String("line"))
        var ec = e2_opt.value().object_get(String("character"))
        if not sl or not sc or not el or not ec \
                or not sl.value().is_int() or not sc.value().is_int() \
                or not el.value().is_int() or not ec.value().is_int():
            continue
        # Single-row swatch (color literals don't span lines).
        out.append(Highlight(
            sl.value().as_int(), sc.value().as_int(), ec.value().as_int(),
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
    var start_opt = rng_opt.value().object_get(String("start"))
    if not start_opt or not start_opt.value().is_object():
        return Optional[DefinitionResolved]()
    var ln = start_opt.value().object_get(String("line"))
    var ch = start_opt.value().object_get(String("character"))
    if not ln or not ch or not ln.value().is_int() or not ch.value().is_int():
        return Optional[DefinitionResolved]()
    return Optional[DefinitionResolved](DefinitionResolved(
        path, ln.value().as_int(), ch.value().as_int(),
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
    var cur = v.array_at(0)
    var depth = 0
    while cur.is_object() and depth < 128:
        depth += 1
        var rng_opt = cur.object_get(String("range"))
        if rng_opt and rng_opt.value().is_object():
            var rng = rng_opt.value().copy()
            var s_opt = rng.object_get(String("start"))
            var e_opt = rng.object_get(String("end"))
            if Bool(s_opt) and Bool(e_opt) and s_opt.value().is_object() \
                    and e_opt.value().is_object():
                var sl = s_opt.value().object_get(String("line"))
                var sc = s_opt.value().object_get(String("character"))
                var el = e_opt.value().object_get(String("line"))
                var ec = e_opt.value().object_get(String("character"))
                if Bool(sl) and Bool(sc) and Bool(el) and Bool(ec) \
                        and sl.value().is_int() \
                        and sc.value().is_int() and el.value().is_int() \
                        and ec.value().is_int():
                    out.append(TextEditEntry(
                        sl.value().as_int(), sc.value().as_int(),
                        el.value().as_int(), ec.value().as_int(), String(""),
                    ))
        var parent_opt = cur.object_get(String("parent"))
        if not parent_opt or not parent_opt.value().is_object():
            break
        cur = parent_opt.value().copy()
    return out^


def _parse_signature_help(v: JsonValue) -> String:
    """Render the active signature of a ``SignatureHelp`` result to a
    one-line status string. Returns the signature ``label`` and, when an
    active parameter with a string ``label`` is resolvable, appends
    ``  ▸ <param>``. Empty string for ``null`` / no signatures."""
    if not v.is_object():
        return String("")
    var sigs_opt = v.object_get(String("signatures"))
    if not sigs_opt or not sigs_opt.value().is_array():
        return String("")
    var sigs = sigs_opt.value().copy()
    if sigs.array_len() == 0:
        return String("")
    var active = 0
    var as_opt = v.object_get(String("activeSignature"))
    if as_opt and as_opt.value().is_int():
        active = as_opt.value().as_int()
    if active < 0 or active >= sigs.array_len():
        active = 0
    var sig = sigs.array_at(active)
    if not sig.is_object():
        return String("")
    var label_opt = sig.object_get(String("label"))
    if not label_opt or not label_opt.value().is_string():
        return String("")
    var label = label_opt.value().as_str()
    # Resolve the active parameter's string label if present.
    var ap = -1
    var ap_opt = v.object_get(String("activeParameter"))
    if ap_opt and ap_opt.value().is_int():
        ap = ap_opt.value().as_int()
    var sap_opt = sig.object_get(String("activeParameter"))
    if sap_opt and sap_opt.value().is_int():
        ap = sap_opt.value().as_int()
    var params_opt = sig.object_get(String("parameters"))
    if ap >= 0 and params_opt and params_opt.value().is_array():
        var params = params_opt.value().copy()
        if ap < params.array_len():
            var p = params.array_at(ap)
            if p.is_object():
                var pl_opt = p.object_get(String("label"))
                if pl_opt and pl_opt.value().is_string():
                    return label + String("   ▸ ") + pl_opt.value().as_str()
    return label


def _parse_document_highlights(v: JsonValue) -> List[TextEditEntry]:
    """Parse ``DocumentHighlight[] | null`` into range carriers
    (``TextEditEntry`` with empty ``new_text``). Each entry has a
    ``range``; the optional ``kind`` (text/read/write) is ignored — we
    paint all occurrences the same."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for i in range(v.array_len()):
        var e = v.array_at(i)
        if not e.is_object():
            continue
        var rng_opt = e.object_get(String("range"))
        if not rng_opt or not rng_opt.value().is_object():
            continue
        var rng = rng_opt.value().copy()
        var s_opt = rng.object_get(String("start"))
        var e_opt = rng.object_get(String("end"))
        if not s_opt or not e_opt \
                or not s_opt.value().is_object() \
                or not e_opt.value().is_object():
            continue
        var sl = s_opt.value().object_get(String("line"))
        var sc = s_opt.value().object_get(String("character"))
        var el = e_opt.value().object_get(String("line"))
        var ec = e_opt.value().object_get(String("character"))
        if not sl or not sc or not el or not ec \
                or not sl.value().is_int() or not sc.value().is_int() \
                or not el.value().is_int() or not ec.value().is_int():
            continue
        out.append(TextEditEntry(
            sl.value().as_int(), sc.value().as_int(),
            el.value().as_int(), ec.value().as_int(), String(""),
        ))
    return out^


def _parse_text_edits(v: JsonValue) -> List[TextEditEntry]:
    """Parse a bare ``TextEdit[] | null`` (the formatting response shape)
    into ``TextEditEntry`` rows, skipping malformed entries. Reused for any
    request that returns a flat edit list for a single file."""
    var out = List[TextEditEntry]()
    if not v.is_array():
        return out^
    for j in range(v.array_len()):
        var te = v.array_at(j)
        if not te.is_object():
            continue
        var nt_opt = te.object_get(String("newText"))
        if not nt_opt or not nt_opt.value().is_string():
            continue
        var nt = nt_opt.value().as_str()
        var rng_opt = te.object_get(String("range"))
        if not rng_opt or not rng_opt.value().is_object():
            continue
        var rng = rng_opt.value().copy()
        var s_opt = rng.object_get(String("start"))
        var e_opt = rng.object_get(String("end"))
        if not s_opt or not e_opt \
                or not s_opt.value().is_object() \
                or not e_opt.value().is_object():
            continue
        var sl = s_opt.value().object_get(String("line"))
        var sc = s_opt.value().object_get(String("character"))
        var el = e_opt.value().object_get(String("line"))
        var ec = e_opt.value().object_get(String("character"))
        if not sl or not sc or not el or not ec \
                or not sl.value().is_int() or not sc.value().is_int() \
                or not el.value().is_int() or not ec.value().is_int():
            continue
        out.append(TextEditEntry(
            sl.value().as_int(), sc.value().as_int(),
            el.value().as_int(), ec.value().as_int(), nt,
        ))
    return out^


def _text_document_position_params(
    path: String, line: Int, character: Int,
) -> JsonValue:
    """Build the ``{textDocument:{uri}, position:{line,character}}`` params
    object shared by the definition / references / completion / hover
    requests. Callers add request-specific fields (e.g. ``context``) to the
    returned object."""
    var params = json_object()
    params.put(String("textDocument"), _text_document(path))
    params.put(String("position"), _lsp_position(line, character))
    return params^


def _uri_hex_nibble(n: Int) -> UInt8:
    if n < 10:
        return UInt8(0x30 + n)          # '0'..'9'
    return UInt8(0x41 + n - 10)         # 'A'..'F'


def _uri_hex_val(b: Int) -> Int:
    if 0x30 <= b and b <= 0x39:
        return b - 0x30
    if 0x41 <= b and b <= 0x46:
        return b - 0x41 + 10
    if 0x61 <= b and b <= 0x66:
        return b - 0x61 + 10
    return -1


def _path_to_uri(path: String) -> String:
    """``/abs/path`` → ``file:///abs/path``. Resolves through realpath when
    possible so the server sees the same canonical form across calls.
    Percent-encodes bytes outside the RFC 3986 unreserved set (keeping
    ``/``) so paths with spaces / non-ASCII round-trip through
    ``_uri_to_path`` and match what spec-compliant servers expect."""
    var resolved = realpath(path)
    var p = resolved if len(resolved.as_bytes()) > 0 else path
    var b = p.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var c = Int(b[i])
        var unreserved = (0x41 <= c and c <= 0x5A) \
            or (0x61 <= c and c <= 0x7A) \
            or (0x30 <= c and c <= 0x39) \
            or c == 0x2D or c == 0x5F or c == 0x2E or c == 0x7E \
            or c == 0x2F
        if unreserved:
            out.append(b[i])
        else:
            out.append(0x25)            # '%'
            out.append(_uri_hex_nibble((c >> 4) & 0xF))
            out.append(_uri_hex_nibble(c & 0xF))
    return String("file://") + String(StringSlice(
        ptr=out.unsafe_ptr(), length=len(out),
    ))


def uri_to_path(uri: String) -> String:
    """Public wrapper over ``_uri_to_path`` for hosts (e.g. the rename
    edit-application path) that need to map a WorkspaceEdit's file URIs
    back to on-disk paths."""
    return _uri_to_path(uri)


def _uri_to_path(uri: String) -> String:
    """Strip the ``file://`` scheme and percent-decode ``%XX`` escapes
    (spec-compliant servers encode spaces / non-ASCII in path bytes; an
    undecoded ``%20`` wouldn't match a ``_doc_paths`` entry or open on
    disk). A malformed ``%`` is left as a literal byte."""
    var prefix = String("file://")
    var pb = prefix.as_bytes()
    var ub = uri.as_bytes()
    if len(ub) < len(pb):
        return uri
    for i in range(len(pb)):
        if ub[i] != pb[i]:
            return uri
    var out = List[UInt8]()
    var i = len(pb)
    while i < len(ub):
        if ub[i] == 0x25 and i + 2 < len(ub):   # '%XX'
            var hi = _uri_hex_val(Int(ub[i + 1]))
            var lo = _uri_hex_val(Int(ub[i + 2]))
            if hi >= 0 and lo >= 0:
                out.append(UInt8((hi << 4) | lo))
                i += 3
                continue
        out.append(ub[i])
        i += 1
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))
