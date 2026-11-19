"""High-level DAP wiring: state machine, breakpoint tracking, execution
control, surfaced events for the UI layer.

``DapManager`` owns one DAP adapter for a single debug session. It:

* spawns the adapter on demand and drives the
  ``initialize`` → ``launch`` → ``initialized`` → ``setBreakpoints`` →
  ``configurationDone`` handshake asynchronously (no blocking the UI);
* tracks client-side breakpoints by path, resending the full list per
  file whenever the user toggles one (DAP's ``setBreakpoints`` replaces
  all breakpoints for that source in one shot);
* parks the most recent ``stopped`` / ``continued`` / ``terminated`` /
  ``output`` events for the host to drain via ``poll_*`` accessors;
* lets the host poll a single ``tick`` per frame to advance state;
* exposes ``request_stack_trace`` / ``request_scopes`` /
  ``request_variables`` so the UI can lazily fetch debug state when
  the user expands a frame / scope / variable.

Limitations on purpose: one adapter per manager, plus the one forked
debugpy subprocess session (no general multi-session), and no hit-count
breakpoints.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .dap import (
    DAP_EVENT, DAP_RESPONSE, DapClient, DapIncoming, dap_initialize_arguments,
)
from .debugger_config import (
    DAP_REQUEST_ATTACH, DAP_REQUEST_LAUNCH,
    DebuggerSpec, launch_arguments_for,
)
from .json import (
    json_array, json_bool, json_get_bool, json_get_int, json_get_string, json_int,
    json_object, json_str, JsonValue,
)
from std.ffi import external_call

from .breakpoint_store import StoredBreakpoint
from .lsp import LspProcess
from .posix import (
    debug_log_path, monotonic_ms, realpath_or_self, tcp_connect, which,
)
from .string_utils import (
    fnv_int, fnv_start, fnv_str, starts_with, strip_trailing_newlines,
)
from .capped_text import CappedText


# --- state machine --------------------------------------------------------

comptime _STATE_NOT_STARTED  = UInt8(0)
comptime _STATE_INITIALIZING = UInt8(1)
"""Sent ``initialize``, waiting for the response."""
comptime _STATE_LAUNCHING    = UInt8(2)
"""Got ``initialize`` response, sent ``launch`` / ``attach``, waiting
for the ``initialized`` event so we can configure breakpoints."""
comptime _STATE_CONFIGURING  = UInt8(3)
"""Got ``initialized`` event, sent ``setBreakpoints`` + ``configurationDone``,
waiting for that response."""
comptime _STATE_RUNNING      = UInt8(4)
"""Configuration done — the debuggee is running. ``is_stopped`` flips
true while a ``stopped`` event is unacknowledged."""
comptime _STATE_TERMINATED   = UInt8(5)
"""Adapter signaled session end."""
comptime _STATE_FAILED       = UInt8(6)


# --- surfaced data --------------------------------------------------------


@fieldwise_init
struct DapStopped(ImplicitlyCopyable, Movable):
    """Latched state from the most recent ``stopped`` event.

    ``thread_id`` is what the UI feeds into a follow-up ``stackTrace``
    request. ``reason`` is the spec'd code (``breakpoint``, ``step``,
    ``exception``, ``pause``, ``entry``, ...). ``description`` is the
    adapter's human text — often empty.

    ``from_subprocess`` flags stops that arrived on the forked-child
    DAP socket. The thread/frame/variable IDs in any follow-up request
    are subprocess-scoped — pydevd hands out per-process dap_ids and
    raises ``KeyError("Wrong ID sent from the client")`` if a parent
    socket gets one of the child's IDs.
    """
    var thread_id: Int
    var reason: String
    var description: String
    var all_threads_stopped: Bool
    var from_subprocess: Bool


@fieldwise_init
struct DapOutput(ImplicitlyCopyable, Movable):
    """One ``output`` event's payload. ``category`` is ``stdout`` /
    ``stderr`` / ``console`` / ``important`` per the spec."""
    var category: String
    var text: String


@fieldwise_init
struct DapStackFrame(ImplicitlyCopyable, Movable):
    """One frame from a ``stackTrace`` response.

    ``path`` is the source file (extracted from ``source.path`` in the
    response). When the adapter only returns a ``source.name`` (e.g.,
    for builtin code with no on-disk file), ``path`` is empty and the
    UI should render ``name`` instead.

    ``subtle`` is True for frames the adapter wants de-emphasized —
    library / stdlib / external code. Set when the frame's
    ``presentationHint`` is ``subtle`` or ``label``, or the frame's
    ``source.presentationHint`` is ``deemphasize``. The UI paints these
    in a dim color so the user can still see them but visually
    distinguish them from their own code.
    """
    var id: Int
    var name: String
    var path: String
    var line: Int        # 0-based — adapter is configured ``linesStartAt1=false``
    var column: Int
    var subtle: Bool


@fieldwise_init
struct DapCompletion(ImplicitlyCopyable, Movable):
    """One target from a ``completions`` response. ``text`` is what to
    insert (``label`` when the adapter sent none). ``start`` / ``length``
    are the adapter's replaced span as sent (``start = -1`` when absent).
    Adapters disagree on its base (debugpy sends 0-based against DAP's
    1-based default), so the console doesn't rely on it."""
    var label: String
    var text: String
    var type_name: String
    var start: Int
    var length: Int


@fieldwise_init
struct DapScope(ImplicitlyCopyable, Movable):
    """One scope from a ``scopes`` response. ``variables_reference`` is
    the handle the UI feeds into a follow-up ``variables`` request to
    fetch this scope's contents."""
    var name: String
    var variables_reference: Int
    var expensive: Bool


@fieldwise_init
struct DapEvaluation(Copyable, Movable):
    """One evaluate response, as ``take_evaluations`` drains them.

    ``context`` carries the request-time hint (``"watch"`` / ``"repl"``
    / ``"hover"``) so the host can route REPL console results to the
    output log while watch results fold into their rows. ``is_error`` is
    True when the adapter reported the evaluate as a failed request (the
    expression raised) — the console paints those red rather than as a
    normal value, which is ``<error: …>`` then."""
    var expression: String
    var value: String
    var type_name: String
    var context: String
    var is_error: Bool


@fieldwise_init
struct DapVariable(ImplicitlyCopyable, Movable):
    """One variable from a ``variables`` response.

    ``variables_reference`` is non-zero when the variable has children
    (struct / array / dict) — the UI uses it to expand the row.
    """
    var name: String
    var value: String
    var type_name: String
    var variables_reference: Int


@fieldwise_init
struct DapBreakpointError(ImplicitlyCopyable, Movable):
    """Surfaced when the adapter rejects a breakpoint — most often a
    bad ``condition`` expression. ``path`` / ``line`` identify the BP
    in our local list (0-based line). ``message`` is the adapter's
    human text. The host pops these via ``take_breakpoint_errors`` and
    opens the condition-fix dialog."""
    var path: String
    var line: Int
    var message: String


@fieldwise_init
struct DapConditionException(ImplicitlyCopyable, Movable):
    """Surfaced when a *runtime* error happens while pydevd evaluates a
    conditional breakpoint expression (e.g. ``NameError`` because a
    variable doesn't exist in this frame). Distinct from
    ``DapBreakpointError`` which fires at ``setBreakpoints`` time for
    a syntactically bad condition.

    debugpy reports this via an ``output`` event of category
    ``important`` whose text starts with
    ``pydevd: Error while evaluating expression in conditional
    breakpoint: <condition>\\n<traceback>`` — and then suspends the
    thread (which we forced on via ``setDebuggerProperty``). The host
    drains this on the next stop and uses it to open the condition-error
    dialog with the offending condition pre-loaded.

    ``condition`` is the original BP condition expression as pydevd
    saw it; ``error`` is the short summary (last non-empty traceback
    line — typically ``ExceptionType: message``) suitable for the
    dialog's single-line error strip."""
    var condition: String
    var error: String


@fieldwise_init
struct DapTestEvaluation(ImplicitlyCopyable, Movable):
    """One result of ``request_test_evaluate`` — the dedicated channel
    the condition-error dialog uses to validate an edited expression
    without colliding with watch / REPL evaluations.

    ``is_error`` is True when the adapter reported the evaluate as a
    failed request (the expression raised); in that case ``value`` is
    the error message. On success ``value`` is the evaluated result as
    a string (e.g. ``"True"``, ``"42"``) — the dialog tests its
    truthiness to decide whether to keep the program paused or
    auto-continue past the BP."""
    var expression: String
    var value: String
    var is_error: Bool


# --- SubprocessAttach -----------------------------------------------------
# debugpy's subprocess-attach flow: when the debuggee forks, debugpy emits a
# ``debugpyAttach`` event with a TCP host/port and a ``subProcessId``. The
# child blocks at startup waiting for the IDE to open that socket and send
# a normal initialize/attach handshake — without it, frameworks that fork
# (Django ``runserver`` spawning the actual HTTP server, multiprocessing,
# pytest-xdist) hang at startup.
#
# We keep one ``SubprocessAttach`` per child, each with its own DapClient
# wrapping a connected socket. Output events are surfaced through the same
# parent channel (``_output_events``) so the user sees one merged log; we
# don't expose subprocess threads/stack/scopes through the inspect view —
# breakpoints in subprocess code are pushed through, but stepping etc. is
# parent-only for now.

@fieldwise_init
struct DapBreakpoint(ImplicitlyCopyable, Movable):
    """One client-side breakpoint. ``line`` is 0-based. ``condition`` is
    empty for an unconditional one."""
    var path: String
    var line: Int
    var condition: String
    # False marks a "parked" breakpoint: it stays in the list (and on disk
    # via ``breakpoint_store``) so the user doesn't lose the row +
    # condition, but it's stripped from ``setBreakpoints`` payloads so the
    # adapter never fires it.
    var enabled: Bool
    # "Enable after another BP is hit": empty = no dependency, else the
    # trigger BP as ``"<full-path>:<1-based-line>"`` (matched against
    # ``"<other.path>:<other.line+1>"``). Persisted.
    var wait_for: String
    # "Trigger has fired this session": True while there's no dependency,
    # or once the trigger has been hit; until then the BP is held back
    # from ``setBreakpoints``. Resets on session restart.
    var armed: Bool

    @staticmethod
    def from_stored(b: StoredBreakpoint) -> DapBreakpoint:
        return DapBreakpoint(
            b.path, b.line, b.condition, b.enabled, b.wait_for,
            len(b.wait_for.as_bytes()) == 0,
        )

    def stored(self) -> StoredBreakpoint:
        return StoredBreakpoint(
            self.path, self.line, self.condition, self.enabled, self.wait_for,
        )


def _bp_json(b: DapBreakpoint) -> JsonValue:
    """One ``SourceBreakpoint`` for ``setBreakpoints``. +1: lines are
    1-based on the wire regardless of ``linesStartAt1`` (see
    ``toggle_breakpoint``)."""
    var bp = json_object()
    bp.put(String("line"), json_int(b.line + 1))
    if len(b.condition.as_bytes()) > 0:
        bp.put(String("condition"), json_str(b.condition))
    return bp^


comptime _ANS_NONE = 0
comptime _ANS_STACK = 1
comptime _ANS_SCOPES = 2
comptime _ANS_VARIABLES = 3
comptime _ANS_COMPLETIONS = 4
comptime _ANS_KEYS_EVAL = 5
comptime _ANS_KEYS_VARS = 6
comptime _ANS_EVALUATE = 7
comptime _ANS_TEST_EVALUATE = 8


@fieldwise_init
struct _InspectAnswer(Movable):
    """Which in-flight inspect request a response answers (``_ANS_*``),
    plus what an evaluate was asked for."""
    var kind: Int
    var expr: String
    var context: String


@fieldwise_init
struct _PendingEval(Copyable, Movable):
    """An ``evaluate`` in flight: its seq, the expression, the request-time
    context hint (``"watch"`` / ``"repl"`` / ``"hover"``, so the host can
    route REPL console lines apart from watch folds), and whether it's the
    condition-error dialog's test evaluate."""
    var seq: Int
    var expr: String
    var context: String
    var test: Bool


@fieldwise_init
struct _InflightSetBreakpoints(Copyable, Movable):
    """A ``setBreakpoints`` in flight: its seq, the file, and the exact
    lines sent (adapter array order; -1 for a run-to-cursor oneshot)."""
    var seq: Int
    var path: String
    var lines: List[Int]


struct _InspectRequests(Copyable, Movable):
    """The inspect-side requests in flight on one DAP connection. The
    parent session and a forked subprocess each have one: their seq
    counters are independent (both start at 1), so a shared table would
    mis-route. Answers from either land in the same ``_pending_*`` /
    ``_evaluations`` buffer on ``DapManager`` — the UI is
    single-session and doesn't care which session answered. Zero = nothing
    in flight."""
    var stack_trace: Int
    var scopes: Int
    var variables: Int
    # Console completions and key completion (``foo['``): own slots, not
    # the watch / variables-pane ones, so they can't steal their answers.
    var completions: Int
    var keys_eval: Int
    var keys_vars: Int
    # Watch / REPL / test ``evaluate``s. A list, not one slot, so every
    # watch can be in flight at once, demuxed on ``request_seq``.
    var evals: List[_PendingEval]

    def __init__(out self):
        self.stack_trace = 0
        self.scopes = 0
        self.variables = 0
        self.completions = 0
        self.keys_eval = 0
        self.keys_vars = 0
        self.evals = List[_PendingEval]()

    def claim(mut self, rseq: Int) -> _InspectAnswer:
        """Which request ``rseq`` answers, no longer in flight once
        claimed; kind ``_ANS_NONE`` when it's none of these."""
        if rseq == self.stack_trace:
            self.stack_trace = 0
            return _InspectAnswer(_ANS_STACK, String(""), String(""))
        if rseq == self.scopes:
            self.scopes = 0
            return _InspectAnswer(_ANS_SCOPES, String(""), String(""))
        if rseq == self.variables:
            self.variables = 0
            return _InspectAnswer(_ANS_VARIABLES, String(""), String(""))
        if rseq == self.completions:
            self.completions = 0
            return _InspectAnswer(_ANS_COMPLETIONS, String(""), String(""))
        if rseq == self.keys_eval:
            self.keys_eval = 0
            return _InspectAnswer(_ANS_KEYS_EVAL, String(""), String(""))
        if rseq == self.keys_vars:
            self.keys_vars = 0
            return _InspectAnswer(_ANS_KEYS_VARS, String(""), String(""))
        for k in range(len(self.evals)):
            if self.evals[k].seq == rseq:
                var e = self.evals.pop(k)
                return _InspectAnswer(
                    _ANS_TEST_EVALUATE if e.test else _ANS_EVALUATE,
                    e.expr, e.context,
                )
        return _InspectAnswer(_ANS_NONE, String(""), String(""))


struct SubprocessAttach(Copyable, Movable):
    var client: DapClient
    var sub_process_id: Int
    var name: String
    var state: UInt8                 # _STATE_NOT_STARTED while idle, then _INITIALIZING / _LAUNCHING / _CONFIGURING / _RUNNING / _TERMINATED / _FAILED
    var inflight_initialize: Int
    var inflight_attach: Int
    var inflight_config_done: Int
    # Inspect requests in flight on the subprocess socket. Frame ids are
    # session-scoped — a subprocess-issued frameId sent through the parent
    # socket fails with ``Wrong ID sent from the client`` — so they go out
    # here, demuxed against this session's own seq counter.
    var rq: _InspectRequests
    var got_initialized_event: Bool
    var pending_attach_args: JsonValue

    def __init__(out self):
        # Inert default — ``state == _STATE_NOT_STARTED`` is the sentinel
        # for "no subprocess is attached". Lets the field live as a
        # direct ``DapManager`` member without ``Optional`` plumbing,
        # which would force a copy-out / copy-in dance the connected
        # socket fd doesn't survive.
        self.client = DapClient(LspProcess())
        self.sub_process_id = -1
        self.name = String("")
        self.state = _STATE_NOT_STARTED
        self.inflight_initialize = 0
        self.inflight_attach = 0
        self.inflight_config_done = 0
        self.rq = _InspectRequests()
        self.got_initialized_event = False
        self.pending_attach_args = JsonValue()

    def __copyinit__(mut self, copy: Self):
        # Same caveat as ``DapManager.__copyinit__``: a real copy would
        # double-own the connected socket. We declare ``Copyable`` only
        # so the field can live in a ``DapManager`` (which is itself
        # Copyable for List storage). Hands back an inert sibling.
        # A copy is a fresh instance, exactly what ``__init__`` builds:
        # one list of field defaults, not two to keep in step.
        self = Self()

# --- DapManager -----------------------------------------------------------


struct DapManager(Copyable, Movable):
    """One DAP session's worth of state plus the transport (``DapClient``).

    Like ``LspManager``, the client is held by-value; before ``start``
    it's a default-constructed sentinel with ``pid == -1``, which the
    framer code treats as inert. The single transition into
    ``_STATE_INITIALIZING`` is the only path that replaces ``self.client``
    with a freshly spawned one.
    """

    var client: DapClient
    var state: UInt8
    var failure_reason: String
    var adapter_name: String   # e.g. "debugpy", surfaced in status bar
    var language_id: String

    # In-flight request seqs we care about. Zero = nothing in flight.
    var _inflight_initialize: Int
    var _inflight_launch: Int
    var _inflight_config_done: Int
    # Inspect requests in flight on the parent session (the subprocess
    # has its own, ``_subprocess.rq``).
    var _rq: _InspectRequests

    # Capabilities returned by the adapter (parked from initialize response).
    var _supports_configuration_done: Bool
    var _supports_terminate_request: Bool
    # ``supportsCompletionsRequest`` from the capabilities — gates the
    # console's completion requests.
    var _supports_completions: Bool
    # Console completions: one request in flight at a time (``rq.
    # completions``), the newest answer parked in
    # ``_completions`` until the host drains it. ``_completions_text`` /
    # ``_completions_column`` echo what the answer is for, so the host can
    # drop one that the user has since typed past.
    var _completions_req_text: String
    var _completions_req_column: Int
    var _completions: List[DapCompletion]
    var _completions_ready: Bool
    var _completions_text: String
    var _completions_column: Int
    # Console key completion (``foo['``): evaluate the container, then fetch
    # its children — a mapping's children are named by key repr.
    # ``_keys`` holds the drained result for ``_keys_expr``.
    var _keys_req_expr: String
    var _keys: List[String]
    var _keys_ready: Bool
    var _keys_expr: String
    # Which pass the in-flight key fetch is on: 0 = the container's own
    # children (a real dict: named by key repr), 1 = the Python fallback
    # for dict-likes (``list((expr).keys())``, keys read from the element
    # *values*). ``_keys_via_sub`` remembers which session to ask.
    var _keys_stage: Int
    var _keys_via_sub: Bool
    var _keys_frame_id: Int

    # Whether we've seen the ``initialized`` event. We track this
    # separately from the launch response because the spec lets either
    # arrive first.
    var _got_initialized_event: Bool
    var _launch_request_kind: UInt8

    # Client-side breakpoint state, in the order the user set them.
    var _bps: List[DapBreakpoint]
    # Demux table for ``setBreakpoints`` responses. Each entry parks
    # the source path of a sent request; the response carries a
    # parallel ``breakpoints`` array we line up by index against the
    # local rows for that path. Without tracking these we can't tell
    # *which* file's BPs the adapter just verified — and without that
    # we can't surface a per-BP "verified=false, message=..." back to
    # the user as a condition error.
    # Each keeps the exact lines sent: the response demux MUST use them
    # rather than re-deriving from the live BP arrays, which can change
    # (toggle/enable/remove) between send and response and would
    # mis-align a ``verified=false`` rejection with the wrong line.
    var _inflight_set_breakpoints: List[_InflightSetBreakpoints]
    # Buffer of breakpoint errors surfaced via ``take_breakpoint_errors``.
    # Single drain per frame; entries describe one rejected BP each.
    var _bp_errors: List[DapBreakpointError]
    # Exception filters to enable on the next ``setExceptionBreakpoints``
    # call. ``"uncaught"`` and ``"raised"`` are the canonical filter ids
    # most adapters accept; we let callers configure freely without
    # validating against capabilities (a wrong id yields a soft error
    # in the response body — non-fatal).
    var _exception_filters: List[String]
    # Buffer of completed evaluate responses; drained by the host once
    # per frame via ``take_evaluations``. ``_evaluations_context`` and
    # ``_evaluations_is_error`` are parallel to the expr/value/type lists.
    var _evaluations: List[DapEvaluation]
    # Independent test-evaluate channel — used by the condition-error
    # dialog to validate an edited BP condition against the live frame
    # before committing it. Kept separate from the watch/REPL evaluate
    # channel because ``_fold_watch_results`` silently drops anything
    # that isn't a known watch expression — sending a one-shot test
    # eval on that channel would lose the response. Same shape (in-flight
    # seq + expression list, then drained results), with an extra
    # ``error`` flag so the dialog can distinguish "evaluation raised"
    # from "evaluation returned the string ``<error: …>``".
    var _test_evals: List[DapTestEvaluation]
    # Most-recent ``Error while evaluating expression in conditional
    # breakpoint`` message, parsed from a debugpy ``output`` event of
    # category ``important``. Cleared by ``take_condition_exception``,
    # which the host calls once per tick after handling the surfaced
    # ``stopped`` event. Empty ``condition`` is the sentinel for "none
    # buffered" (a real BP condition expression is never empty — the
    # absence of a condition is encoded by an empty ``DapBreakpoint.condition``,
    # not by storing an empty condition here).
    var _pending_cond_exc_condition: String
    var _pending_cond_exc_error: String

    # Surfaced events (consumed via ``take_*`` accessors).
    var _stopped: Optional[DapStopped]
    var _is_stopped: Bool
    var _continued_pending: Bool   # latch: a ``continued`` event arrived
    var _output_events: List[DapOutput]
    var _terminated_pending: Bool

    # Async response buffers — single-slot, freshest wins.
    var _pending_stack: List[DapStackFrame]
    var _pending_stack_ready: Bool
    var _pending_scopes: List[DapScope]
    var _pending_scopes_ready: Bool
    var _pending_vars: List[DapVariable]
    var _pending_vars_ready: Bool

    # Launch arguments are stashed at ``start`` time and replayed once
    # the ``initialize`` response lands. Keeping the JSON object around
    # means dispatch never re-reads the registry past start.
    var _pending_launch_args: JsonValue
    # The argv we actually spawned with — useful for diagnostics when
    # the user reports "stuck at initializing" and we need to know
    # whether we ran ``debugpy-adapter`` directly or fell through to
    # ``python -m debugpy.adapter``. Resolved via ``which``, so it's
    # the absolute path the kernel actually executed.
    var spawn_argv: List[String]
    # Rolling capture of the adapter's stderr. ``drain_stderr`` appends
    # each chunk it returns here, so the info window can show what the
    # adapter printed even though ``drain_stderr`` itself is destructive
    # (each call empties the OS pipe). Capped at 16 KB so a runaway
    # adapter can't grow this buffer unbounded — we keep the *tail*,
    # since the latest output is what tells us why a session just died.
    var _stderr_log: CappedText
    # Wall-clock timestamp (ms) when we entered the current state.
    # Read by the watchdog in ``tick`` to fail a session that's been
    # ``INITIALIZING`` / ``LAUNCHING`` for too long without forward
    # progress. Without this a misbehaving adapter just sits forever
    # and the user can't tell whether to wait or kill the session.
    var _state_entered_ms: Int
    # Last heartbeat trace timestamp. Emitted every few seconds while
    # the session is alive but nothing else is happening, so a user
    # tailing the trace log can tell "frozen" from "idle/waiting".
    var _last_heartbeat_ms: Int

    # Forked subprocess sessions. debugpy emits one ``debugpyAttach``
    # event per child it sees; we open a TCP socket per child and run a
    # mini DAP handshake against it so the child can proceed. Single-slot
    # for now (Django runserver, multiprocessing pools fork once at
    # startup); extending to a list when a real-world target needs it
    # is straightforward — each entry is independent.
    var _subprocess: SubprocessAttach
    # Tracks which session ``request_stack_trace`` was last routed to.
    # ``request_scopes`` / ``request_variables`` consume frame_ids /
    # variable_references that came from that stack response, so they
    # must follow the same routing — pydevd's per-process dap_id table
    # rejects IDs from a different session.
    var _last_inspect_in_subprocess: Bool
    # Sticky mirror of ``_stopped.from_subprocess`` that survives
    # ``take_stopped``. Set in ``_on_stopped_event``, cleared in the
    # ``continued`` handlers and at teardown. ``request_stack_trace``
    # and ``_send_thread_command`` consult this — they often run *after*
    # the host has popped ``_stopped`` via ``take_stopped`` and would
    # otherwise lose the routing hint.
    var _stop_in_subprocess: Bool
    # Sticky mirror of ``_stopped.thread_id``. Same lifecycle as
    # ``_stop_in_subprocess`` — set on stop, cleared on continue/teardown.
    # ``_send_thread_command`` (next/stepIn/stepOut/continue/pause) needs
    # the actual paused thread id; pydevd treats requests with an unknown
    # threadId as "continue all" rather than a step, so a stale default
    # of 1 silently turns Step Over into Continue.
    var _last_stopped_thread_id: Int

    # One-shot breakpoint backing "run to cursor". DAP has no native
    # one-shot, so we inject this into the next ``setBreakpoints`` for
    # the path and clear it on the next ``stopped`` event (re-pushing
    # ``setBreakpoints`` to scrub the adapter side). Empty path = no
    # oneshot. Coexists with a regular BP at the same line — we suppress
    # the duplicate in ``_send_set_breakpoints``.
    var _oneshot_bp_path: String
    var _oneshot_bp_line: Int

    def __init__(out self):
        self.client = DapClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self.adapter_name = String("")
        self.language_id = String("")
        self._inflight_initialize = 0
        self._inflight_launch = 0
        self._inflight_config_done = 0
        self._rq = _InspectRequests()
        self._supports_configuration_done = True
        self._supports_terminate_request = False
        self._got_initialized_event = False
        self._launch_request_kind = DAP_REQUEST_LAUNCH
        self._bps = List[DapBreakpoint]()
        self._inflight_set_breakpoints = List[_InflightSetBreakpoints]()
        self._bp_errors = List[DapBreakpointError]()
        self._exception_filters = _default_exception_filters()
        self._evaluations = List[DapEvaluation]()
        self._supports_completions = False
        self._completions_req_text = String("")
        self._completions_req_column = 0
        self._completions = List[DapCompletion]()
        self._completions_ready = False
        self._completions_text = String("")
        self._completions_column = 0
        self._keys_req_expr = String("")
        self._keys = List[String]()
        self._keys_ready = False
        self._keys_expr = String("")
        self._keys_stage = 0
        self._keys_via_sub = False
        self._keys_frame_id = 0
        self._test_evals = List[DapTestEvaluation]()
        self._pending_cond_exc_condition = String("")
        self._pending_cond_exc_error = String("")
        self._stopped = Optional[DapStopped]()
        self._is_stopped = False
        self._continued_pending = False
        self._output_events = List[DapOutput]()
        self._terminated_pending = False
        self._pending_stack = List[DapStackFrame]()
        self._pending_stack_ready = False
        self._pending_scopes = List[DapScope]()
        self._pending_scopes_ready = False
        self._pending_vars = List[DapVariable]()
        self._pending_vars_ready = False
        self._pending_launch_args = JsonValue()
        self.spawn_argv = List[String]()
        # Keeps the tail: the most recent output says why a session died.
        self._stderr_log = CappedText(16384, keep_tail=True)
        self._state_entered_ms = 0
        self._last_heartbeat_ms = 0
        self._subprocess = SubprocessAttach()
        self._last_inspect_in_subprocess = False
        self._stop_in_subprocess = False
        self._last_stopped_thread_id = 0
        self._oneshot_bp_path = String("")
        self._oneshot_bp_line = -1

    def __copyinit__(mut self, copy: Self):
        # Same caveat as ``LspManager.__copyinit__``: a real copy would
        # duplicate child PID + pipe FD ownership. We declare ``Copyable``
        # only so a manager can live in ``List[DapManager]``; lists are
        # grown via ``^`` transfer in practice and this branch shouldn't
        # fire for a live session. If it ever does, we hand back an
        # inert NOT_STARTED sibling.
        # A copy is a fresh instance, exactly what ``__init__`` builds:
        # one list of field defaults, not two to keep in step.
        self = Self()

    def is_active(self) -> Bool:
        return self.state != _STATE_NOT_STARTED \
            and self.state != _STATE_FAILED \
            and self.state != _STATE_TERMINATED

    def is_running(self) -> Bool:
        return self.state == _STATE_RUNNING and not self._is_stopped

    def is_stopped(self) -> Bool:
        # Gated on ``is_active`` for the same reason ``is_running``
        # checks state: ``shutdown`` doesn't clear ``_is_stopped``, so
        # without this gate a session that was paused at a breakpoint
        # when the user hit Shift+F5 reports as "stopped" forever and
        # ``_debug_start_or_continue`` keeps routing F5 to ``cont()``
        # instead of starting a new session.
        return self._is_stopped and self.is_active()

    def is_failed(self) -> Bool:
        return self.state == _STATE_FAILED

    def _fail(mut self, var reason: String):
        """Latch the session FAILED with ``reason`` (shown to the user, and
        traced)."""
        self.state = _STATE_FAILED
        self.client.process.trace(String("FAIL: ") + reason)
        self.failure_reason = reason^

    def _fail_rejected(mut self, what: String, msg: DapIncoming):
        """``_fail`` for a request the adapter answered with
        ``success: false``: ``<what> rejected[: <its message>]``."""
        var why = what + String(" rejected")
        if msg.message:
            why += String(": ") + msg.message.value()
        self._fail(why^)

    def is_terminated(self) -> Bool:
        return self.state == _STATE_TERMINATED

    def status_summary(self) -> String:
        """Short label suitable for the status bar."""
        if self.state == _STATE_NOT_STARTED:
            return String("DAP: idle")
        if self.state == _STATE_FAILED:
            return String("DAP: failed — ") + self.failure_reason
        if self.state == _STATE_TERMINATED:
            return String("DAP: terminated")
        if self.state == _STATE_INITIALIZING:
            return String("DAP[") + self.adapter_name + String("]: initializing")
        if self.state == _STATE_LAUNCHING:
            return String("DAP[") + self.adapter_name + String("]: launching")
        if self.state == _STATE_CONFIGURING:
            return String("DAP[") + self.adapter_name + String("]: configuring")
        if self._is_stopped:
            return String("DAP[") + self.adapter_name + String("]: stopped")
        return String("DAP[") + self.adapter_name + String("]: running")

    # --- session lifecycle -----------------------------------------------

    def start(
        mut self, spec: DebuggerSpec, program: String, cwd: String,
        var program_args: List[String], stop_on_entry: Bool = False,
        env: List[String] = List[String](),
    ):
        """Spawn the adapter and kick off the handshake.

        ``env`` is the target's extra ``KEY=VALUE`` list, forwarded on
        the ``launch`` body (see ``launch_arguments_for``).

        Picks the first candidate from ``spec.candidates`` whose argv[0]
        is on ``$PATH``. Returns silently and stays NOT_STARTED if no
        candidate is installed — callers can show a hint via
        ``status_summary`` but shouldn't treat it as a hard error.

        On any spawn / send failure latches to FAILED so we don't keep
        retrying every frame.
        """
        if self.state != _STATE_NOT_STARTED:
            return
        var argv = self._pick_argv(spec)
        if len(argv) == 0:
            self._fail(String("no adapter on $PATH for ") + spec.name)
            return
        self.adapter_name = spec.name
        self.language_id = spec.language_id
        self._launch_request_kind = spec.request_kind
        # Stash a copy of the argv before transferring it into spawn —
        # diagnostic surfaces (the pane log, status summaries) read
        # this without disturbing the spawn machinery.
        var argv_copy = List[String]()
        for k in range(len(argv)):
            argv_copy.append(argv[k])
        self.spawn_argv = argv_copy^
        try:
            self.client = DapClient.spawn(argv)
        except e:
            self._fail(String("spawn failed: ") + String(e))
            return
        # Open the streaming trace log right after spawn. ``creat``
        # truncates so the file is fresh per session. Errors yield -1,
        # which keeps tracing disabled — never load-bearing.
        var trace_path = debug_log_path(String("turbokod-dap.log")) + String("\0")
        var tfd = external_call["creat", Int32](
            trace_path.unsafe_ptr(), Int32(0o644),
        )
        if Int(tfd) >= 0:
            self.client.process.own_trace_fd(tfd)
            var hdr = String("session start argv:")
            for k in range(len(self.spawn_argv)):
                hdr = hdr + String(" ") + self.spawn_argv[k]
            self.client.process.trace(hdr)
        var init_args = dap_initialize_arguments(
            String("turbokod"), spec.name,
        )
        try:
            self._inflight_initialize = self.client.send_request(
                String("initialize"), init_args,
            )
        except e:
            self._fail(String("initialize failed: ") + String(e))
            return
        # Stash the launch arguments to send on the initialize response.
        # We keep them as a JsonValue rather than re-deriving from spec
        # so the dispatch doesn't depend on the registry past start.
        self._pending_launch_args = launch_arguments_for(
            spec, program, cwd, program_args^, stop_on_entry, env,
        )
        self.state = _STATE_INITIALIZING
        self._state_entered_ms = monotonic_ms()
        self.client.process.trace(String("state -> initializing"))

    def _pick_argv(self, spec: DebuggerSpec) -> List[String]:
        """Return the first candidate whose argv[0] resolves on $PATH."""
        for i in range(len(spec.candidates)):
            var c = spec.candidates[i].copy()
            if len(c.argv) == 0:
                continue
            if len(which(c.argv[0]).as_bytes()) == 0:
                continue
            var out = List[String]()
            for k in range(len(c.argv)):
                out.append(c.argv[k])
            return out^
        return List[String]()

    def drain_stderr(mut self) -> String:
        """Read whatever's available on the adapter's stderr without
        blocking. Critical when the adapter dies mid-handshake — DAP
        offers no protocol-level signal for that, so the only way to
        know debugpy crashed importing its own modules (or lldb-dap
        complained about a missing dSYM) is to tail stderr."""
        if self.state == _STATE_NOT_STARTED:
            return String("")
        var text = self.client.process.drain_stderr()
        if len(text.as_bytes()) > 0:
            self.client.process.trace(
                String("stderr: ") + strip_trailing_newlines(text),
            )
            # Keep a persistent copy so the info window can show what
            # the adapter said even though this call has already drained
            # the OS pipe. Cap the buffer at 16 KB, keeping the tail —
            # the most recent output is what tells us why a session died.
            self._stderr_log.append(text)
        return text^

    def captured_stderr(self) -> String:
        """Everything ``drain_stderr`` has read from the adapter so far,
        capped at 16 KB. Surfaced in the DAP info window so the user can
        see what the adapter printed before the handshake failed."""
        return self._stderr_log.text


    def shutdown(mut self):
        """Best-effort: send ``disconnect`` if active, then terminate the
        child if alive. Idempotent."""
        if self.state == _STATE_NOT_STARTED:
            return
        if self.is_active():
            var args = json_object()
            args.put(String("terminateDebuggee"), json_bool(True))
            try:
                _ = self.client.send_request(String("disconnect"), args)
            except e:
                # Disconnect is best-effort; we ``terminate`` the
                # child unconditionally just below.
                print("dap: shutdown disconnect:", String(e))
        self.client.terminate()
        self.state = _STATE_TERMINATED
        # Clear pause-related latches. Without this, a session that
        # was paused at a breakpoint when shutdown ran would still
        # have ``_is_stopped`` set; while ``is_stopped()`` now gates
        # on ``is_active()`` so it reads False, code that pokes the
        # raw fields (e.g. ``status_summary``) still benefits from a
        # clean reset.
        self._is_stopped = False
        self._stop_in_subprocess = False
        self._last_stopped_thread_id = 0
        self._last_inspect_in_subprocess = False
        self._continued_pending = False
        self._oneshot_bp_path = String("")
        self._oneshot_bp_line = -1
        # Tear down any attached subprocess too — its socket points at
        # the parent debugpy we just terminated, so leaving it around
        # would just spew read-EOF noise.
        if self._subprocess.state != _STATE_NOT_STARTED \
                and self._subprocess.state != _STATE_TERMINATED:
            self._subprocess.client.terminate()
            self._subprocess.state = _STATE_TERMINATED

    def reset_for_restart(mut self):
        """Return to ``NOT_STARTED`` so ``start()`` can run again,
        preserving the persistent debugger configuration the user has
        accumulated this run.

        Kept across restarts:
          * Breakpoints (``_bps``)
          * Exception filter selection (``_exception_filters``)

        Their ``armed`` latch is reset — wait-for BPs need to re-observe their
        trigger fire before they go live in the new session.

        Everything else is transient handshake / event state that
        must not leak from one process spawn to the next: a stale
        ``_inflight_initialize`` would race the next handshake; a
        stale ``_pending_stack_ready`` would surface frames from the
        previous run; the dead ``client`` would let writes go to a
        closed pipe.

        Sibling to ``shutdown``, but it does not *depend* on having been
        preceded by one. It used to: the docstring told callers to
        ``shutdown`` first, and all four of them did the opposite —
        each gates on ``is_failed() or is_terminated()``, which is
        exactly where the ``if is_active(): shutdown()`` above it
        doesn't fire. And the child is very much alive in those states:
        a post-spawn ``initialize`` failure, an outbound-queue
        overflow, the 15 s watchdog and an ``initialize`` rejection all
        latch FAILED without touching the process, and the
        ``terminated`` event — the normal end of every session — latches
        TERMINATED while the adapter is still running. ``tick`` returns
        early in both states, so not even ``try_reap`` ran. Replacing
        ``client`` then stranded the pid, its three pipes and the trace
        fd for the life of the process: one leaked set per F5 → exit →
        F5 cycle, which is the ordinary debugging loop.

        So the teardown happens here instead of in a precondition.
        ``LspProcess.terminate`` is idempotent and closes the fds
        whether or not the child is still up, so a caller that *did*
        shutdown first pays nothing.
        """
        # Hand the old child's pid + fds back first: nothing else can reach
        # them once the manager is replaced. Same for a subprocess attach —
        # it holds a connected TCP socket (``LspProcess.from_socket``), and
        # because its ``pid`` is the ``-1`` socket-mode sentinel,
        # ``terminate`` is the only thing that ever closes it. ``shutdown``
        # tears both down too, but that's the call the restart paths skip.
        self.client.terminate()
        self._subprocess.client.terminate()
        # Everything transient goes back to what ``__init__`` builds — one
        # list of field defaults, where this used to be a third copy of it
        # that a new field had to be remembered in.
        var fresh = DapManager()
        swap(fresh._bps, self._bps)
        swap(fresh._exception_filters, self._exception_filters)
        swap(fresh._stderr_log, self._stderr_log)
        # Reset the per-session ``armed`` latches: dependent BPs go
        # back to "armed iff no wait-for". Without this a BP that was
        # armed by its trigger in run N would stay live in run N+1
        # before the trigger re-fires.
        for ref b in fresh._bps:
            b.armed = len(b.wait_for.as_bytes()) == 0
        self = fresh^

    # --- breakpoints -----------------------------------------------------

    def toggle_breakpoint(mut self, path: String, line: Int):
        """Add or remove an unconditional breakpoint at ``(path, line)``.

        Lines are 0-based here (matching ``Editor.cursor_row``); we add
        +1 on the wire because DAP's default is 1-based and we keep the
        adapter configured with ``linesStartAt1=false`` in
        ``initialize``... but adapters disagree on whether they honor
        that. lldb-dap respects the flag; debugpy ignores it and always
        expects 1-based. So we send 1-based unconditionally.
        """
        var found = self._bp_index(path, line)
        if found >= 0:
            _ = self._bps.pop(found)
        else:
            self._append_bp(path, line, String(""))
        self._push_breakpoints_for_path(path)

    def set_breakpoint_condition(
        mut self, path: String, line: Int, var condition: String,
    ):
        """Set the condition expression for the breakpoint at
        ``(path, line)``. Adds the breakpoint if it didn't exist; an
        empty ``condition`` clears any prior condition without removing
        the breakpoint (use ``toggle_breakpoint`` for removal)."""
        var found = self._bp_index(path, line)
        if found < 0:
            self._append_bp(path, line, condition^)
        else:
            self._bps[found].condition = condition^
        self._push_breakpoints_for_path(path)

    def set_breakpoint_enabled(
        mut self, path: String, line: Int, enabled: Bool,
    ):
        """Mark the breakpoint at ``(path, line)`` enabled or disabled.
        No-op when no BP exists at that location — toggling enable on
        a non-existent BP has no obvious meaning, and the right-click
        menu only opens over an existing dot anyway."""
        var i = self._bp_index(path, line)
        if i < 0 or self._bps[i].enabled == enabled:
            return
        self._bps[i].enabled = enabled
        self._push_breakpoints_for_path(path)

    def set_breakpoint_wait_for(
        mut self, path: String, line: Int, var wait_for: String,
    ):
        """Set (or clear) the trigger-BP key for the breakpoint at
        ``(path, line)``. ``wait_for`` is the ``"<path>:<1-based-line>"``
        identifier of the BP that must be hit first; empty clears the
        dependency. No-op when no BP exists at that location."""
        var i = self._bp_index(path, line)
        if i < 0 or self._bps[i].wait_for == wait_for:
            return
        # Re-derive ``armed``: empty wait-for is always armed; non-empty
        # starts disarmed (the trigger has to fire again before the BP
        # goes live).
        self._bps[i].armed = len(wait_for.as_bytes()) == 0
        self._bps[i].wait_for = wait_for^
        self._push_breakpoints_for_path(path)

    def breakpoint_wait_for(self, path: String, line: Int) -> String:
        """Wait-for trigger key at ``(path, line)``, or empty string
        when none / no BP exists."""
        var i = self._bp_index(path, line)
        return self._bps[i].wait_for if i >= 0 else String("")

    def arm_dependents(mut self, path: String, line: Int):
        """Mark every BP whose ``wait_for`` matches ``(path, line)`` as
        armed and re-push ``setBreakpoints`` for any newly-armed paths
        so the adapter starts honoring them.

        Called by the host after the program stops at ``(path, line)``
        — once the top stack frame resolves, this is the BP key the
        user thinks of as "the one that just hit". ``line`` is 0-based
        (matching ``DapStackFrame.line``); we convert to the 1-based
        wire form on comparison so the dropdown's stored values line
        up.

        No-op when no BP depends on this location.
        """
        var key = path + String(":") + String(line + 1)
        var changed_paths = List[String]()
        for ref b in self._bps:
            if b.wait_for != key or b.armed:
                continue
            b.armed = True
            if b.path not in changed_paths:
                changed_paths.append(b.path)
        for k in range(len(changed_paths)):
            self._push_breakpoints_for_path(changed_paths[k])

    def breakpoint_condition(self, path: String, line: Int) -> String:
        """Current condition for the breakpoint at ``(path, line)``,
        or empty string when none / unconditional."""
        var i = self._bp_index(path, line)
        return self._bps[i].condition if i >= 0 else String("")

    def breakpoint_enabled(self, path: String, line: Int) -> Bool:
        """Enable state at ``(path, line)``. Defaults to True (the
        most common case) so callers can use this in expressions
        without first probing ``has_breakpoint``."""
        var i = self._bp_index(path, line)
        return self._bps[i].enabled if i >= 0 else True

    def breakpoints_for(self, path: String) -> List[Int]:
        """Return a copy of the breakpoint lines for ``path``, 0-based.
        Includes disabled breakpoints — the gutter still draws them
        (in gray) so the user knows they're parked there."""
        var out = List[Int]()
        for ref b in self._bps:
            if b.path == path:
                out.append(b.line)
        return out^

    def fill_breakpoints_info(
        self, path: String, mut lines: List[Int], mut enabled: List[Bool],
        mut conditional: List[Bool],
    ):
        """Parallel ``(lines, enabled, conditional)`` for ``path``, into
        the caller's own lists. ``conditional`` is True when the BP has a
        non-empty condition. The editor uses these to color the gutter
        dot per row; filling the caller's lists keeps the per-frame
        gutter push from allocating three lists per open editor."""
        lines.clear()
        enabled.clear()
        conditional.clear()
        for ref b in self._bps:
            if b.path == path:
                lines.append(b.line)
                enabled.append(b.enabled)
                conditional.append(len(b.condition.as_bytes()) > 0)

    def breakpoints_fingerprint(self) -> UInt64:
        """A hash of the whole breakpoint set, computed without
        allocating — the per-frame "has it changed since the last save?"
        check."""
        var h = fnv_start()
        for ref b in self._bps:
            h = fnv_str(h, b.path)
            h = fnv_int(h, b.line)
            h = fnv_str(h, b.condition)
            h = fnv_int(h, 1 if b.enabled else 0)
            h = fnv_str(h, b.wait_for)
        return h

    def breakpoint_count(self) -> Int:
        return len(self._bps)

    def breakpoint_at(self, idx: Int) -> DapBreakpoint:
        return self._bps[idx]

    def stored_breakpoints(self) -> List[StoredBreakpoint]:
        """The breakpoint set as ``breakpoint_store`` persists it."""
        var out = List[StoredBreakpoint]()
        for ref b in self._bps:
            out.append(b.stored())
        return out^

    def restore_breakpoints(mut self, stored: List[StoredBreakpoint]):
        """Replace the in-memory breakpoint set wholesale, without
        sending any ``setBreakpoints`` to the adapter. Used at project
        setup to seed from the on-disk per-user file before the user
        starts a debug session — once they hit F5,
        ``_push_all_breakpoints`` ships the restored set during the
        CONFIGURING transition. ``armed`` is derived — empty ``wait_for``
        is always armed; non-empty starts disarmed until the trigger fires
        this session."""
        self._bps = List[DapBreakpoint]()
        for ref b in stored:
            self._bps.append(DapBreakpoint.from_stored(b))

    def has_breakpoint(self, path: String, line: Int) -> Bool:
        return self._bp_index(path, line) >= 0

    def _bp_index(self, path: String, line: Int) -> Int:
        """Index of the breakpoint at ``(path, line)`` in ``_bps``, or -1."""
        for i in range(len(self._bps)):
            if self._bps[i].path == path and self._bps[i].line == line:
                return i
        return -1

    def _append_bp(mut self, path: String, line: Int, var condition: String):
        """Add an enabled, armed, trigger-less breakpoint."""
        self._bps.append(
            DapBreakpoint(path, line, condition^, True, String(""), True),
        )

    def _distinct_breakpoint_paths(self) -> List[String]:
        """Unique source paths that currently hold a breakpoint."""
        return _bp_paths(self._bps)

    def _push_breakpoints_for_path(mut self, path: String):
        """Send ``setBreakpoints`` for ``path`` if the adapter is in a
        state that can accept it. No-op otherwise — once the session
        reaches CONFIGURING / RUNNING we resend everything in
        ``_push_all_breakpoints``."""
        if self.state != _STATE_RUNNING:
            return
        self._send_set_breakpoints(path)

    def _push_all_breakpoints(mut self):
        """Send the full breakpoint set, one ``setBreakpoints`` per
        distinct source. Called once during the CONFIGURING transition."""
        var paths = self._distinct_breakpoint_paths()
        for i in range(len(paths)):
            self._send_set_breakpoints(paths[i])

    def _send_set_breakpoints(mut self, path: String):
        var built = self._set_breakpoints_args(path)
        ref args = built[0]
        try:
            var seq = self.client.send_request(
                String("setBreakpoints"), args.copy(),
            )
            self._inflight_set_breakpoints.append(
                _InflightSetBreakpoints(seq, path, built[1].copy()),
            )
        except e:
            print("dap: setBreakpoints", path, ":", String(e))
        # Mirror to the attached subprocess if any — without this, a
        # breakpoint toggled after attach in shared code (a Django view
        # served from the forked child) wouldn't fire because only the
        # parent gets the update.
        if self._subprocess.state == _STATE_RUNNING \
                or self._subprocess.state == _STATE_CONFIGURING:
            try:
                _ = self._subprocess.client.send_request(
                    String("setBreakpoints"), args,
                )
            except e:
                print("dap: setBreakpoints (subprocess)", path, ":", String(e))

    def _set_breakpoints_args(self, path: String) -> Tuple[JsonValue, List[Int]]:
        """``setBreakpoints`` arguments for ``path`` — what the adapter
        should hold now (enabled, armed, plus a run-to-cursor oneshot) —
        and the line of each sent breakpoint in wire order (-1 for the
        oneshot), for the response demux. The parent session and a
        forked subprocess get the same set."""
        var args = json_object()
        var src = json_object()
        src.put(String("path"), json_str(realpath_or_self(path)))
        args.put(String("source"), src)
        var bps = json_array()
        var have_oneshot_match = False
        # Track which local indices we serialized for ``path``, in send
        # order, so the response demux can map ``breakpoints[i]`` back
        # to a ``(path, line)`` pair.
        var sent_lines = List[Int]()
        for ref b in self._bps:
            if b.path != path:
                continue
            # Disabled BPs stay in the local list (so the user keeps
            # their condition + the gutter still shows a faint dot)
            # but never reach the adapter. Skip without breaking the
            # response-line correlation — the index on the wire only
            # advances for BPs we actually send. A oneshot landing on a
            # disabled BP still fires: skipping here leaves
            # ``have_oneshot_match`` False, so the oneshot branch below
            # emits it.
            if not b.enabled:
                continue
            # Wait-for trigger gating: a BP that's enabled but waiting
            # on another BP is held back until ``arm_dependents`` flips
            # ``armed``. Same skip-but-no-correlation-break as
            # the disabled branch above. The oneshot ("run to cursor")
            # exception still applies — the user explicitly asked to
            # stop on this line, dependency or not.
            var is_oneshot = self._oneshot_bp_path == path \
                and b.line == self._oneshot_bp_line
            if not b.armed and not is_oneshot:
                continue
            bps.append(_bp_json(b))
            sent_lines.append(b.line)
            if is_oneshot:
                have_oneshot_match = True
        # "Run to cursor" oneshot: stitch into this path's BP list iff
        # the user doesn't already have a regular BP on the same line.
        # Cleared by ``_on_stopped_event`` (which then re-pushes).
        if self._oneshot_bp_path == path \
                and self._oneshot_bp_line >= 0 \
                and not have_oneshot_match:
            var bp = json_object()
            bp.put(String("line"), json_int(self._oneshot_bp_line + 1))
            bps.append(bp)
            # Oneshot has no local index — track with -1 so the
            # response demux skips it instead of misattributing.
            sent_lines.append(-1)
        args.put(String("breakpoints"), bps)
        args.put(String("sourceModified"), json_bool(False))
        return (args^, sent_lines^)

    # --- exception breakpoints --------------------------------------------

    def set_exception_filters(mut self, var filters: List[String]):
        """Replace the active exception filter set. Resends to the
        adapter immediately if the session is past CONFIGURING; queued
        otherwise, picked up during ``_do_configure``."""
        self._exception_filters = filters^
        if self.state == _STATE_RUNNING:
            self._send_set_exception_breakpoints()

    def exception_filters(self) -> List[String]:
        return self._exception_filters.copy()

    def _send_set_exception_breakpoints(mut self):
        try:
            _ = self.client.send_request(
                String("setExceptionBreakpoints"),
                _exception_breakpoints_args(self._exception_filters),
            )
        except e:
            print("dap: setExceptionBreakpoints:", String(e))

    # --- evaluate (watch / REPL) ------------------------------------------

    def request_evaluate(
        mut self, var expression: String, frame_id: Int,
        var context: String = String("watch"),
    ) -> Bool:
        """Issue an ``evaluate`` request. ``context`` is a hint to the
        adapter — ``"watch"`` for value-only display (no side effects
        ideally), ``"repl"`` for the user-typed REPL line, ``"hover"``
        for inline tooltips. Returns False if the session can't accept
        the request; the expression's value lands later via
        ``take_evaluations``.

        ``frame_id`` of 0 means "global" — most adapters interpret that
        as "use the current top frame", which is the right default
        when the caller hasn't yet picked a specific frame.

        Routes to the subprocess client when the most recent inspect
        was in a subprocess — frame ids are session-scoped, so a
        subprocess-issued frameId sent through the parent socket
        returns ``Wrong ID sent from the client``."""
        if not self.is_active():
            return False
        var args = _evaluate_args(expression, frame_id, context)
        var via_sub = self._inspect_via_subprocess()
        var seq = self._send_inspect(via_sub, String("evaluate"), args)
        if seq == 0:
            return False
        ref rq = self._requests(via_sub)
        rq.evals.append(_PendingEval(seq, expression^, context^, False))
        return True

    # --- completions (debug console) --------------------------------------

    def request_completions(
        mut self, var text: String, column: Int, frame_id: Int,
    ) -> Bool:
        """Ask the adapter what could complete ``text`` at ``column``
        (0-based UTF-16 offset of the cursor). Only one request is kept in
        flight — a newer one replaces the older (its late answer is
        dropped) — since only the latest keystroke's answer matters. The
        result lands via ``take_completions``. Routes like ``evaluate``."""
        if not self.is_active() or not self._supports_completions:
            return False
        var args = json_object()
        args.put(String("text"), json_str(text))
        # Columns are 1-based on the wire (we never send columnsStartAt1).
        args.put(String("column"), json_int(column + 1))
        if frame_id != 0:
            args.put(String("frameId"), json_int(frame_id))
        var via_sub = self._inspect_via_subprocess()
        var seq = self._send_inspect(via_sub, String("completions"), args)
        if seq == 0:
            return False
        self._requests(via_sub).completions = seq
        self._completions_req_text = text^
        self._completions_req_column = column
        return True

    def has_completions(self) -> Bool:
        return self._completions_ready

    def take_completions(mut self) -> Tuple[String, Int, List[DapCompletion]]:
        """Drain the newest completions answer as ``(text, column,
        targets)`` — the request text/column it answers, then the
        targets."""
        self._completions_ready = False
        var items = self._completions^
        self._completions = List[DapCompletion]()
        return (self._completions_text, self._completions_column, items^)

    def _stash_completions(mut self, msg: DapIncoming):
        self._completions = _parse_completions(msg.body) \
            if msg.ok() else List[DapCompletion]()
        self._completions_text = self._completions_req_text
        self._completions_column = self._completions_req_column
        self._completions_ready = True

    def request_container_keys(mut self, var expr: String, frame_id: Int) -> Bool:
        """Start fetching the keys of the container ``expr`` evaluates to:
        ``evaluate`` it, then (on the answer) ``variables`` on its
        reference. The keys land via ``take_container_keys``. Like
        completions, only the newest request is answered."""
        if not self.is_active():
            return False
        self._keys_req_expr = expr.copy()
        self._keys_frame_id = frame_id
        self._keys_stage = 0
        self._keys_via_sub = self._inspect_via_subprocess()
        return self._send_keys_eval(expr^)

    def _send_keys_eval(mut self, var expr: String) -> Bool:
        var args = _evaluate_args(expr, self._keys_frame_id, String("watch"))
        var seq = self._send_inspect(
            self._keys_via_sub, String("evaluate"), args,
        )
        if seq == 0:
            return False
        self._requests(self._keys_via_sub).keys_eval = seq
        return True

    def has_container_keys(self) -> Bool:
        return self._keys_ready

    def take_container_keys(mut self) -> Tuple[String, List[String]]:
        """``(expr, keys)`` — key reprs as the adapter names them."""
        self._keys_ready = False
        var k = self._keys^
        self._keys = List[String]()
        return (self._keys_expr, k^)

    def _on_keys_eval(mut self, msg: DapIncoming):
        """Container evaluated: ask for its children, or give up (no
        children → nothing to offer)."""
        var var_ref = 0
        if msg.ok() and msg.body and msg.body.value().is_object():
            var_ref = json_get_int(
                msg.body.value(), String("variablesReference"), var_ref,
            )
        if var_ref <= 0:
            self._finish_keys(List[String]())
            return
        var args = json_object()
        args.put(String("variablesReference"), json_int(var_ref))
        var seq = self._send_inspect(
            self._keys_via_sub, String("variables"), args,
        )
        if seq == 0:
            self._finish_keys(List[String]())
            return
        self._requests(self._keys_via_sub).keys_vars = seq

    def _on_keys_vars(mut self, msg: DapIncoming):
        var keys = List[String]()
        if msg.ok():
            var vars = _parse_variables(msg.body)
            for i in range(len(vars)):
                if self._keys_stage == 0:
                    if _is_key_name(vars[i].name):
                        keys.append(vars[i].name)
                elif _is_index_name(vars[i].name):
                    # Fallback list: element values are the key reprs.
                    keys.append(vars[i].value)
        # Nothing keyed among the children: a dict-like that isn't a dict
        # (Django's ``request.session``, a ``UserDict`` wrapper, …) lists
        # its attributes there instead. In Python, ask it for its keys.
        if len(keys) == 0 and self._keys_stage == 0 \
                and self.language_id == String("python"):
            self._keys_stage = 1
            if self._send_keys_eval(
                String("list((") + self._keys_req_expr + String(").keys())")
            ):
                return
        self._finish_keys(keys^)

    def _finish_keys(mut self, var keys: List[String]):
        self._keys = keys^
        self._keys_expr = self._keys_req_expr
        self._keys_ready = True

    def has_evaluations(self) -> Bool:
        return len(self._evaluations) > 0

    def take_evaluations(mut self) -> List[DapEvaluation]:
        """Drain the buffered evaluate responses.

        Empty types are common for adapters that don't return ``type``
        on plain identifier lookups."""
        var out = List[DapEvaluation]()
        swap(out, self._evaluations)
        return out^

    # --- execution control -----------------------------------------------

    def cont(mut self) -> Bool:
        """``continue`` is a Mojo keyword — hence ``cont``. Resumes the
        thread reported in the most recent ``stopped`` event, or thread
        1 as a fallback. Returns False if no session is active."""
        return self._send_thread_command(String("continue"))

    def next(mut self) -> Bool:
        """Step over (one source line, no descent into calls)."""
        return self._send_thread_command(String("next"))

    def step_in(mut self) -> Bool:
        return self._send_thread_command(String("stepIn"))

    def step_out(mut self) -> Bool:
        return self._send_thread_command(String("stepOut"))

    def pause(mut self) -> Bool:
        return self._send_thread_command(String("pause"))

    def run_to_cursor(mut self, path: String, line: Int) -> Bool:
        """Resume execution and stop again at ``(path, line)``.

        DAP has no native one-shot breakpoint, so we plant a transient
        BP at the cursor (via the oneshot fields), push the augmented
        BP list, then send ``continue``. The next ``stopped`` event —
        whether at our line or at an earlier real BP — clears the
        oneshot and re-pushes ``setBreakpoints`` so the cursor BP
        doesn't linger past one stop.

        No-op unless we're currently paused; "resume from where" is
        ambiguous otherwise. Returns False on no-op.
        """
        if not self.is_active() or not self._is_stopped:
            return False
        if line < 0 or len(path.as_bytes()) == 0:
            return False
        self._oneshot_bp_path = path
        self._oneshot_bp_line = line
        self._push_breakpoints_for_path(path)
        return self._send_thread_command(String("continue"))

    def _send_thread_command(mut self, command: String) -> Bool:
        if not self.is_active():
            return False
        # Prefer the sticky thread id over the unread ``_stopped`` event:
        # the host's auto-stack hook calls ``take_stopped`` every tick, so
        # by the time the user clicks Step Over ``_stopped`` is empty and
        # falling back to ``threadId: 1`` makes pydevd step a thread that
        # isn't paused — which it interprets as "continue all".
        var tid = 1
        if self._last_stopped_thread_id != 0:
            tid = self._last_stopped_thread_id
        elif self._stopped:
            tid = self._stopped.value().thread_id
        var args = json_object()
        args.put(String("threadId"), json_int(tid))
        try:
            if self._stop_in_subprocess \
                    and self._subprocess.state == _STATE_RUNNING:
                _ = self._subprocess.client.send_request(command, args)
            else:
                _ = self.client.send_request(command, args)
        except:
            return False
        # Optimistic — adapter will send a ``continued`` event back which
        # clears ``_is_stopped``. We don't wait for the response here.
        return True

    # --- async data fetches ----------------------------------------------

    def request_stack_trace(mut self, thread_id: Int, levels: Int = 64) -> Bool:
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("threadId"), json_int(thread_id))
        args.put(String("startFrame"), json_int(0))
        args.put(String("levels"), json_int(levels))
        # ``includeAll`` overrides the adapter's default of hiding
        # "external" frames. For adapters that mark library frames
        # subtle (lldb-dap, delve) this is sufficient — we still get
        # the frames, just flagged so the UI can dim them. debugpy
        # *additionally* needs ``justMyCode: false`` in the launch
        # config to expose stdlib / site-packages frames at all; with
        # ``justMyCode: true`` it drops them server-side regardless of
        # this flag. See ``_build_debugpy_launch_args``.
        var fmt = json_object()
        fmt.put(String("includeAll"), json_bool(True))
        args.put(String("format"), fmt)
        # Route to the subprocess when the latched stop came from there.
        # We can't read ``self._stopped.from_subprocess`` here because
        # ``take_stopped`` typically runs *just before* this — the host's
        # auto-stack hook does ``take_stopped → request_stack_trace`` on
        # the same tick, and ``take_stopped`` empties ``_stopped``. The
        # sticky ``_stop_in_subprocess`` mirror survives the take.
        # Frame ids in the response are scoped to the answering pydevd,
        # so ``_last_inspect_in_subprocess`` records which session owns
        # them — ``request_scopes`` / ``request_variables`` follow the
        # same routing on the next click.
        var via_sub = self._stop_in_subprocess \
            and self._subprocess.state == _STATE_RUNNING
        var seq = self._send_inspect(via_sub, String("stackTrace"), args)
        if seq == 0:
            return False
        self._requests(via_sub).stack_trace = seq
        self._last_inspect_in_subprocess = via_sub
        return True

    def request_scopes(mut self, frame_id: Int) -> Bool:
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("frameId"), json_int(frame_id))
        var via_sub = self._inspect_via_subprocess()
        var seq = self._send_inspect(via_sub, String("scopes"), args)
        if seq == 0:
            return False
        self._requests(via_sub).scopes = seq
        return True

    def request_variables(mut self, variables_reference: Int) -> Bool:
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("variablesReference"), json_int(variables_reference))
        var via_sub = self._inspect_via_subprocess()
        var seq = self._send_inspect(via_sub, String("variables"), args)
        if seq == 0:
            return False
        self._requests(via_sub).variables = seq
        return True

    # --- pending-event accessors -----------------------------------------

    def take_stopped(mut self) -> Optional[DapStopped]:
        """Pop the most recent ``stopped`` event. The ``_is_stopped``
        flag stays true until execution resumes (``continued`` event)
        — UI surfaces (gutter caret, stack pane) consult it."""
        var out = self._stopped
        self._stopped = Optional[DapStopped]()
        return out

    def take_outputs(mut self) -> List[DapOutput]:
        """Drain all buffered ``output`` events."""
        var out = self._output_events^
        self._output_events = List[DapOutput]()
        return out^

    def consume_terminated(mut self) -> Bool:
        """Returns True iff a ``terminated`` event has fired since the
        last call. Used by the host to fold up the debug pane."""
        if self._terminated_pending:
            self._terminated_pending = False
            return True
        return False

    def consume_continued(mut self) -> Bool:
        """Returns True iff a ``continued`` event has fired since the
        last call. Host uses this to wipe stack/locals/watches while
        the program is running again — those rows hold ids tied to
        the prior stop, so clicking them after resume would request
        scopes/variables for stale frame ids and surface errors."""
        if self._continued_pending:
            self._continued_pending = False
            return True
        return False

    def has_stack(self) -> Bool:
        return self._pending_stack_ready

    def take_stack(mut self) -> List[DapStackFrame]:
        var out = self._pending_stack^
        self._pending_stack = List[DapStackFrame]()
        self._pending_stack_ready = False
        return out^

    def has_scopes(self) -> Bool:
        return self._pending_scopes_ready

    def take_scopes(mut self) -> List[DapScope]:
        var out = self._pending_scopes^
        self._pending_scopes = List[DapScope]()
        self._pending_scopes_ready = False
        return out^

    def has_variables(self) -> Bool:
        return self._pending_vars_ready

    def take_variables(mut self) -> List[DapVariable]:
        var out = self._pending_vars^
        self._pending_vars = List[DapVariable]()
        self._pending_vars_ready = False
        return out^

    # --- frame-tick driver -----------------------------------------------

    def tick(mut self):
        """Drive the state machine one step.

        Drains every framed message currently available, advancing the
        handshake and parking events / async-response data for the host
        to consume via ``take_*`` accessors. Also detects when the
        adapter died without sending ``terminated`` first — DAP offers
        no protocol-level signal for "I crashed", so we have to poll
        the child via ``waitpid``.
        """
        if self.state == _STATE_NOT_STARTED \
                or self.state == _STATE_FAILED \
                or self.state == _STATE_TERMINATED:
            return
        # Continue draining the outbound queue. ``write_message``
        # now never blocks — whatever the kernel didn't accept in
        # one shot is parked here and flushed on subsequent ticks.
        self.client.process.pump_writes()
        if self.client.process.write_overflowed():
            self._fail(String(
                "outbound queue overflowed (adapter not reading stdin)"
            ))
            return
        # Crash-detection: ``try_reap`` returns True iff the child has
        # exited. While the session is supposed to be live, that means
        # the adapter crashed — most often because the python it was
        # spawned under doesn't have debugpy on its sys.path. Latch
        # FAILED so the UI shows a real error instead of an indefinite
        # ``initializing`` spinner.
        if self.client.process.try_reap():
            self._fail(String("adapter exited before completing handshake"))
            return
        # Heartbeat. Once per second while alive — short enough that
        # a crash anywhere in the host loop is visible within a frame
        # of the last good tick, long enough that a normal session
        # doesn't flood the log. ``buf`` reflects the framer's pending
        # bytes so a partial response (the prior 140 B variables-stall
        # case) is obvious.
        var now = monotonic_ms()
        if now - self._last_heartbeat_ms >= 1000:
            self._last_heartbeat_ms = now
            self.client.process.trace(
                String("heartbeat state=") + _state_name(self.state)
                + String(" buf=")
                + String(len(self.client.process._read_buffer))
                + String("B")
            )
        # Watchdog: if we've been in INITIALIZING / LAUNCHING /
        # CONFIGURING for more than 15 s without forward progress,
        # something is wrong with the adapter (debugpy buffering its
        # response, lldb-dap waiting on a missing symbol server, etc.)
        # and the user is better served by a FAILED state than by an
        # indefinite spinner.
        if self.state == _STATE_INITIALIZING \
                or self.state == _STATE_LAUNCHING \
                or self.state == _STATE_CONFIGURING:
            var elapsed = monotonic_ms() - self._state_entered_ms
            if elapsed > 15000:
                var prior = _state_name(self.state)
                self._fail(String("adapter unresponsive for 15s in ") + prior)
                return
        var i = 0
        while i < 32:
            i += 1
            var maybe: Optional[DapIncoming]
            try:
                maybe = self.client.poll(Int32(0))
            except:
                return
            if not maybe:
                break
            var msg = maybe.take()
            if msg.kind == DAP_EVENT:
                self._handle_event(msg)
            elif msg.kind == DAP_RESPONSE:
                self._handle_response(msg)
            else:
                # Reverse request (runInTerminal / startDebugging). We
                # advertised non-support in ``initialize``, so adapters
                # shouldn't send these — answer with success=false if
                # one slips through, just to keep their state machine
                # unstuck.
                self._handle_reverse_request(msg)
        # Drive any subprocess attach session forward in the same tick.
        # Sits after parent processing so a ``debugpyAttach`` event handled
        # this tick gets its initialize sent before we poll the new socket.
        self._tick_subprocess()

    def _tick_subprocess(mut self):
        """Pump messages between turbokod and one attached subprocess.

        Runs entirely independently of the parent state machine: the
        subprocess has its own socket-backed ``DapClient`` and its own
        initialize → attach → setBreakpoints → configurationDone
        handshake. We forward its ``output`` events into the parent's
        output buffer so the user sees one merged log; ``stopped`` and
        ``terminated`` events route to the same surfaced fields, since
        the UI is single-session for now.
        """
        if self._subprocess.state == _STATE_NOT_STARTED \
                or self._subprocess.state == _STATE_TERMINATED \
                or self._subprocess.state == _STATE_FAILED:
            return
        var j = 0
        while j < 32:
            j += 1
            var maybe: Optional[DapIncoming]
            try:
                maybe = self._subprocess.client.poll(Int32(0))
            except:
                # Close the socket, don't just latch FAILED. This was the
                # one failure transition that skipped ``terminate`` — and
                # the slot is *reusable* at FAILED, so the next
                # ``debugpyAttach`` overwrote ``client`` and made the fd
                # unreachable. (``shutdown`` does terminate a FAILED
                # subprocess, so the descriptor was only lost when a
                # re-attach came first.)
                self._subprocess.client.terminate()
                self._subprocess.state = _STATE_FAILED
                return
            if not maybe:
                break
            var msg = maybe.take()
            self._handle_subprocess_message(msg)

    def _handle_subprocess_message(mut self, msg: DapIncoming):
        if msg.kind == DAP_EVENT:
            if not msg.event:
                return
            var event = msg.event.value()
            if event == String("initialized"):
                self._subprocess.got_initialized_event = True
                if self._subprocess.state == _STATE_LAUNCHING:
                    self._subprocess_configure()
                return
            if event == String("output"):
                # Merge into the parent output channel so the user sees
                # subprocess prints in the same Output panel.
                self._on_output_event(msg)
                return
            if event == String("terminated"):
                self._subprocess.state = _STATE_TERMINATED
                self._subprocess.client.terminate()
                return
            if event == String("exited"):
                return
            if event == String("stopped"):
                # Surface in parent UI. The ``from_subprocess=True`` flag
                # routes follow-up stackTrace/scopes/variables/continue
                # to the subprocess client — its thread/frame/varRef
                # ids are scoped to its own pydevd translation table.
                self._on_stopped_event(msg, True)
                return
            if event == String("continued"):
                # Mirror the parent's continued handling. Without this
                # the inspect view stays stuck "stopped" after a
                # ``continue`` we sent into the subprocess.
                self._on_continued_event()
                return
            return
        if msg.kind == DAP_RESPONSE:
            if not msg.request_seq:
                return
            var rseq = msg.request_seq.value()
            if rseq == self._subprocess.inflight_initialize:
                self._subprocess.inflight_initialize = 0
                var sub_init_ok = msg.ok()
                if not sub_init_ok:
                    self._fail_subprocess()
                    return
                # Now send attach with the args debugpy gave us.
                try:
                    self._subprocess.inflight_attach = \
                        self._subprocess.client.send_request(
                            String("attach"),
                            self._subprocess.pending_attach_args,
                        )
                except:
                    self._fail_subprocess()
                    return
                self._subprocess.state = _STATE_LAUNCHING
                if self._subprocess.got_initialized_event:
                    self._subprocess_configure()
                return
            if rseq == self._subprocess.inflight_attach:
                self._subprocess.inflight_attach = 0
                var sub_att_ok = msg.ok()
                if not sub_att_ok:
                    self._fail_subprocess()
                return
            if rseq == self._subprocess.inflight_config_done:
                self._subprocess.inflight_config_done = 0
                var sub_cfg_ok = msg.ok()
                if not sub_cfg_ok:
                    self._fail_subprocess()
                    return
                self._subprocess.state = _STATE_RUNNING
                return
            _ = self._on_inspect_answer(self._subprocess.rq.claim(rseq), msg)
            return
        # Reverse requests: answer not-supported so the subprocess
        # debugpy isn't blocked.
        if msg.command:
            try:
                self._subprocess.client.send_response(
                    msg.seq, msg.command.value(), False, json_object(),
                )
            except e:
                print("dap: subprocess reverse-request not-supported reply:", String(e))

    def _inspect_via_subprocess(self) -> Bool:
        """Route evaluate / variables requests to the forked-subprocess
        session: the last stop's frames live there and it's still up."""
        return self._last_inspect_in_subprocess \
            and self._subprocess.state == _STATE_RUNNING

    def _fail_subprocess(mut self):
        """Give up on the forked-subprocess session: mark it failed and
        drop its connection."""
        self._subprocess.state = _STATE_FAILED
        self._subprocess.client.terminate()

    def _subprocess_configure(mut self):
        """Push breakpoints + exception filters, then ``configurationDone``."""
        # Subprocess attach is debugpy-only (the ``debugpyAttach`` event
        # that opens this socket is a debugpy extension), so the same
        # condition-exception override the parent does applies here too.
        try:
            _ = self._subprocess.client.send_request(
                String("setDebuggerProperty"), _debugpy_condition_property_args(),
            )
        except e:
            print("dap: subprocess setDebuggerProperty:", String(e))
        # setBreakpoints per source path: the parent's set as it stands
        # now (wait-for gating and all) — a breakpoint set in shared code
        # (a Django view served from the forked child) has to fire here.
        var paths = self._distinct_breakpoint_paths()
        for i in range(len(paths)):
            var built = self._set_breakpoints_args(paths[i])
            try:
                _ = self._subprocess.client.send_request(
                    String("setBreakpoints"), built[0],
                )
            except e:
                print("dap: subprocess _configure setBreakpoints", paths[i], ":", String(e))
        # setExceptionBreakpoints — same defaults as parent.
        try:
            _ = self._subprocess.client.send_request(
                String("setExceptionBreakpoints"),
                _exception_breakpoints_args(self._exception_filters),
            )
        except e:
            print("dap: subprocess _configure setExceptionBreakpoints:", String(e))
        try:
            self._subprocess.inflight_config_done = \
                self._subprocess.client.send_request(
                    String("configurationDone"), json_object(),
                )
        except:
            self._fail_subprocess()
            return
        self._subprocess.state = _STATE_CONFIGURING

    # --- event / response handlers ---------------------------------------

    def _handle_event(mut self, msg: DapIncoming):
        if not msg.event:
            return
        var event = msg.event.value()
        if event == String("initialized"):
            self._got_initialized_event = True
            self._on_initialized_event()
            return
        if event == String("stopped"):
            self._on_stopped_event(msg, False)
            return
        if event == String("continued"):
            self._on_continued_event()
            return
        if event == String("terminated"):
            self._terminated_pending = True
            self.state = _STATE_TERMINATED
            return
        if event == String("exited"):
            # ``exited`` fires when the debuggee exits but the adapter
            # may stay alive for postmortem inspection. We don't act —
            # ``terminated`` is the authoritative end-of-session signal.
            return
        if event == String("output"):
            self._on_output_event(msg)
            return
        if event == String("debugpyAttach"):
            self._on_debugpy_attach_event(msg)
            return
        # ``thread``, ``module``, ``loadedSource``, ``breakpoint``,
        # ``capabilities``, ``progress*`` — unhandled, silently dropped.

    def _handle_response(mut self, msg: DapIncoming):
        if not msg.request_seq:
            return
        var rseq = msg.request_seq.value()
        if rseq == self._inflight_initialize:
            self._on_initialize_response(msg)
            self._inflight_initialize = 0
            return
        if rseq == self._inflight_launch:
            self._on_launch_response(msg)
            self._inflight_launch = 0
            return
        if rseq == self._inflight_config_done:
            self._on_config_done_response(msg)
            self._inflight_config_done = 0
            return
        if self._on_inspect_answer(self._rq.claim(rseq), msg):
            return
        # ``setBreakpoints`` response: per-BP verified flag + optional
        # message. We only surface the negative case — a verified=false
        # entry with a message is how debugpy reports a syntactically
        # invalid ``condition``, and that's the trigger for the
        # condition-fix dialog.
        var sidx = -1
        for k in range(len(self._inflight_set_breakpoints)):
            if self._inflight_set_breakpoints[k].seq == rseq:
                sidx = k
                break
        if sidx >= 0:
            self._on_set_breakpoints_response(sidx, msg)
            return

    def _handle_reverse_request(mut self, msg: DapIncoming):
        if not msg.command:
            return
        try:
            self.client.send_response(
                msg.seq, msg.command.value(), False, json_object(),
            )
        except e:
            print("dap: reverse-request not-supported reply:", String(e))

    def _on_initialize_response(mut self, msg: DapIncoming):
        # Entry trace: when a session goes FAILED here, the only previous
        # signal in the log is the silence after a ``< response`` line.
        # Stamping the parsed success/message at the head of the handler
        # turns "no follow-up" into "we saw success=X" so the cause is
        # legible without re-deriving from the raw bytes.
        var succ_str: String
        if msg.success:
            succ_str = String("True") if msg.success.value() else String("False")
        else:
            succ_str = String("(missing)")
        var msg_str = msg.message.value() if msg.message else String("")
        self.client.process.trace(
            String("initialize response success=") + succ_str
            + String(" message=\"") + msg_str + String("\"")
        )
        # ``if msg.success and not msg.success.value():`` looks right
        # but evaluates to True when ``.value()`` is True under this
        # Mojo build — observed in a /tmp/turbokod-dap.log where the
        # entry-trace printed ``success=True`` and the next line was
        # ``FAIL: initialize rejected``. Split into two statements so
        # the boolean check is unambiguous.
        var success_ok = msg.ok()
        if not success_ok:
            self._fail_rejected(String("initialize"), msg)
            return
        # Park capabilities. Only the few we actually use.
        if msg.body and msg.body.value().is_object():
            ref b = msg.body.value()
            self._supports_configuration_done = json_get_bool(
                b, String("supportsConfigurationDoneRequest"),
                self._supports_configuration_done,
            )
            self._supports_terminate_request = json_get_bool(
                b, String("supportsTerminateRequest"), self._supports_terminate_request,
            )
            self._supports_completions = json_get_bool(
                b, String("supportsCompletionsRequest"), self._supports_completions,
            )
        # Now send launch / attach.
        var cmd: String
        if self._launch_request_kind == DAP_REQUEST_ATTACH:
            cmd = String("attach")
        else:
            cmd = String("launch")
        try:
            self._inflight_launch = self.client.send_request(
                cmd, self._pending_launch_args,
            )
        except e:
            self._fail(String("launch failed: ") + String(e))
            return
        self.state = _STATE_LAUNCHING
        self._state_entered_ms = monotonic_ms()
        self.client.process.trace(String("state -> launching"))
        # If ``initialized`` already arrived (rare but spec-legal), kick
        # the configuration step now.
        if self._got_initialized_event:
            self._do_configure()

    def _on_initialized_event(mut self):
        # Only meaningful once we've moved past INITIALIZING — if it
        # arrives during INITIALIZING (some adapters send it eagerly),
        # we'll act on it after the launch request goes out.
        if self.state == _STATE_LAUNCHING:
            self._do_configure()

    def _on_set_breakpoints_response(mut self, idx: Int, msg: DapIncoming):
        """Demux a ``setBreakpoints`` response: pop the inflight slot,
        then walk the response's ``breakpoints`` array against the live
        local list (filtered by enabled-state to mirror what we sent).
        Any ``verified == false`` entry produces a ``DapBreakpointError``
        for the host to surface."""
        # The exact lines sent with THIS request (adapter array order),
        # captured at send time. A ``-1`` entry is the oneshot "run to
        # cursor" row (no user-visible BP).
        var sent = self._inflight_set_breakpoints.pop(idx)
        var path = sent.path
        var sent_lines = sent.lines.copy()
        if not msg.body or not msg.body.value().is_object():
            return
        ref b = msg.body.value()
        var at = b.object_index(String("breakpoints"))
        if at < 0 or not b.obj_v[at].value.is_array():
            return
        ref arr = b.obj_v[at].value.arr_v
        for i in range(len(arr)):
            ref entry = arr[i]
            if not entry.is_object():
                continue
            var vi = entry.object_index(String("verified"))
            if vi < 0 or not entry.obj_v[vi].value.is_bool():
                continue
            if entry.obj_v[vi].value.as_bool():
                continue
            var msg_text = json_get_string(entry, String("message"))
            if i >= len(sent_lines):
                continue
            var line = sent_lines[i]
            if line < 0:
                # Oneshot — not the user's BP, no dialog.
                continue
            if len(msg_text.as_bytes()) == 0:
                # Adapters sometimes send verified=false with no message
                # for breakpoints in modules that aren't loaded yet —
                # that's not a user error and we shouldn't pop a dialog.
                continue
            self._bp_errors.append(
                DapBreakpointError(path, line, msg_text^),
            )

    def take_breakpoint_errors(mut self) -> List[DapBreakpointError]:
        """Drain any ``setBreakpoints`` rejections since the last call.
        Empty list when nothing's wrong."""
        var out = self._bp_errors^
        self._bp_errors = List[DapBreakpointError]()
        return out^

    def has_breakpoint_errors(self) -> Bool:
        return len(self._bp_errors) > 0

    def has_inflight_set_breakpoints(self) -> Bool:
        """True while at least one ``setBreakpoints`` request is still
        waiting on a response. The condition-error dialog uses this to
        tell "the adapter hasn't answered yet" from "the adapter
        accepted the new condition" — only the latter is a cue to
        close the dialog."""
        return len(self._inflight_set_breakpoints) > 0

    def _on_inspect_answer(
        mut self, answer: _InspectAnswer, msg: DapIncoming,
    ) -> Bool:
        """Park an inspect response from either session (``answer`` says
        which request it was) where the host reads it. False when it
        answered none of them."""
        var k = answer.kind
        if k == _ANS_STACK:
            self._pending_stack = _parse_stack_trace(msg.body)
            self._pending_stack_ready = True
        elif k == _ANS_SCOPES:
            self._pending_scopes = _parse_scopes(msg.body)
            self._pending_scopes_ready = True
        elif k == _ANS_VARIABLES:
            self._pending_vars = _parse_variables(msg.body)
            self._pending_vars_ready = True
        elif k == _ANS_COMPLETIONS:
            self._stash_completions(msg)
        elif k == _ANS_KEYS_EVAL:
            self._on_keys_eval(msg)
        elif k == _ANS_KEYS_VARS:
            self._on_keys_vars(msg)
        elif k == _ANS_EVALUATE:
            self._stash_evaluate_result(
                answer.expr.copy(), answer.context.copy(), msg,
            )
        elif k == _ANS_TEST_EVALUATE:
            # Its own buffer, so the watch fold doesn't swallow it.
            self._stash_test_evaluate_result(answer.expr.copy(), msg)
        else:
            return False
        return True

    def _requests(
        mut self, via_sub: Bool,
    ) -> ref[self._rq, self._subprocess.rq] _InspectRequests:
        """The in-flight table of the session an inspect request goes to."""
        if via_sub:
            return self._subprocess.rq
        return self._rq

    def _send_inspect(
        mut self, via_sub: Bool, command: String, args: JsonValue,
    ) -> Int:
        """Send an inspect request on the session that owns its frame ids
        (``via_sub``: the forked subprocess). Its seq, or 0 if it failed."""
        try:
            if via_sub:
                return self._subprocess.client.send_request(command, args)
            return self.client.send_request(command, args)
        except:
            return 0

    def _stash_evaluate_result(
        mut self, var expr: String, var context: String, msg: DapIncoming,
    ):
        """Append one parsed ``evaluate`` result to the watch/REPL
        result buffers. Shared between parent and subprocess paths so
        both surface identically to the host. ``context`` is the
        request-time hint, carried through so the host can route REPL
        console results apart from watch folds."""
        var r = _evaluate_result(msg)
        var value = r[0]
        var eval_ok = msg.ok()
        if not eval_ok:
            # Error response — surface the message as the value so the
            # watch row reads ``len(items) = <error>`` rather than
            # going stale or vanishing.
            value = String("<error: ") + msg.message.value() + String(">") \
                if msg.message else String("<error>")
        var type_name = r[1]
        self._evaluations.append(DapEvaluation(
            expr^, value^, type_name^, context^, not eval_ok,
        ))

    # --- condition-exception buffer & test-evaluate channel --------------

    def _maybe_capture_condition_exception(mut self, text: String) -> Bool:
        """Detect pydevd's ``Error while evaluating expression in
        conditional breakpoint`` notice and stash the parsed condition
        + short error so ``take_condition_exception`` can surface it on
        the matching ``stopped`` event. Returns True on a match.

        Idempotent: a later match overwrites the buffer, which is fine
        because the matching ``stopped`` event arrives right after and
        the host drains both atomically — a stale buffer would only
        survive a tick where pydevd printed the message but never got
        to suspend, which doesn't happen for any normal flow."""
        var prefix = String(
            "pydevd: Error while evaluating expression in conditional breakpoint: "
        )
        if not starts_with(text, prefix):
            return False
        var b = text.as_bytes()
        var p = len(prefix.as_bytes())
        var nl = -1
        var i = p
        while i < len(b):
            if b[i] == 0x0A:
                nl = i
                break
            i += 1
        var condition: String
        var traceback: String
        if nl < 0:
            condition = String(StringSpan(unsafe_from_utf8=b[p:]))
            traceback = String("")
        else:
            condition = String(StringSpan(unsafe_from_utf8=b[p:nl]))
            traceback = String(StringSpan(unsafe_from_utf8=b[nl + 1:]))
        var short_error = _last_nonempty_line(traceback)
        if len(short_error.as_bytes()) == 0:
            short_error = String("evaluation failed")
        self._pending_cond_exc_condition = condition^
        self._pending_cond_exc_error = short_error^
        return True

    def has_condition_exception(self) -> Bool:
        return len(self._pending_cond_exc_condition.as_bytes()) > 0

    def take_condition_exception(mut self) -> Optional[DapConditionException]:
        """Drain the most recent runtime condition-exception buffer.
        Returns ``None`` when nothing's pending. The host calls this
        once per tick after handling the surfaced ``stopped`` event;
        the dialog opens iff this returns a value."""
        if len(self._pending_cond_exc_condition.as_bytes()) == 0:
            return Optional[DapConditionException]()
        var c = self._pending_cond_exc_condition^
        var e = self._pending_cond_exc_error^
        self._pending_cond_exc_condition = String("")
        self._pending_cond_exc_error = String("")
        return Optional[DapConditionException](
            DapConditionException(c^, e^),
        )

    def request_test_evaluate(
        mut self, var expression: String, frame_id: Int,
    ) -> Bool:
        """Issue an ``evaluate`` whose result lands in the test-eval
        channel rather than the watch/REPL channel. Used by the
        condition-error dialog to validate an edited expression
        against the live frame before committing it as the new BP
        condition. Returns False if no session is active.

        The ``context`` is ``"watch"`` so adapters that distinguish
        side-effect-free from REPL evaluations stay on the cautious
        side — testing a condition shouldn't mutate state.

        Routes to the subprocess client when the most recent inspect
        was in a subprocess (same reason as ``request_evaluate``: the
        ``frame_id`` is session-scoped to whichever pydevd issued it,
        and parent vs subprocess have independent seq counters which
        forces per-channel inflight tables to avoid collision)."""
        if not self.is_active():
            return False
        var args = _evaluate_args(expression, frame_id, String("watch"))
        var via_sub = self._inspect_via_subprocess()
        var seq = self._send_inspect(via_sub, String("evaluate"), args)
        if seq == 0:
            return False
        ref rq = self._requests(via_sub)
        rq.evals.append(_PendingEval(seq, expression^, String(""), True))
        return True

    def has_test_evaluations(self) -> Bool:
        return len(self._test_evals) > 0

    def take_test_evaluation(mut self) -> Optional[DapTestEvaluation]:
        """Pop the oldest test-evaluate result. Returns ``None`` when
        nothing's queued. We pop one at a time rather than draining
        the batch so the dialog state machine handles each ``Try again``
        round trip independently — the batch shape would force the
        host to track which result belongs to which submit."""
        if len(self._test_evals) == 0:
            return Optional[DapTestEvaluation]()
        return Optional[DapTestEvaluation](self._test_evals.pop(0))

    def _stash_test_evaluate_result(
        mut self, var expr: String, msg: DapIncoming,
    ):
        var r = _evaluate_result(msg)
        var value = r[0]
        if not msg.ok():
            value = msg.message.value() if msg.message \
                else String("evaluation failed")
        self._test_evals.append(DapTestEvaluation(expr^, value^, not msg.ok()))

    def _send_set_debugger_property_debugpy(mut self):
        """debugpy-only: tell pydevd to suspend (and print) on every
        exception raised while evaluating a conditional breakpoint.

        pydevd's default ``debugpy-dap`` mode sets
        ``skip_suspend_on_breakpoint_exception = (BaseException,)`` and
        ``skip_print_breakpoint_exception = (NameError,)`` — meaning a
        condition that raises (e.g. ``x.y`` when ``x`` is None) silently
        evaluates to false and the user just doesn't stop. That's worse
        than useless: a typo in a condition expression looks
        indistinguishable from "the condition was never true". We
        override both with empty lists so any exception during condition
        evaluation gets printed to the debug pane *and* suspends the
        thread, surfacing the bug instead of hiding it.

        Sent as the debugpy/pydevd ``setDebuggerProperty`` request,
        which other adapters don't recognize — gate on adapter name."""
        if self.adapter_name != String("debugpy"):
            return
        try:
            _ = self.client.send_request(
                String("setDebuggerProperty"), _debugpy_condition_property_args(),
            )
        except e:
            print("dap: setDebuggerProperty (debugpy):", String(e))

    def _do_configure(mut self):
        """Push all breakpoints + exception filters, then send
        ``configurationDone``."""
        self._send_set_debugger_property_debugpy()
        self._push_all_breakpoints()
        self._send_set_exception_breakpoints()
        if self._supports_configuration_done:
            try:
                self._inflight_config_done = self.client.send_request(
                    String("configurationDone"), json_object(),
                )
            except e:
                self._fail(String("configurationDone failed: ") + String(e))
                return
            self.state = _STATE_CONFIGURING
            self.client.process.trace(String("state -> configuring"))
        else:
            # Some adapters (older delve, certain attach modes) don't
            # advertise configurationDone. Skip straight to RUNNING.
            self.state = _STATE_RUNNING
            self.client.process.trace(String("state -> running (no configDone)"))
        self._state_entered_ms = monotonic_ms()

    def _on_launch_response(mut self, msg: DapIncoming):
        # Spec lets the launch response arrive at any point — even after
        # the program has stopped on entry. We only fail the session if
        # success=false; otherwise the response is informational.
        var launch_ok = msg.ok()
        if not launch_ok:
            self._fail_rejected(String("launch"), msg)

    def _on_config_done_response(mut self, msg: DapIncoming):
        var cfg_ok = msg.ok()
        if not cfg_ok:
            self._fail(String("configurationDone rejected"))
            return
        if self.state == _STATE_CONFIGURING:
            self.state = _STATE_RUNNING
            self._state_entered_ms = monotonic_ms()
            self.client.process.trace(String("state -> running"))

    def _on_stopped_event(mut self, msg: DapIncoming, from_subprocess: Bool):
        var tid = 1
        var reason = String("")
        var description = String("")
        var all = False
        if msg.body and msg.body.value().is_object():
            ref b = msg.body.value()
            tid = json_get_int(b, String("threadId"), tid)
            reason = json_get_string(b, String("reason"), reason)
            description = json_get_string(b, String("description"), description)
            all = json_get_bool(b, String("allThreadsStopped"), all)
        self._stopped = Optional[DapStopped](DapStopped(
            tid, reason, description, all, from_subprocess,
        ))
        self._is_stopped = True
        self._stop_in_subprocess = from_subprocess
        self._last_stopped_thread_id = tid
        # "Run to cursor" oneshot housekeeping: any stop ends the
        # oneshot's lifetime — either we hit it (intended) or we hit a
        # real BP first (intent overridden). Clear the marker and
        # re-push ``setBreakpoints`` so the adapter forgets the
        # transient BP. Without this it persists and would re-fire on
        # subsequent runs through that line.
        if len(self._oneshot_bp_path.as_bytes()) > 0:
            var stale_path = self._oneshot_bp_path
            self._oneshot_bp_path = String("")
            self._oneshot_bp_line = -1
            self._push_breakpoints_for_path(stale_path)

    def _on_continued_event(mut self):
        """Execution resumed (parent or subprocess session): drop the
        stop state and latch ``_continued_pending`` for the host."""
        self._is_stopped = False
        self._stopped = Optional[DapStopped]()
        self._stop_in_subprocess = False
        self._last_stopped_thread_id = 0
        self._continued_pending = True

    def _on_output_event(mut self, msg: DapIncoming):
        if not msg.body or not msg.body.value().is_object():
            return
        ref b = msg.body.value()
        var category = String("console")
        var text = String("")
        category = json_get_string(b, String("category"), category)
        text = json_get_string(b, String("output"), text)
        if len(text.as_bytes()) == 0:
            return
        # Sniff for the runtime-condition-exception marker. We still
        # forward the full text into the output stream so the user sees
        # the traceback in the debug pane; the parsed condition + short
        # error are stashed on the side for the dialog to consume.
        _ = self._maybe_capture_condition_exception(text)
        self._output_events.append(DapOutput(category, text))

    def _on_debugpy_attach_event(mut self, msg: DapIncoming):
        """Open a TCP session to the forked subprocess and start its
        attach handshake. Without this, the child blocks at startup
        forever waiting for an IDE that never connects — and frameworks
        that fork at startup (Django runserver, multiprocessing pools)
        never get to bind their listening ports.

        Body fields we care about: ``connect.host`` / ``connect.port``
        (where to dial), ``subProcessId`` (must echo back in the attach
        request so the parent debugpy routes our messages to the right
        child), and ``name`` (display only). The rest of the body is
        treated as a launch-config blob to forward unchanged as the
        attach arguments — debugpy fills in ``program`` / ``cwd`` /
        ``justMyCode`` etc. that match the parent session.
        """
        if not msg.body or not msg.body.value().is_object():
            return
        ref b = msg.body.value()
        # Pull out connect.host/port. Anything weirdly-shaped → bail;
        # the subprocess will hang but the parent stays usable.
        var ci = b.object_index(String("connect"))
        if ci < 0 or not b.obj_v[ci].value.is_object():
            self.client.process.trace(String(
                "debugpyAttach: missing/invalid 'connect' field; ignoring",
            ))
            return
        ref co = b.obj_v[ci].value
        var host = String("127.0.0.1")
        host = json_get_string(co, String("host"), host)
        var port = json_get_int(co, String("port"), 0)
        if port <= 0:
            self.client.process.trace(String(
                "debugpyAttach: missing/invalid port; ignoring",
            ))
            return
        var spi = json_get_int(b, String("subProcessId"), -1)
        var name = String("Subprocess")
        name = json_get_string(b, String("name"), name)
        # Bail if a subprocess session is already in flight — current
        # design is single-slot. (When we extend to multi-fork targets,
        # swap this for an append.)
        if self._subprocess.state != _STATE_NOT_STARTED \
                and self._subprocess.state != _STATE_TERMINATED \
                and self._subprocess.state != _STATE_FAILED:
            self.client.process.trace(String(
                "debugpyAttach: subprocess slot busy; ignoring ",
            ) + name)
            return
        var fd = tcp_connect(host, port)
        if fd < 0:
            self.client.process.trace(String(
                "debugpyAttach: tcp_connect failed for ",
            ) + host + String(":") + String(port))
            return
        var proc = LspProcess.from_socket(fd)
        # Shared with the parent session, which owns the close.
        proc.borrow_trace_fd(self.client.process.trace_fd)
        # A fresh slot — the new client's seq restarts at 1, so nothing
        # from a previous subprocess (in-flight inspect requests, attach
        # args) may survive to claim its responses. Moved in, never
        # copied: the inert __copyinit__ would lose the live socket fd.
        self._subprocess = SubprocessAttach()
        self._subprocess.client = DapClient(proc^)
        self._subprocess.sub_process_id = spi
        self._subprocess.name = name
        self._subprocess.state = _STATE_INITIALIZING
        # Send the standard initialize. Same arguments as the parent —
        # debugpy doesn't really care, but matching shape keeps the log
        # sensible and the capabilities response well-formed.
        var init_args = dap_initialize_arguments(
            String("turbokod"), self.adapter_name,
        )
        try:
            self._subprocess.inflight_initialize = \
                self._subprocess.client.send_request(
                    String("initialize"), init_args,
                )
        except e:
            self.client.process.trace(String(
                "debugpyAttach: initialize send failed: ",
            ) + String(e))
            self._subprocess.client.terminate()
            self._subprocess.state = _STATE_FAILED
            return
        # Stash the attach arguments — sent on the initialize response.
        # Strip out the ``connect`` field (it's instructions for us, not
        # for the adapter) but otherwise forward the body unchanged. The
        # adapter expects ``subProcessId`` so it can route to the right
        # child.
        var attach_args = json_object()
        for i in range(len(b.obj_v)):
            var k = b.obj_v[i].key
            if k == String("connect"):
                continue
            attach_args.put(k, b.obj_v[i].value)
        self._subprocess.pending_attach_args = attach_args^
        self.client.process.trace(
            String("debugpyAttach: opened ") + host + String(":")
            + String(port) + String(" pid=") + String(spi)
            + String(" inflight_initialize=")
            + String(self._subprocess.inflight_initialize),
        )


# --- module-level helpers -------------------------------------------------


def _last_nonempty_line(text: String) -> String:
    """Last ``\\n``-delimited line of ``text`` skipping any trailing
    blank lines. Used to reduce a Python traceback string down to its
    final ``ExceptionType: message`` summary, which is what the
    condition-error dialog can fit on its single error row."""
    var b = text.as_bytes()
    if len(b) == 0:
        return String("")
    var end = len(b)
    while end > 0 and b[end - 1] == 0x0A:
        end -= 1
    if end == 0:
        return String("")
    var start = end
    while start > 0 and b[start - 1] != 0x0A:
        start -= 1
    return String(StringSpan(unsafe_from_utf8=b[start:end]))


def _state_name(state: UInt8) -> String:
    """Human-readable name for a state constant. Used in failure
    messages so ``adapter unresponsive for 15s in initializing`` reads
    cleanly without the caller knowing the comptime constants."""
    if state == _STATE_NOT_STARTED:
        return String("not_started")
    if state == _STATE_INITIALIZING:
        return String("initializing")
    if state == _STATE_LAUNCHING:
        return String("launching")
    if state == _STATE_CONFIGURING:
        return String("configuring")
    if state == _STATE_RUNNING:
        return String("running")
    if state == _STATE_TERMINATED:
        return String("terminated")
    return String("failed")


def _default_exception_filters() -> List[String]:
    """Sensible default: break only on uncaught exceptions. ``raised``
    fires on every raise (including ones the program later catches)
    which is rarely useful as a default but easy to flip on via
    ``set_exception_filters``."""
    var out = List[String]()
    out.append(String("uncaught"))
    return out^


# --- response-body parsers ------------------------------------------------


def _body_array(
    body_opt: Optional[JsonValue], key: String,
) -> Optional[Int]:
    """Index of the array member ``key`` of the response body, so a
    parser reads ``body.obj_v[i].value.arr_v`` in place instead of copying
    the body and then the array out of it. None when the body or the
    member is missing or the wrong shape."""
    if not body_opt or not body_opt.value().is_object():
        return Optional[Int]()
    var at = body_opt.value().object_index(key)
    if at < 0 or not body_opt.value().obj_v[at].value.is_array():
        return Optional[Int]()
    return Optional[Int](at)


def _has_int(obj: JsonValue, key: String) -> Bool:
    var at = obj.object_index(key)
    return at >= 0 and obj.obj_v[at].value.is_int()


def _has_string(obj: JsonValue, key: String) -> Bool:
    var at = obj.object_index(key)
    return at >= 0 and obj.obj_v[at].value.is_string()


def _parse_stack_trace(body_opt: Optional[JsonValue]) -> List[DapStackFrame]:
    var out = List[DapStackFrame]()
    var at = _body_array(body_opt, String("stackFrames"))
    if not at:
        return out^
    ref arr = body_opt.value().obj_v[at.value()].value.arr_v
    for i in range(len(arr)):
        ref f = arr[i]
        if not f.is_object():
            continue
        if not _has_int(f, String("id")) or not _has_string(f, String("name")):
            continue
        var line = json_get_int(f, String("line"), 0)
        var col = json_get_int(f, String("column"), 0)
        # Adapters disagree on linesStartAt1: lldb-dap honors our flag;
        # debugpy + delve hardcode 1-based. Subtract 1 with floor at 0
        # so the editor's 0-based row index always lines up.
        if line > 0:
            line = line - 1
        if col > 0:
            col = col - 1
        var path = String("")
        var subtle = False
        var si = f.object_index(String("source"))
        if si >= 0 and f.obj_v[si].value.is_object():
            ref s = f.obj_v[si].value
            path = json_get_string(s, String("path"), path)
            # ``source.presentationHint = deemphasize`` is how lldb-dap /
            # delve mark third-party / stdlib sources. Frame-level
            # ``presentationHint`` (next block) is how debugpy marks them.
            if json_get_string(s, String("presentationHint")) \
                    == String("deemphasize"):
                subtle = True
        if _has_string(f, String("presentationHint")):
            var h = json_get_string(f, String("presentationHint"))
            # ``subtle`` is the standard "library code" hint. ``label``
            # is for synthetic separator frames (thread-name markers);
            # treat both as dim so they don't compete with user code
            # for visual weight.
            if h == String("subtle") or h == String("label"):
                subtle = True
        out.append(DapStackFrame(
            json_get_int(f, String("id"), 0), json_get_string(f, String("name")),
            path, line, col, subtle,
        ))
    return out^


def _is_key_name(name: String) -> Bool:
    """A child name that's a mapping key repr (``'a'``, ``"a"``, ``1``,
    ``-2``, ``(1, 2)``, ``None``/``True``/``False``) rather than one of the
    adapter's synthetic rows (debugpy's ``len()``, ``special variables``,
    ``function variables``, …) or an attribute name."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    var c = b[0]
    if c == 0x27 or c == 0x22 or c == 0x28 or c == 0x2D:   # ' " ( -
        return True
    if c >= 0x30 and c <= 0x39:
        return True
    return name == String("None") or name == String("True") \
        or name == String("False")


def _is_index_name(name: String) -> Bool:
    """A list element's child name (``0``, ``12``) — not ``len()`` etc."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            return False
    return True


def _parse_completions(body_opt: Optional[JsonValue]) -> List[DapCompletion]:
    """``completions`` response body → targets, ``start`` kept as sent."""
    var out = List[DapCompletion]()
    var at = _body_array(body_opt, String("targets"))
    if not at:
        return out^
    ref arr = body_opt.value().obj_v[at.value()].value.arr_v
    for i in range(len(arr)):
        ref t = arr[i]
        if not t.is_object() or not _has_string(t, String("label")):
            continue
        var label = json_get_string(t, String("label"))
        var text = label
        text = json_get_string(t, String("text"), text)
        var type_name = String("")
        type_name = json_get_string(t, String("type"), type_name)
        var start = -1
        start = json_get_int(t, String("start"), start)
        var length = 0
        length = json_get_int(t, String("length"), length)
        out.append(DapCompletion(label^, text^, type_name^, start, length))
    return out^


def _parse_scopes(body_opt: Optional[JsonValue]) -> List[DapScope]:
    var out = List[DapScope]()
    var at = _body_array(body_opt, String("scopes"))
    if not at:
        return out^
    ref arr = body_opt.value().obj_v[at.value()].value.arr_v
    for i in range(len(arr)):
        ref s = arr[i]
        if not s.is_object():
            continue
        if not _has_string(s, String("name")) \
                or not _has_int(s, String("variablesReference")):
            continue
        out.append(DapScope(
            json_get_string(s, String("name")),
            json_get_int(s, String("variablesReference"), 0),
            json_get_bool(s, String("expensive"), False),
        ))
    return out^


def _parse_variables(body_opt: Optional[JsonValue]) -> List[DapVariable]:
    var out = List[DapVariable]()
    var at = _body_array(body_opt, String("variables"))
    if not at:
        return out^
    ref arr = body_opt.value().obj_v[at.value()].value.arr_v
    for i in range(len(arr)):
        ref v = arr[i]
        if not v.is_object() or not _has_string(v, String("name")):
            continue
        out.append(DapVariable(
            json_get_string(v, String("name")),
            json_get_string(v, String("value")),
            json_get_string(v, String("type")),
            json_get_int(v, String("variablesReference"), 0),
        ))
    return out^


def _debugpy_condition_property_args() -> JsonValue:
    """``setDebuggerProperty`` arguments that stop pydevd from swallowing
    exceptions raised while evaluating a breakpoint condition (see
    ``_send_set_debugger_property_debugpy``)."""
    var args = json_object()
    args.put(String("skipSuspendOnBreakpointException"), json_array())
    args.put(String("skipPrintBreakpointException"), json_array())
    return args^


def _exception_breakpoints_args(filters: List[String]) -> JsonValue:
    """``setExceptionBreakpoints`` arguments for ``filters``."""
    var arr = json_array()
    for i in range(len(filters)):
        arr.append(json_str(filters[i]))
    var args = json_object()
    args.put(String("filters"), arr)
    return args^


def _evaluate_args(
    expression: String, frame_id: Int, context: String,
) -> JsonValue:
    """``evaluate`` arguments. ``frame_id`` 0 leaves the frame out, which
    adapters read as "the current top frame"."""
    var args = json_object()
    args.put(String("expression"), json_str(expression))
    if frame_id != 0:
        args.put(String("frameId"), json_int(frame_id))
    args.put(String("context"), json_str(context))
    return args^


def _evaluate_result(msg: DapIncoming) -> Tuple[String, String]:
    """A successful ``evaluate`` response's ``(result, type)`` — empty for
    an error response or a body without them."""
    if not msg.ok() or not msg.body or not msg.body.value().is_object():
        return (String(""), String(""))
    ref b = msg.body.value()
    return (
        json_get_string(b, String("result")), json_get_string(b, String("type")),
    )


def _bp_paths(bps: List[DapBreakpoint]) -> List[String]:
    """The distinct source paths holding a breakpoint, first-seen order."""
    var out = List[String]()
    for ref b in bps:
        if b.path not in out:
            out.append(b.path)
    return out^
