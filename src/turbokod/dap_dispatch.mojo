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

Limitations on purpose: one adapter per manager (not multi-session),
no conditional / hit-count breakpoints yet, no watch expressions, no
exception filters. Add when needed.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .dap import (
    DAP_EVENT, DAP_REQUEST, DAP_RESPONSE,
    DapClient, DapIncoming, dap_initialize_arguments,
)
from .debugger_config import (
    DAP_REQUEST_ATTACH, DAP_REQUEST_LAUNCH,
    DebuggerSpec, launch_arguments_for,
)
from .json import (
    JsonValue, json_array, json_bool, json_int, json_object, json_str,
)
from std.ffi import external_call

from .lsp import LspProcess
from .posix import monotonic_ms, realpath, tcp_connect, which
from .string_utils import starts_with


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
    """
    var id: Int
    var name: String
    var path: String
    var line: Int        # 0-based — adapter is configured ``linesStartAt1=false``
    var column: Int


@fieldwise_init
struct DapThread(ImplicitlyCopyable, Movable):
    var id: Int
    var name: String


@fieldwise_init
struct DapScope(ImplicitlyCopyable, Movable):
    """One scope from a ``scopes`` response. ``variables_reference`` is
    the handle the UI feeds into a follow-up ``variables`` request to
    fetch this scope's contents."""
    var name: String
    var variables_reference: Int
    var expensive: Bool


@fieldwise_init
struct DapEvaluations(Movable):
    """Drained evaluate-response batch. Three parallel lists in one
    return value so the host doesn't need a second pass to demux."""
    var expressions: List[String]
    var values: List[String]
    var types: List[String]


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

struct SubprocessAttach(Copyable, Movable):
    var client: DapClient
    var sub_process_id: Int
    var name: String
    var state: UInt8                 # _STATE_NOT_STARTED while idle, then _INITIALIZING / _LAUNCHING / _CONFIGURING / _RUNNING / _TERMINATED / _FAILED
    var inflight_initialize: Int
    var inflight_attach: Int
    var inflight_config_done: Int
    # Inspect-side inflight slots. The subprocess has its own pydevd and
    # therefore its own seq counter, so we can't share the parent's
    # ``_inflight_*`` fields — a parent seq=5 would collide with a
    # subprocess seq=5. Responses arriving on the subprocess socket are
    # demuxed against these and the parsed bodies are written into the
    # same ``_pending_*`` buffers on ``DapManager`` (the UI is
    # single-session and doesn't care which session answered).
    var inflight_stack_trace: Int
    var inflight_scopes: Int
    var inflight_variables: Int
    # Watch / REPL evaluates routed through the subprocess client when
    # the inspect frame was issued by subprocess pydevd. Frame ids are
    # session-scoped — sending a subprocess-issued frameId through the
    # parent socket fails with ``Wrong ID sent from the client``. List
    # rather than single-slot because watches fire all at once.
    var inflight_evaluate_seqs: List[Int]
    var inflight_evaluate_exprs: List[String]
    var inflight_test_eval_seqs: List[Int]
    var inflight_test_eval_exprs: List[String]
    var got_initialized_event: Bool
    var pending_attach_args: JsonValue
    # Mirror of the parent's breakpoints at attach time. Sent to the
    # subprocess on ``initialized`` so a breakpoint set in shared code
    # (e.g. a Django view served from the forked child) actually fires.
    var bp_paths: List[String]
    var bp_lines: List[Int]
    var bp_conditions: List[String]
    var bp_enabled: List[Bool]

    fn __init__(out self):
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
        self.inflight_stack_trace = 0
        self.inflight_scopes = 0
        self.inflight_variables = 0
        self.inflight_evaluate_seqs = List[Int]()
        self.inflight_evaluate_exprs = List[String]()
        self.inflight_test_eval_seqs = List[Int]()
        self.inflight_test_eval_exprs = List[String]()
        self.got_initialized_event = False
        self.pending_attach_args = JsonValue()
        self.bp_paths = List[String]()
        self.bp_lines = List[Int]()
        self.bp_conditions = List[String]()
        self.bp_enabled = List[Bool]()

    fn __copyinit__(out self, copy: Self):
        # Same caveat as ``DapManager.__copyinit__``: a real copy would
        # double-own the connected socket. We declare ``Copyable`` only
        # so the field can live in a ``DapManager`` (which is itself
        # Copyable for List storage). Hands back an inert sibling.
        self.client = DapClient(LspProcess())
        self.sub_process_id = -1
        self.name = String("")
        self.state = _STATE_NOT_STARTED
        self.inflight_initialize = 0
        self.inflight_attach = 0
        self.inflight_config_done = 0
        self.inflight_stack_trace = 0
        self.inflight_scopes = 0
        self.inflight_variables = 0
        self.inflight_evaluate_seqs = List[Int]()
        self.inflight_evaluate_exprs = List[String]()
        self.inflight_test_eval_seqs = List[Int]()
        self.inflight_test_eval_exprs = List[String]()
        self.got_initialized_event = False
        self.pending_attach_args = JsonValue()
        self.bp_paths = List[String]()
        self.bp_lines = List[Int]()
        self.bp_conditions = List[String]()
        self.bp_enabled = List[Bool]()


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
    var _inflight_threads: Int
    var _inflight_stack_trace: Int
    var _inflight_scopes: Int
    var _inflight_variables: Int

    # Capabilities returned by the adapter (parked from initialize response).
    var _supports_configuration_done: Bool
    var _supports_terminate_request: Bool

    # Whether we've seen the ``initialized`` event. We track this
    # separately from the launch response because the spec lets either
    # arrive first.
    var _got_initialized_event: Bool
    var _launch_request_kind: UInt8

    # Client-side breakpoint state. Stored as a flat list of
    # (path, line, condition) triples rather than a nested
    # ``List[List[...]]`` — nested generics aren't used anywhere else
    # in this codebase, so the flat shape is the safer / more idiomatic
    # choice. ``condition`` is empty for unconditional breakpoints.
    var _bp_path: List[String]
    var _bp_line: List[Int]        # 0-based
    var _bp_condition: List[String]
    # Per-BP enable flag. False marks a "parked" breakpoint — it stays
    # in the list (and on disk via ``breakpoint_store``) so the user
    # doesn't lose the row + condition, but it's stripped from
    # ``setBreakpoints`` payloads so the adapter never fires it.
    var _bp_enabled: List[Bool]
    # Per-BP "enable after another BP is hit" trigger. Empty string =
    # no dependency (the BP is live as soon as it's enabled). A
    # non-empty value identifies the trigger BP as ``"<full-path>:<1-based-line>"``
    # — matching ``_bp_wait_for[i]`` against ``"<other.path>:<other.line+1>"``.
    # Persisted via ``breakpoint_store``.
    var _bp_wait_for: List[String]
    # Per-BP "trigger has fired this session" latch. True while there's
    # no dependency (so the BP is always live), or once the wait-for
    # trigger has been hit. False otherwise — those BPs are stripped
    # from ``setBreakpoints`` until armed. Resets on session restart.
    var _bp_armed: List[Bool]
    # Demux table for ``setBreakpoints`` responses. Each entry parks
    # the source path of a sent request; the response carries a
    # parallel ``breakpoints`` array we line up by index against the
    # local rows for that path. Without tracking these we can't tell
    # *which* file's BPs the adapter just verified — and without that
    # we can't surface a per-BP "verified=false, message=..." back to
    # the user as a condition error.
    var _inflight_set_breakpoints_seqs: List[Int]
    var _inflight_set_breakpoints_paths: List[String]
    # Buffer of breakpoint errors surfaced via ``take_breakpoint_errors``.
    # Single drain per frame; entries describe one rejected BP each.
    var _bp_errors: List[DapBreakpointError]
    # Exception filters to enable on the next ``setExceptionBreakpoints``
    # call. ``"uncaught"`` and ``"raised"`` are the canonical filter ids
    # most adapters accept; we let callers configure freely without
    # validating against capabilities (a wrong id yields a soft error
    # in the response body — non-fatal).
    var _exception_filters: List[String]
    # In-flight ``evaluate`` requests. Single-slot tracking (like other
    # inflight ids) would force watches to evaluate serially; using
    # parallel lists lets us fire all watches at once and demux on
    # ``request_seq``.
    var _inflight_evaluate_seqs: List[Int]
    var _inflight_evaluate_exprs: List[String]
    # Buffer of completed evaluate responses; drained by the host once
    # per frame via ``take_evaluations``.
    var _evaluations_expr: List[String]
    var _evaluations_value: List[String]
    var _evaluations_type: List[String]
    # Independent test-evaluate channel — used by the condition-error
    # dialog to validate an edited BP condition against the live frame
    # before committing it. Kept separate from the watch/REPL evaluate
    # channel because ``_fold_watch_results`` silently drops anything
    # that isn't a known watch expression — sending a one-shot test
    # eval on that channel would lose the response. Same shape (in-flight
    # seq + expression list, then drained results), with an extra
    # ``error`` flag so the dialog can distinguish "evaluation raised"
    # from "evaluation returned the string ``<error: …>``".
    var _inflight_test_eval_seqs: List[Int]
    var _inflight_test_eval_exprs: List[String]
    var _test_eval_expr: List[String]
    var _test_eval_value: List[String]
    var _test_eval_error: List[Bool]
    # Most-recent ``Error while evaluating expression in conditional
    # breakpoint`` message, parsed from a debugpy ``output`` event of
    # category ``important``. Cleared by ``take_condition_exception``,
    # which the host calls once per tick after handling the surfaced
    # ``stopped`` event. Empty ``condition`` is the sentinel for "none
    # buffered" (a real BP condition expression is never empty — the
    # absence of a condition is encoded by ``len(_bp_condition[i]) == 0``,
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
    var _pending_threads: List[DapThread]
    var _pending_threads_ready: Bool
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

    fn __init__(out self):
        self.client = DapClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self.adapter_name = String("")
        self.language_id = String("")
        self._inflight_initialize = 0
        self._inflight_launch = 0
        self._inflight_config_done = 0
        self._inflight_threads = 0
        self._inflight_stack_trace = 0
        self._inflight_scopes = 0
        self._inflight_variables = 0
        self._supports_configuration_done = True
        self._supports_terminate_request = False
        self._got_initialized_event = False
        self._launch_request_kind = DAP_REQUEST_LAUNCH
        self._bp_path = List[String]()
        self._bp_line = List[Int]()
        self._bp_condition = List[String]()
        self._bp_enabled = List[Bool]()
        self._bp_wait_for = List[String]()
        self._bp_armed = List[Bool]()
        self._inflight_set_breakpoints_seqs = List[Int]()
        self._inflight_set_breakpoints_paths = List[String]()
        self._bp_errors = List[DapBreakpointError]()
        self._exception_filters = _default_exception_filters()
        self._inflight_evaluate_seqs = List[Int]()
        self._inflight_evaluate_exprs = List[String]()
        self._evaluations_expr = List[String]()
        self._evaluations_value = List[String]()
        self._evaluations_type = List[String]()
        self._inflight_test_eval_seqs = List[Int]()
        self._inflight_test_eval_exprs = List[String]()
        self._test_eval_expr = List[String]()
        self._test_eval_value = List[String]()
        self._test_eval_error = List[Bool]()
        self._pending_cond_exc_condition = String("")
        self._pending_cond_exc_error = String("")
        self._stopped = Optional[DapStopped]()
        self._is_stopped = False
        self._continued_pending = False
        self._output_events = List[DapOutput]()
        self._terminated_pending = False
        self._pending_threads = List[DapThread]()
        self._pending_threads_ready = False
        self._pending_stack = List[DapStackFrame]()
        self._pending_stack_ready = False
        self._pending_scopes = List[DapScope]()
        self._pending_scopes_ready = False
        self._pending_vars = List[DapVariable]()
        self._pending_vars_ready = False
        self._pending_launch_args = JsonValue()
        self.spawn_argv = List[String]()
        self._state_entered_ms = 0
        self._last_heartbeat_ms = 0
        self._subprocess = SubprocessAttach()
        self._last_inspect_in_subprocess = False
        self._stop_in_subprocess = False
        self._last_stopped_thread_id = 0
        self._oneshot_bp_path = String("")
        self._oneshot_bp_line = -1

    fn __copyinit__(out self, copy: Self):
        # Same caveat as ``LspManager.__copyinit__``: a real copy would
        # duplicate child PID + pipe FD ownership. We declare ``Copyable``
        # only so a manager can live in ``List[DapManager]``; lists are
        # grown via ``^`` transfer in practice and this branch shouldn't
        # fire for a live session. If it ever does, we hand back an
        # inert NOT_STARTED sibling.
        self.client = DapClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self.adapter_name = String("")
        self.language_id = String("")
        self._inflight_initialize = 0
        self._inflight_launch = 0
        self._inflight_config_done = 0
        self._inflight_threads = 0
        self._inflight_stack_trace = 0
        self._inflight_scopes = 0
        self._inflight_variables = 0
        self._supports_configuration_done = True
        self._supports_terminate_request = False
        self._got_initialized_event = False
        self._launch_request_kind = DAP_REQUEST_LAUNCH
        self._bp_path = List[String]()
        self._bp_line = List[Int]()
        self._bp_condition = List[String]()
        self._bp_enabled = List[Bool]()
        self._bp_wait_for = List[String]()
        self._bp_armed = List[Bool]()
        self._inflight_set_breakpoints_seqs = List[Int]()
        self._inflight_set_breakpoints_paths = List[String]()
        self._bp_errors = List[DapBreakpointError]()
        self._exception_filters = _default_exception_filters()
        self._inflight_evaluate_seqs = List[Int]()
        self._inflight_evaluate_exprs = List[String]()
        self._evaluations_expr = List[String]()
        self._evaluations_value = List[String]()
        self._evaluations_type = List[String]()
        self._inflight_test_eval_seqs = List[Int]()
        self._inflight_test_eval_exprs = List[String]()
        self._test_eval_expr = List[String]()
        self._test_eval_value = List[String]()
        self._test_eval_error = List[Bool]()
        self._pending_cond_exc_condition = String("")
        self._pending_cond_exc_error = String("")
        self._stopped = Optional[DapStopped]()
        self._is_stopped = False
        self._continued_pending = False
        self._output_events = List[DapOutput]()
        self._terminated_pending = False
        self._pending_threads = List[DapThread]()
        self._pending_threads_ready = False
        self._pending_stack = List[DapStackFrame]()
        self._pending_stack_ready = False
        self._pending_scopes = List[DapScope]()
        self._pending_scopes_ready = False
        self._pending_vars = List[DapVariable]()
        self._pending_vars_ready = False
        self._pending_launch_args = JsonValue()
        self.spawn_argv = List[String]()
        self._state_entered_ms = 0
        self._last_heartbeat_ms = 0
        self._subprocess = SubprocessAttach()
        self._last_inspect_in_subprocess = False
        self._stop_in_subprocess = False
        self._last_stopped_thread_id = 0
        self._oneshot_bp_path = String("")
        self._oneshot_bp_line = -1

    # --- state predicates ------------------------------------------------

    fn is_active(self) -> Bool:
        return self.state != _STATE_NOT_STARTED \
            and self.state != _STATE_FAILED \
            and self.state != _STATE_TERMINATED

    fn is_running(self) -> Bool:
        return self.state == _STATE_RUNNING and not self._is_stopped

    fn is_stopped(self) -> Bool:
        # Gated on ``is_active`` for the same reason ``is_running``
        # checks state: ``shutdown`` doesn't clear ``_is_stopped``, so
        # without this gate a session that was paused at a breakpoint
        # when the user hit Shift+F5 reports as "stopped" forever and
        # ``_debug_start_or_continue`` keeps routing F5 to ``cont()``
        # instead of starting a new session.
        return self._is_stopped and self.is_active()

    fn is_failed(self) -> Bool:
        return self.state == _STATE_FAILED

    fn is_terminated(self) -> Bool:
        return self.state == _STATE_TERMINATED

    fn status_summary(self) -> String:
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

    fn start(
        mut self, spec: DebuggerSpec, program: String, cwd: String,
        var program_args: List[String], stop_on_entry: Bool = False,
    ):
        """Spawn the adapter and kick off the handshake.

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
            self.state = _STATE_FAILED
            self.failure_reason = String("no adapter on $PATH for ") + spec.name
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
            self.state = _STATE_FAILED
            self.failure_reason = String("spawn failed: ") + String(e)
            return
        # Open the streaming trace log right after spawn. ``creat``
        # truncates so the file is fresh per session. Errors yield -1,
        # which keeps tracing disabled — never load-bearing.
        var trace_path = String("/tmp/turbokod-dap.log\0")
        var tfd = external_call["creat", Int32](
            trace_path.unsafe_ptr(), Int32(0o644),
        )
        if Int(tfd) >= 0:
            self.client.process.trace_fd = tfd
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
            self.state = _STATE_FAILED
            self.failure_reason = String("initialize failed: ") + String(e)
            return
        # Stash the launch arguments to send on the initialize response.
        # We keep them as a JsonValue rather than re-deriving from spec
        # so the dispatch doesn't depend on the registry past start.
        self._pending_launch_args = launch_arguments_for(
            spec, program, cwd, program_args^, stop_on_entry,
        )
        self.state = _STATE_INITIALIZING
        self._state_entered_ms = monotonic_ms()
        self.client.process.trace(String("state -> initializing"))

    fn _pick_argv(self, spec: DebuggerSpec) -> List[String]:
        """Return the first candidate whose argv[0] resolves on $PATH."""
        for i in range(len(spec.candidates)):
            var c = spec.candidates[i]
            if len(c.argv) == 0:
                continue
            if len(which(c.argv[0]).as_bytes()) == 0:
                continue
            var out = List[String]()
            for k in range(len(c.argv)):
                out.append(c.argv[k])
            return out^
        return List[String]()

    fn drain_stderr(mut self) -> String:
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
                String("stderr: ") + _trim_trailing_newline(text),
            )
        return text^


    fn shutdown(mut self):
        """Best-effort: send ``disconnect`` if active, then terminate the
        child if alive. Idempotent."""
        if self.state == _STATE_NOT_STARTED:
            return
        if self.is_active():
            var args = json_object()
            args.put(String("terminateDebuggee"), json_bool(True))
            try:
                _ = self.client.send_request(String("disconnect"), args)
            except:
                pass
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

    fn reset_for_restart(mut self):
        """Return to ``NOT_STARTED`` so ``start()`` can run again,
        preserving the persistent debugger configuration the user has
        accumulated this run.

        Kept across restarts:
          * Breakpoints (``_bp_path``/``_bp_line``/``_bp_condition``/
            ``_bp_wait_for``)
          * Exception filter selection (``_exception_filters``)

        ``_bp_armed`` is reset — wait-for BPs need to re-observe their
        trigger fire before they go live in the new session.

        Everything else is transient handshake / event state that
        must not leak from one process spawn to the next: a stale
        ``_inflight_initialize`` would race the next handshake; a
        stale ``_pending_stack_ready`` would surface frames from the
        previous run; the dead ``client`` would let writes go to a
        closed pipe.

        Sibling to ``shutdown``: callers that want to teardown call
        ``shutdown`` first, then ``reset_for_restart`` before the
        next ``start``.
        """
        # Discard the dead child + pipes wholesale by giving back a
        # fresh inert client.
        self.client = DapClient(LspProcess())
        self.state = _STATE_NOT_STARTED
        self.failure_reason = String("")
        self.adapter_name = String("")
        self.language_id = String("")
        self._inflight_initialize = 0
        self._inflight_launch = 0
        self._inflight_config_done = 0
        self._inflight_threads = 0
        self._inflight_stack_trace = 0
        self._inflight_scopes = 0
        self._inflight_variables = 0
        self._supports_configuration_done = True
        self._supports_terminate_request = False
        self._got_initialized_event = False
        self._launch_request_kind = DAP_REQUEST_LAUNCH
        # Reset the per-session ``armed`` latches: dependent BPs go
        # back to "armed iff no wait-for". Without this a BP that was
        # armed by its trigger in run N would stay live in run N+1
        # before the trigger re-fires.
        var rearmed = List[Bool]()
        for k in range(len(self._bp_wait_for)):
            rearmed.append(len(self._bp_wait_for[k].as_bytes()) == 0)
        self._bp_armed = rearmed^
        self._inflight_set_breakpoints_seqs = List[Int]()
        self._inflight_set_breakpoints_paths = List[String]()
        self._bp_errors = List[DapBreakpointError]()
        self._inflight_evaluate_seqs = List[Int]()
        self._inflight_evaluate_exprs = List[String]()
        self._evaluations_expr = List[String]()
        self._evaluations_value = List[String]()
        self._evaluations_type = List[String]()
        self._inflight_test_eval_seqs = List[Int]()
        self._inflight_test_eval_exprs = List[String]()
        self._test_eval_expr = List[String]()
        self._test_eval_value = List[String]()
        self._test_eval_error = List[Bool]()
        self._pending_cond_exc_condition = String("")
        self._pending_cond_exc_error = String("")
        self._stopped = Optional[DapStopped]()
        self._is_stopped = False
        self._continued_pending = False
        self._output_events = List[DapOutput]()
        self._terminated_pending = False
        self._pending_threads = List[DapThread]()
        self._pending_threads_ready = False
        self._pending_stack = List[DapStackFrame]()
        self._pending_stack_ready = False
        self._pending_scopes = List[DapScope]()
        self._pending_scopes_ready = False
        self._pending_vars = List[DapVariable]()
        self._pending_vars_ready = False
        self._pending_launch_args = JsonValue()
        self.spawn_argv = List[String]()
        self._state_entered_ms = 0
        self._last_heartbeat_ms = 0
        self._subprocess = SubprocessAttach()
        self._last_inspect_in_subprocess = False
        self._stop_in_subprocess = False
        self._last_stopped_thread_id = 0
        self._oneshot_bp_path = String("")
        self._oneshot_bp_line = -1

    # --- breakpoints -----------------------------------------------------

    fn toggle_breakpoint(mut self, path: String, line: Int):
        """Add or remove an unconditional breakpoint at ``(path, line)``.

        Lines are 0-based here (matching ``Editor.cursor_row``); we add
        +1 on the wire because DAP's default is 1-based and we keep the
        adapter configured with ``linesStartAt1=false`` in
        ``initialize``... but adapters disagree on whether they honor
        that. lldb-dap respects the flag; debugpy ignores it and always
        expects 1-based. So we send 1-based unconditionally.
        """
        var found = -1
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                found = i
                break
        if found >= 0:
            self._remove_bp_at(found)
        else:
            self._bp_path.append(path)
            self._bp_line.append(line)
            self._bp_condition.append(String(""))
            self._bp_enabled.append(True)
            self._bp_wait_for.append(String(""))
            self._bp_armed.append(True)
        self._push_breakpoints_for_path(path)

    fn set_breakpoint_condition(
        mut self, path: String, line: Int, var condition: String,
    ):
        """Set the condition expression for the breakpoint at
        ``(path, line)``. Adds the breakpoint if it didn't exist; an
        empty ``condition`` clears any prior condition without removing
        the breakpoint (use ``toggle_breakpoint`` for removal)."""
        var found = -1
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                found = i
                break
        if found < 0:
            self._bp_path.append(path)
            self._bp_line.append(line)
            self._bp_condition.append(condition^)
            self._bp_enabled.append(True)
            self._bp_wait_for.append(String(""))
            self._bp_armed.append(True)
        else:
            self._bp_condition[found] = condition^
        self._push_breakpoints_for_path(path)

    fn set_breakpoint_enabled(
        mut self, path: String, line: Int, enabled: Bool,
    ):
        """Mark the breakpoint at ``(path, line)`` enabled or disabled.
        No-op when no BP exists at that location — toggling enable on
        a non-existent BP has no obvious meaning, and the right-click
        menu only opens over an existing dot anyway."""
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                if self._bp_enabled[i] == enabled:
                    return
                self._bp_enabled[i] = enabled
                self._push_breakpoints_for_path(path)
                return

    fn set_breakpoint_wait_for(
        mut self, path: String, line: Int, var wait_for: String,
    ):
        """Set (or clear) the trigger-BP key for the breakpoint at
        ``(path, line)``. ``wait_for`` is the ``"<path>:<1-based-line>"``
        identifier of the BP that must be hit first; empty clears the
        dependency. No-op when no BP exists at that location."""
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                if self._bp_wait_for[i] == wait_for:
                    return
                self._bp_wait_for[i] = wait_for^
                # Re-derive ``armed``: empty wait-for is always armed;
                # non-empty starts disarmed (the trigger has to fire
                # again before the BP goes live).
                self._bp_armed[i] = (
                    len(self._bp_wait_for[i].as_bytes()) == 0
                )
                self._push_breakpoints_for_path(path)
                return

    fn breakpoint_wait_for(self, path: String, line: Int) -> String:
        """Wait-for trigger key at ``(path, line)``, or empty string
        when none / no BP exists."""
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                return self._bp_wait_for[i]
        return String("")

    fn arm_dependents(mut self, path: String, line: Int):
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
        for i in range(len(self._bp_wait_for)):
            if self._bp_wait_for[i] != key:
                continue
            if self._bp_armed[i]:
                continue
            self._bp_armed[i] = True
            var p = self._bp_path[i]
            var seen = False
            for k in range(len(changed_paths)):
                if changed_paths[k] == p:
                    seen = True
                    break
            if not seen:
                changed_paths.append(p)
        for k in range(len(changed_paths)):
            self._push_breakpoints_for_path(changed_paths[k])

    fn breakpoint_condition(self, path: String, line: Int) -> String:
        """Current condition for the breakpoint at ``(path, line)``,
        or empty string when none / unconditional."""
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                return self._bp_condition[i]
        return String("")

    fn breakpoint_enabled(self, path: String, line: Int) -> Bool:
        """Enable state at ``(path, line)``. Defaults to True (the
        most common case) so callers can use this in expressions
        without first probing ``has_breakpoint``."""
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                return self._bp_enabled[i]
        return True

    fn _remove_bp_at(mut self, idx: Int):
        """Compact the parallel breakpoint lists by skipping ``idx``."""
        var new_paths = List[String]()
        var new_lines = List[Int]()
        var new_conds = List[String]()
        var new_en = List[Bool]()
        var new_wait = List[String]()
        var new_armed = List[Bool]()
        for k in range(len(self._bp_path)):
            if k == idx:
                continue
            new_paths.append(self._bp_path[k])
            new_lines.append(self._bp_line[k])
            new_conds.append(self._bp_condition[k])
            new_en.append(self._bp_enabled[k])
            new_wait.append(self._bp_wait_for[k])
            new_armed.append(self._bp_armed[k])
        self._bp_path = new_paths^
        self._bp_line = new_lines^
        self._bp_condition = new_conds^
        self._bp_enabled = new_en^
        self._bp_wait_for = new_wait^
        self._bp_armed = new_armed^

    fn breakpoints_for(self, path: String) -> List[Int]:
        """Return a copy of the breakpoint lines for ``path``, 0-based.
        Includes disabled breakpoints — the gutter still draws them
        (in gray) so the user knows they're parked there."""
        var out = List[Int]()
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path:
                out.append(self._bp_line[i])
        return out^

    fn breakpoints_info_for(
        self, path: String,
    ) -> Tuple[List[Int], List[Bool], List[Bool]]:
        """Return parallel ``(lines, enabled, conditional)`` lists for
        ``path``. ``conditional`` is True when the BP has a non-empty
        condition expression. The editor uses these to colour the
        gutter dot (red / yellow / gray) per row."""
        var lines = List[Int]()
        var enabled = List[Bool]()
        var conditional = List[Bool]()
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path:
                lines.append(self._bp_line[i])
                enabled.append(self._bp_enabled[i])
                conditional.append(
                    len(self._bp_condition[i].as_bytes()) > 0,
                )
        return (lines^, enabled^, conditional^)

    fn breakpoint_count(self) -> Int:
        return len(self._bp_path)

    fn breakpoint_path_at(self, idx: Int) -> String:
        if idx < 0 or idx >= len(self._bp_path):
            return String("")
        return self._bp_path[idx]

    fn breakpoint_line_at(self, idx: Int) -> Int:
        if idx < 0 or idx >= len(self._bp_line):
            return 0
        return self._bp_line[idx]

    fn breakpoint_condition_at(self, idx: Int) -> String:
        if idx < 0 or idx >= len(self._bp_condition):
            return String("")
        return self._bp_condition[idx]

    fn breakpoint_enabled_at(self, idx: Int) -> Bool:
        if idx < 0 or idx >= len(self._bp_enabled):
            return True
        return self._bp_enabled[idx]

    fn breakpoint_wait_for_at(self, idx: Int) -> String:
        if idx < 0 or idx >= len(self._bp_wait_for):
            return String("")
        return self._bp_wait_for[idx]

    fn restore_breakpoints(
        mut self,
        var paths: List[String],
        var lines: List[Int],
        var conditions: List[String],
        var enabled: List[Bool],
        var wait_for: List[String],
    ):
        """Replace the in-memory breakpoint set wholesale, without
        sending any ``setBreakpoints`` to the adapter. Used at project
        setup to seed from the on-disk per-user file before the user
        starts a debug session — once they hit F5,
        ``_push_all_breakpoints`` ships the restored set during the
        CONFIGURING transition.

        All five lists must be the same length; a length mismatch is
        treated as "no breakpoints to restore" rather than partially
        populating the parallel arrays. ``armed`` is derived locally —
        empty ``wait_for`` is always armed; non-empty starts disarmed
        until the trigger fires this session."""
        if len(paths) != len(lines) \
                or len(paths) != len(conditions) \
                or len(paths) != len(enabled) \
                or len(paths) != len(wait_for):
            return
        var armed = List[Bool]()
        for k in range(len(wait_for)):
            armed.append(len(wait_for[k].as_bytes()) == 0)
        self._bp_path = paths^
        self._bp_line = lines^
        self._bp_condition = conditions^
        self._bp_enabled = enabled^
        self._bp_wait_for = wait_for^
        self._bp_armed = armed^

    fn has_breakpoint(self, path: String, line: Int) -> Bool:
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                return True
        return False

    fn _distinct_breakpoint_paths(self) -> List[String]:
        """Unique source paths that currently hold a breakpoint."""
        var out = List[String]()
        for i in range(len(self._bp_path)):
            var seen = False
            for k in range(len(out)):
                if out[k] == self._bp_path[i]:
                    seen = True
                    break
            if not seen:
                out.append(self._bp_path[i])
        return out^

    fn _push_breakpoints_for_path(mut self, path: String):
        """Send ``setBreakpoints`` for ``path`` if the adapter is in a
        state that can accept it. No-op otherwise — once the session
        reaches CONFIGURING / RUNNING we resend everything in
        ``_push_all_breakpoints``."""
        if self.state != _STATE_RUNNING:
            return
        self._send_set_breakpoints(path)

    fn _push_all_breakpoints(mut self):
        """Send the full breakpoint set, one ``setBreakpoints`` per
        distinct source. Called once during the CONFIGURING transition."""
        var paths = self._distinct_breakpoint_paths()
        for i in range(len(paths)):
            self._send_set_breakpoints(paths[i])

    fn _send_set_breakpoints(mut self, path: String):
        var args = json_object()
        var src = json_object()
        var resolved = realpath(path)
        var p = resolved if len(resolved.as_bytes()) > 0 else path
        src.put(String("path"), json_str(p))
        args.put(String("source"), src)
        var bps = json_array()
        var have_oneshot_match = False
        # Track which local indices we serialized for ``path``, in send
        # order, so the response demux can map ``breakpoints[i]`` back
        # to a ``(path, line)`` pair.
        var sent_lines = List[Int]()
        for i in range(len(self._bp_path)):
            if self._bp_path[i] != path:
                continue
            # Disabled BPs stay in the local list (so the user keeps
            # their condition + the gutter still shows a faint dot)
            # but never reach the adapter. Skip without breaking the
            # response-line correlation — the index on the wire only
            # advances for BPs we actually send.
            if not self._bp_enabled[i]:
                if self._oneshot_bp_path == path \
                        and self._bp_line[i] == self._oneshot_bp_line:
                    # A oneshot landing on a disabled BP still needs to
                    # fire. Fall through and emit it via the oneshot
                    # branch below.
                    pass
                continue
            # Wait-for trigger gating: a BP that's enabled but waiting
            # on another BP is held back until ``arm_dependents`` flips
            # ``_bp_armed[i]``. Same skip-but-no-correlation-break as
            # the disabled branch above. The oneshot ("run to cursor")
            # exception still applies — the user explicitly asked to
            # stop on this line, dependency or not.
            if not self._bp_armed[i]:
                if self._oneshot_bp_path == path \
                        and self._bp_line[i] == self._oneshot_bp_line:
                    pass
                else:
                    continue
            var bp = json_object()
            # +1: see comment in toggle_breakpoint about lines being
            # 1-based on the wire regardless of linesStartAt1.
            bp.put(String("line"), json_int(self._bp_line[i] + 1))
            if len(self._bp_condition[i].as_bytes()) > 0:
                bp.put(
                    String("condition"), json_str(self._bp_condition[i]),
                )
            bps.append(bp)
            sent_lines.append(self._bp_line[i])
            if self._oneshot_bp_path == path \
                    and self._bp_line[i] == self._oneshot_bp_line:
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
        try:
            var seq = self.client.send_request(
                String("setBreakpoints"), args.copy(),
            )
            self._inflight_set_breakpoints_seqs.append(seq)
            self._inflight_set_breakpoints_paths.append(path)
            # ``_handle_set_breakpoints_response`` re-derives lines from
            # the live arrays, so we don't need to stash sent_lines.
            _ = sent_lines^
        except:
            pass
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
            except:
                pass

    # --- exception breakpoints --------------------------------------------

    fn set_exception_filters(mut self, var filters: List[String]):
        """Replace the active exception filter set. Resends to the
        adapter immediately if the session is past CONFIGURING; queued
        otherwise, picked up during ``_do_configure``."""
        self._exception_filters = filters^
        if self.state == _STATE_RUNNING:
            self._send_set_exception_breakpoints()

    fn exception_filters(self) -> List[String]:
        var out = List[String]()
        for i in range(len(self._exception_filters)):
            out.append(self._exception_filters[i])
        return out^

    fn _send_set_exception_breakpoints(mut self):
        var args = json_object()
        var arr = json_array()
        for i in range(len(self._exception_filters)):
            arr.append(json_str(self._exception_filters[i]))
        args.put(String("filters"), arr)
        try:
            _ = self.client.send_request(
                String("setExceptionBreakpoints"), args,
            )
        except:
            pass

    # --- evaluate (watch / REPL) ------------------------------------------

    fn request_evaluate(
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
        var args = json_object()
        args.put(String("expression"), json_str(expression))
        if frame_id != 0:
            args.put(String("frameId"), json_int(frame_id))
        args.put(String("context"), json_str(context^))
        var via_subprocess = self._last_inspect_in_subprocess \
            and self._subprocess.state == _STATE_RUNNING
        var seq: Int
        try:
            if via_subprocess:
                seq = self._subprocess.client.send_request(
                    String("evaluate"), args,
                )
            else:
                seq = self.client.send_request(String("evaluate"), args)
        except:
            return False
        # Demux table is per-channel: parent and subprocess have
        # independent seq counters that can collide (both start at 1),
        # so a shared list would mis-route.
        if via_subprocess:
            self._subprocess.inflight_evaluate_seqs.append(seq)
            self._subprocess.inflight_evaluate_exprs.append(expression^)
        else:
            self._inflight_evaluate_seqs.append(seq)
            self._inflight_evaluate_exprs.append(expression^)
        return True

    fn has_evaluations(self) -> Bool:
        return len(self._evaluations_expr) > 0

    fn take_evaluations(mut self) -> DapEvaluations:
        """Drain the buffered evaluate responses.

        Empty types are common for adapters that don't return ``type``
        on plain identifier lookups."""
        var e = self._evaluations_expr^
        var v = self._evaluations_value^
        var t = self._evaluations_type^
        self._evaluations_expr = List[String]()
        self._evaluations_value = List[String]()
        self._evaluations_type = List[String]()
        return DapEvaluations(e^, v^, t^)

    # --- execution control -----------------------------------------------

    fn cont(mut self) -> Bool:
        """``continue`` is a Mojo keyword — hence ``cont``. Resumes the
        thread reported in the most recent ``stopped`` event, or thread
        1 as a fallback. Returns False if no session is active."""
        return self._send_thread_command(String("continue"))

    fn next(mut self) -> Bool:
        """Step over (one source line, no descent into calls)."""
        return self._send_thread_command(String("next"))

    fn step_in(mut self) -> Bool:
        return self._send_thread_command(String("stepIn"))

    fn step_out(mut self) -> Bool:
        return self._send_thread_command(String("stepOut"))

    fn pause(mut self) -> Bool:
        return self._send_thread_command(String("pause"))

    fn run_to_cursor(mut self, path: String, line: Int) -> Bool:
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

    fn _send_thread_command(mut self, command: String) -> Bool:
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

    fn request_threads(mut self) -> Bool:
        if not self.is_active():
            return False
        try:
            self._inflight_threads = self.client.send_request(
                String("threads"), json_object(),
            )
        except:
            return False
        return True

    fn request_stack_trace(mut self, thread_id: Int, levels: Int = 64) -> Bool:
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("threadId"), json_int(thread_id))
        args.put(String("startFrame"), json_int(0))
        args.put(String("levels"), json_int(levels))
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
        var via_subprocess = self._stop_in_subprocess \
            and self._subprocess.state == _STATE_RUNNING
        try:
            if via_subprocess:
                self._subprocess.inflight_stack_trace = \
                    self._subprocess.client.send_request(
                        String("stackTrace"), args,
                    )
                self._last_inspect_in_subprocess = True
            else:
                self._inflight_stack_trace = self.client.send_request(
                    String("stackTrace"), args,
                )
                self._last_inspect_in_subprocess = False
        except:
            return False
        return True

    fn request_scopes(mut self, frame_id: Int) -> Bool:
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("frameId"), json_int(frame_id))
        var via_subprocess = self._last_inspect_in_subprocess \
            and self._subprocess.state == _STATE_RUNNING
        try:
            if via_subprocess:
                self._subprocess.inflight_scopes = \
                    self._subprocess.client.send_request(
                        String("scopes"), args,
                    )
            else:
                self._inflight_scopes = self.client.send_request(
                    String("scopes"), args,
                )
        except:
            return False
        return True

    fn request_variables(mut self, variables_reference: Int) -> Bool:
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("variablesReference"), json_int(variables_reference))
        var via_subprocess = self._last_inspect_in_subprocess \
            and self._subprocess.state == _STATE_RUNNING
        try:
            if via_subprocess:
                self._subprocess.inflight_variables = \
                    self._subprocess.client.send_request(
                        String("variables"), args,
                    )
            else:
                self._inflight_variables = self.client.send_request(
                    String("variables"), args,
                )
        except:
            return False
        return True

    # --- pending-event accessors -----------------------------------------

    fn take_stopped(mut self) -> Optional[DapStopped]:
        """Pop the most recent ``stopped`` event. The ``_is_stopped``
        flag stays true until execution resumes (``continued`` event)
        — UI surfaces (gutter caret, stack pane) consult it."""
        var out = self._stopped
        self._stopped = Optional[DapStopped]()
        return out

    fn take_outputs(mut self) -> List[DapOutput]:
        """Drain all buffered ``output`` events."""
        var out = self._output_events^
        self._output_events = List[DapOutput]()
        return out^

    fn consume_terminated(mut self) -> Bool:
        """Returns True iff a ``terminated`` event has fired since the
        last call. Used by the host to fold up the debug pane."""
        if self._terminated_pending:
            self._terminated_pending = False
            return True
        return False

    fn consume_continued(mut self) -> Bool:
        """Returns True iff a ``continued`` event has fired since the
        last call. Host uses this to wipe stack/locals/watches while
        the program is running again — those rows hold ids tied to
        the prior stop, so clicking them after resume would request
        scopes/variables for stale frame ids and surface errors."""
        if self._continued_pending:
            self._continued_pending = False
            return True
        return False

    fn has_threads(self) -> Bool:
        return self._pending_threads_ready

    fn take_threads(mut self) -> List[DapThread]:
        var out = self._pending_threads^
        self._pending_threads = List[DapThread]()
        self._pending_threads_ready = False
        return out^

    fn has_stack(self) -> Bool:
        return self._pending_stack_ready

    fn take_stack(mut self) -> List[DapStackFrame]:
        var out = self._pending_stack^
        self._pending_stack = List[DapStackFrame]()
        self._pending_stack_ready = False
        return out^

    fn has_scopes(self) -> Bool:
        return self._pending_scopes_ready

    fn take_scopes(mut self) -> List[DapScope]:
        var out = self._pending_scopes^
        self._pending_scopes = List[DapScope]()
        self._pending_scopes_ready = False
        return out^

    fn has_variables(self) -> Bool:
        return self._pending_vars_ready

    fn take_variables(mut self) -> List[DapVariable]:
        var out = self._pending_vars^
        self._pending_vars = List[DapVariable]()
        self._pending_vars_ready = False
        return out^

    # --- frame-tick driver -----------------------------------------------

    fn tick(mut self):
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
            self.state = _STATE_FAILED
            self.failure_reason = String(
                "outbound queue overflowed (adapter not reading stdin)"
            )
            self.client.process.trace(String(
                "FAIL: outbound queue overflow",
            ))
            return
        # Crash-detection: ``try_reap`` returns True iff the child has
        # exited. While the session is supposed to be live, that means
        # the adapter crashed — most often because the python it was
        # spawned under doesn't have debugpy on its sys.path. Latch
        # FAILED so the UI shows a real error instead of an indefinite
        # ``initializing`` spinner.
        if self.client.process.try_reap():
            self.state = _STATE_FAILED
            self.failure_reason = String(
                "adapter exited before completing handshake"
            )
            self.client.process.trace(String(
                "FAIL: adapter exited (try_reap returned True)",
            ))
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
                self.state = _STATE_FAILED
                self.failure_reason = String(
                    "adapter unresponsive for 15s in "
                ) + prior
                self.client.process.trace(
                    String("FAIL: watchdog ") + prior,
                )
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
            var msg = maybe.value()
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

    fn _tick_subprocess(mut self):
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
                self._subprocess.state = _STATE_FAILED
                return
            if not maybe:
                break
            var msg = maybe.value()
            self._handle_subprocess_message(msg)

    fn _handle_subprocess_message(mut self, msg: DapIncoming):
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
                if not msg.body or not msg.body.value().is_object():
                    return
                var b = msg.body.value()
                var category = String("console")
                var text = String("")
                var c = b.object_get(String("category"))
                if c and c.value().is_string():
                    category = c.value().as_str()
                var o = b.object_get(String("output"))
                if o and o.value().is_string():
                    text = o.value().as_str()
                if len(text.as_bytes()) > 0:
                    _ = self._maybe_capture_condition_exception(text)
                    self._output_events.append(DapOutput(category, text))
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
                self._is_stopped = False
                self._stopped = Optional[DapStopped]()
                self._stop_in_subprocess = False
                self._last_stopped_thread_id = 0
                self._continued_pending = True
                return
            return
        if msg.kind == DAP_RESPONSE:
            if not msg.request_seq:
                return
            var rseq = msg.request_seq.value()
            if rseq == self._subprocess.inflight_initialize:
                self._subprocess.inflight_initialize = 0
                if msg.success and not msg.success.value():
                    self._subprocess.state = _STATE_FAILED
                    self._subprocess.client.terminate()
                    return
                # Now send attach with the args debugpy gave us.
                try:
                    self._subprocess.inflight_attach = \
                        self._subprocess.client.send_request(
                            String("attach"),
                            self._subprocess.pending_attach_args,
                        )
                except:
                    self._subprocess.state = _STATE_FAILED
                    self._subprocess.client.terminate()
                    return
                self._subprocess.state = _STATE_LAUNCHING
                if self._subprocess.got_initialized_event:
                    self._subprocess_configure()
                return
            if rseq == self._subprocess.inflight_attach:
                self._subprocess.inflight_attach = 0
                if msg.success and not msg.success.value():
                    self._subprocess.state = _STATE_FAILED
                    self._subprocess.client.terminate()
                return
            if rseq == self._subprocess.inflight_config_done:
                self._subprocess.inflight_config_done = 0
                if msg.success and not msg.success.value():
                    self._subprocess.state = _STATE_FAILED
                    self._subprocess.client.terminate()
                    return
                self._subprocess.state = _STATE_RUNNING
                return
            # Inspect-side responses — write into the same ``_pending_*``
            # buffers the parent path uses so the UI is session-agnostic.
            if rseq == self._subprocess.inflight_stack_trace:
                self._pending_stack = _parse_stack_trace(msg.body)
                self._pending_stack_ready = True
                self._subprocess.inflight_stack_trace = 0
                return
            if rseq == self._subprocess.inflight_scopes:
                self._pending_scopes = _parse_scopes(msg.body)
                self._pending_scopes_ready = True
                self._subprocess.inflight_scopes = 0
                return
            if rseq == self._subprocess.inflight_variables:
                self._pending_vars = _parse_variables(msg.body)
                self._pending_vars_ready = True
                self._subprocess.inflight_variables = 0
                return
            # Watch / REPL evaluate response routed via subprocess.
            # Output destination is the same as the parent path
            # (``_evaluations_*``) so the host's watch fold treats it
            # uniformly.
            var eidx = -1
            for k in range(len(self._subprocess.inflight_evaluate_seqs)):
                if self._subprocess.inflight_evaluate_seqs[k] == rseq:
                    eidx = k
                    break
            if eidx >= 0:
                self._on_evaluate_response_subprocess(eidx, msg)
                return
            # Test-evaluate response routed via subprocess (condition
            # dialog editing a BP that hit in subprocess code).
            var teidx = -1
            for k in range(len(self._subprocess.inflight_test_eval_seqs)):
                if self._subprocess.inflight_test_eval_seqs[k] == rseq:
                    teidx = k
                    break
            if teidx >= 0:
                self._on_test_evaluate_response_subprocess(teidx, msg)
                return
            return
        # Reverse requests: answer not-supported so the subprocess
        # debugpy isn't blocked.
        if msg.command:
            try:
                self._subprocess.client.send_response(
                    msg.seq, msg.command.value(), False, json_object(),
                )
            except:
                pass

    fn _subprocess_configure(mut self):
        """Push breakpoints + exception filters, then ``configurationDone``."""
        # Subprocess attach is debugpy-only (the ``debugpyAttach`` event
        # that opens this socket is a debugpy extension), so the same
        # condition-exception override the parent does applies here too.
        var sdp = json_object()
        sdp.put(String("skipSuspendOnBreakpointException"), json_array())
        sdp.put(String("skipPrintBreakpointException"), json_array())
        try:
            _ = self._subprocess.client.send_request(
                String("setDebuggerProperty"), sdp^,
            )
        except:
            pass
        # setBreakpoints per source path.
        var paths = List[String]()
        for i in range(len(self._subprocess.bp_paths)):
            var p = self._subprocess.bp_paths[i]
            var seen = False
            for k in range(len(paths)):
                if paths[k] == p:
                    seen = True
                    break
            if not seen:
                paths.append(p)
        for i in range(len(paths)):
            var path = paths[i]
            var src = json_object()
            src.put(String("path"), json_str(path))
            var bps = json_array()
            for k in range(len(self._subprocess.bp_paths)):
                if self._subprocess.bp_paths[k] != path:
                    continue
                if not self._subprocess.bp_enabled[k]:
                    continue
                var bp = json_object()
                bp.put(
                    String("line"),
                    json_int(self._subprocess.bp_lines[k] + 1),
                )
                if len(self._subprocess.bp_conditions[k].as_bytes()) > 0:
                    bp.put(
                        String("condition"),
                        json_str(self._subprocess.bp_conditions[k]),
                    )
                bps.append(bp^)
            var args = json_object()
            args.put(String("source"), src^)
            args.put(String("breakpoints"), bps^)
            args.put(String("sourceModified"), json_bool(False))
            try:
                _ = self._subprocess.client.send_request(
                    String("setBreakpoints"), args^,
                )
            except:
                pass
        # setExceptionBreakpoints — same defaults as parent.
        var ex_args = json_object()
        var arr = json_array()
        for i in range(len(self._exception_filters)):
            arr.append(json_str(self._exception_filters[i]))
        ex_args.put(String("filters"), arr^)
        try:
            _ = self._subprocess.client.send_request(
                String("setExceptionBreakpoints"), ex_args^,
            )
        except:
            pass
        try:
            self._subprocess.inflight_config_done = \
                self._subprocess.client.send_request(
                    String("configurationDone"), json_object(),
                )
        except:
            self._subprocess.state = _STATE_FAILED
            self._subprocess.client.terminate()
            return
        self._subprocess.state = _STATE_CONFIGURING

    # --- event / response handlers ---------------------------------------

    fn _handle_event(mut self, msg: DapIncoming):
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
            self._is_stopped = False
            self._stopped = Optional[DapStopped]()
            self._stop_in_subprocess = False
            self._last_stopped_thread_id = 0
            self._continued_pending = True
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

    fn _handle_response(mut self, msg: DapIncoming):
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
        if rseq == self._inflight_threads:
            self._pending_threads = _parse_threads(msg.body)
            self._pending_threads_ready = True
            self._inflight_threads = 0
            return
        if rseq == self._inflight_stack_trace:
            self._pending_stack = _parse_stack_trace(msg.body)
            self._pending_stack_ready = True
            self._inflight_stack_trace = 0
            return
        if rseq == self._inflight_scopes:
            self._pending_scopes = _parse_scopes(msg.body)
            self._pending_scopes_ready = True
            self._inflight_scopes = 0
            return
        if rseq == self._inflight_variables:
            self._pending_vars = _parse_variables(msg.body)
            self._pending_vars_ready = True
            self._inflight_variables = 0
            return
        # Evaluate response — match against the in-flight evaluate
        # seq list to recover which expression this answered.
        var eidx = -1
        for k in range(len(self._inflight_evaluate_seqs)):
            if self._inflight_evaluate_seqs[k] == rseq:
                eidx = k
                break
        if eidx >= 0:
            self._on_evaluate_response(eidx, msg)
            return
        # Test-evaluate response (condition-error dialog). Same shape
        # as the watch evaluate but routes into a dedicated buffer so
        # the watch fold doesn't swallow it.
        var teidx = -1
        for k in range(len(self._inflight_test_eval_seqs)):
            if self._inflight_test_eval_seqs[k] == rseq:
                teidx = k
                break
        if teidx >= 0:
            self._on_test_evaluate_response(teidx, msg)
            return
        # ``setBreakpoints`` response: per-BP verified flag + optional
        # message. We only surface the negative case — a verified=false
        # entry with a message is how debugpy reports a syntactically
        # invalid ``condition``, and that's the trigger for the
        # condition-fix dialog.
        var sidx = -1
        for k in range(len(self._inflight_set_breakpoints_seqs)):
            if self._inflight_set_breakpoints_seqs[k] == rseq:
                sidx = k
                break
        if sidx >= 0:
            self._on_set_breakpoints_response(sidx, msg)
            return

    fn _handle_reverse_request(mut self, msg: DapIncoming):
        if not msg.command:
            return
        try:
            self.client.send_response(
                msg.seq, msg.command.value(), False, json_object(),
            )
        except:
            pass

    fn _on_initialize_response(mut self, msg: DapIncoming):
        if msg.success and not msg.success.value():
            self.state = _STATE_FAILED
            var why = String("initialize rejected")
            if msg.message:
                why = why + String(": ") + msg.message.value()
            self.failure_reason = why
            return
        # Park capabilities. Only the few we actually use.
        if msg.body and msg.body.value().is_object():
            var b = msg.body.value()
            var cd = b.object_get(String("supportsConfigurationDoneRequest"))
            if cd and cd.value().is_bool():
                self._supports_configuration_done = cd.value().as_bool()
            var tr = b.object_get(String("supportsTerminateRequest"))
            if tr and tr.value().is_bool():
                self._supports_terminate_request = tr.value().as_bool()
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
            self.state = _STATE_FAILED
            self.failure_reason = String("launch failed: ") + String(e)
            return
        self.state = _STATE_LAUNCHING
        self._state_entered_ms = monotonic_ms()
        self.client.process.trace(String("state -> launching"))
        # If ``initialized`` already arrived (rare but spec-legal), kick
        # the configuration step now.
        if self._got_initialized_event:
            self._do_configure()

    fn _on_initialized_event(mut self):
        # Only meaningful once we've moved past INITIALIZING — if it
        # arrives during INITIALIZING (some adapters send it eagerly),
        # we'll act on it after the launch request goes out.
        if self.state == _STATE_LAUNCHING:
            self._do_configure()

    fn _on_set_breakpoints_response(mut self, idx: Int, msg: DapIncoming):
        """Demux a ``setBreakpoints`` response: pop the inflight slot,
        then walk the response's ``breakpoints`` array against the live
        local list (filtered by enabled-state to mirror what we sent).
        Any ``verified == false`` entry produces a ``DapBreakpointError``
        for the host to surface."""
        var path = self._inflight_set_breakpoints_paths[idx]
        # Compact inflight tables.
        var new_seqs = List[Int]()
        var new_paths = List[String]()
        for k in range(len(self._inflight_set_breakpoints_seqs)):
            if k == idx:
                continue
            new_seqs.append(self._inflight_set_breakpoints_seqs[k])
            new_paths.append(self._inflight_set_breakpoints_paths[k])
        self._inflight_set_breakpoints_seqs = new_seqs^
        self._inflight_set_breakpoints_paths = new_paths^
        # Re-derive the lines we sent in order — same filter rule as
        # ``_send_set_breakpoints``: same path, enabled. Then append
        # the oneshot if it would have stitched in. Lines past the end
        # of this list correspond to the trailing oneshot row.
        var sent_lines = List[Int]()
        var have_oneshot_match = False
        for i in range(len(self._bp_path)):
            if self._bp_path[i] != path:
                continue
            if not self._bp_enabled[i]:
                continue
            sent_lines.append(self._bp_line[i])
            if self._oneshot_bp_path == path \
                    and self._bp_line[i] == self._oneshot_bp_line:
                have_oneshot_match = True
        if self._oneshot_bp_path == path \
                and self._oneshot_bp_line >= 0 \
                and not have_oneshot_match:
            sent_lines.append(-1)   # oneshot — no user-visible BP
        if not msg.body or not msg.body.value().is_object():
            return
        var b = msg.body.value()
        var arr_opt = b.object_get(String("breakpoints"))
        if not arr_opt or not arr_opt.value().is_array():
            return
        var arr = arr_opt.value()
        var n = arr.array_len()
        for i in range(n):
            var entry = arr.array_at(i)
            if not entry.is_object():
                continue
            var verified_opt = entry.object_get(String("verified"))
            if not verified_opt or not verified_opt.value().is_bool():
                continue
            if verified_opt.value().as_bool():
                continue
            var msg_text = String("")
            var m = entry.object_get(String("message"))
            if m and m.value().is_string():
                msg_text = m.value().as_str()
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

    fn take_breakpoint_errors(mut self) -> List[DapBreakpointError]:
        """Drain any ``setBreakpoints`` rejections since the last call.
        Empty list when nothing's wrong."""
        var out = self._bp_errors^
        self._bp_errors = List[DapBreakpointError]()
        return out^

    fn has_breakpoint_errors(self) -> Bool:
        return len(self._bp_errors) > 0

    fn has_inflight_set_breakpoints(self) -> Bool:
        """True while at least one ``setBreakpoints`` request is still
        waiting on a response. The condition-error dialog uses this to
        tell "the adapter hasn't answered yet" from "the adapter
        accepted the new condition" — only the latter is a cue to
        close the dialog."""
        return len(self._inflight_set_breakpoints_seqs) > 0

    fn _on_evaluate_response(mut self, idx: Int, msg: DapIncoming):
        """Pop ``idx`` from the parent in-flight evaluate lists and
        stash the result. ``msg.body`` shape:
        ``{result, type?, variablesReference}``; we surface ``result``
        as the value text and ``type`` as the type when present."""
        var expr = self._inflight_evaluate_exprs[idx]
        var new_seqs = List[Int]()
        var new_exprs = List[String]()
        for k in range(len(self._inflight_evaluate_seqs)):
            if k == idx:
                continue
            new_seqs.append(self._inflight_evaluate_seqs[k])
            new_exprs.append(self._inflight_evaluate_exprs[k])
        self._inflight_evaluate_seqs = new_seqs^
        self._inflight_evaluate_exprs = new_exprs^
        self._stash_evaluate_result(expr^, msg)

    fn _on_evaluate_response_subprocess(
        mut self, idx: Int, msg: DapIncoming,
    ):
        """Subprocess-channel variant: same body, different inflight
        list. Result lands in the same ``_evaluations_*`` buffers so
        the host's watch fold doesn't care which session answered."""
        var expr = self._subprocess.inflight_evaluate_exprs[idx]
        var new_seqs = List[Int]()
        var new_exprs = List[String]()
        for k in range(len(self._subprocess.inflight_evaluate_seqs)):
            if k == idx:
                continue
            new_seqs.append(self._subprocess.inflight_evaluate_seqs[k])
            new_exprs.append(self._subprocess.inflight_evaluate_exprs[k])
        self._subprocess.inflight_evaluate_seqs = new_seqs^
        self._subprocess.inflight_evaluate_exprs = new_exprs^
        self._stash_evaluate_result(expr^, msg)

    fn _stash_evaluate_result(
        mut self, var expr: String, msg: DapIncoming,
    ):
        """Append one parsed ``evaluate`` result to the watch/REPL
        result buffers. Shared between parent and subprocess paths so
        both surface identically to the host."""
        var value = String("")
        var type_name = String("")
        if msg.success and not msg.success.value():
            # Error response — surface the message as the value so the
            # watch row reads ``len(items) = <error>`` rather than
            # going stale or vanishing.
            if msg.message:
                value = String("<error: ") + msg.message.value() + String(">")
            else:
                value = String("<error>")
        elif msg.body and msg.body.value().is_object():
            var b = msg.body.value()
            var r = b.object_get(String("result"))
            if r and r.value().is_string():
                value = r.value().as_str()
            var t = b.object_get(String("type"))
            if t and t.value().is_string():
                type_name = t.value().as_str()
        self._evaluations_expr.append(expr^)
        self._evaluations_value.append(value^)
        self._evaluations_type.append(type_name^)

    # --- condition-exception buffer & test-evaluate channel --------------

    fn _maybe_capture_condition_exception(mut self, text: String) -> Bool:
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
            condition = String(StringSlice(unsafe_from_utf8=b[p:]))
            traceback = String("")
        else:
            condition = String(StringSlice(unsafe_from_utf8=b[p:nl]))
            traceback = String(StringSlice(unsafe_from_utf8=b[nl + 1:]))
        var short_error = _last_nonempty_line(traceback)
        if len(short_error.as_bytes()) == 0:
            short_error = String("evaluation failed")
        self._pending_cond_exc_condition = condition^
        self._pending_cond_exc_error = short_error^
        return True

    fn has_condition_exception(self) -> Bool:
        return len(self._pending_cond_exc_condition.as_bytes()) > 0

    fn take_condition_exception(mut self) -> Optional[DapConditionException]:
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

    fn request_test_evaluate(
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
        var args = json_object()
        args.put(String("expression"), json_str(expression))
        if frame_id != 0:
            args.put(String("frameId"), json_int(frame_id))
        args.put(String("context"), json_str(String("watch")))
        var via_subprocess = self._last_inspect_in_subprocess \
            and self._subprocess.state == _STATE_RUNNING
        var seq: Int
        try:
            if via_subprocess:
                seq = self._subprocess.client.send_request(
                    String("evaluate"), args,
                )
            else:
                seq = self.client.send_request(String("evaluate"), args)
        except:
            return False
        if via_subprocess:
            self._subprocess.inflight_test_eval_seqs.append(seq)
            self._subprocess.inflight_test_eval_exprs.append(expression^)
        else:
            self._inflight_test_eval_seqs.append(seq)
            self._inflight_test_eval_exprs.append(expression^)
        return True

    fn has_test_evaluations(self) -> Bool:
        return len(self._test_eval_expr) > 0

    fn take_test_evaluation(mut self) -> Optional[DapTestEvaluation]:
        """Pop the oldest test-evaluate result. Returns ``None`` when
        nothing's queued. We pop one at a time rather than draining
        the batch so the dialog state machine handles each ``Try again``
        round trip independently — the batch shape would force the
        host to track which result belongs to which submit."""
        if len(self._test_eval_expr) == 0:
            return Optional[DapTestEvaluation]()
        var expr = self._test_eval_expr[0]
        var val = self._test_eval_value[0]
        var err = self._test_eval_error[0]
        # Pop index 0 — small list (one inflight expected at a time).
        var ne = List[String]()
        var nv = List[String]()
        var nr = List[Bool]()
        for k in range(1, len(self._test_eval_expr)):
            ne.append(self._test_eval_expr[k])
            nv.append(self._test_eval_value[k])
            nr.append(self._test_eval_error[k])
        self._test_eval_expr = ne^
        self._test_eval_value = nv^
        self._test_eval_error = nr^
        return Optional[DapTestEvaluation](
            DapTestEvaluation(expr^, val^, err),
        )

    fn _on_test_evaluate_response(mut self, idx: Int, msg: DapIncoming):
        """Pop the parent in-flight slot at ``idx`` and store the value
        (or the error message) in the test-eval result lists."""
        var expr = self._inflight_test_eval_exprs[idx]
        var new_seqs = List[Int]()
        var new_exprs = List[String]()
        for k in range(len(self._inflight_test_eval_seqs)):
            if k == idx:
                continue
            new_seqs.append(self._inflight_test_eval_seqs[k])
            new_exprs.append(self._inflight_test_eval_exprs[k])
        self._inflight_test_eval_seqs = new_seqs^
        self._inflight_test_eval_exprs = new_exprs^
        self._stash_test_evaluate_result(expr^, msg)

    fn _on_test_evaluate_response_subprocess(
        mut self, idx: Int, msg: DapIncoming,
    ):
        """Subprocess-channel variant — same body, different inflight
        list. Result lands in the same ``_test_eval_*`` buffers."""
        var expr = self._subprocess.inflight_test_eval_exprs[idx]
        var new_seqs = List[Int]()
        var new_exprs = List[String]()
        for k in range(len(self._subprocess.inflight_test_eval_seqs)):
            if k == idx:
                continue
            new_seqs.append(
                self._subprocess.inflight_test_eval_seqs[k],
            )
            new_exprs.append(
                self._subprocess.inflight_test_eval_exprs[k],
            )
        self._subprocess.inflight_test_eval_seqs = new_seqs^
        self._subprocess.inflight_test_eval_exprs = new_exprs^
        self._stash_test_evaluate_result(expr^, msg)

    fn _stash_test_evaluate_result(
        mut self, var expr: String, msg: DapIncoming,
    ):
        var value = String("")
        var is_error = False
        if msg.success and not msg.success.value():
            is_error = True
            if msg.message:
                value = msg.message.value()
            else:
                value = String("evaluation failed")
        elif msg.body and msg.body.value().is_object():
            var b = msg.body.value()
            var r = b.object_get(String("result"))
            if r and r.value().is_string():
                value = r.value().as_str()
        self._test_eval_expr.append(expr^)
        self._test_eval_value.append(value^)
        self._test_eval_error.append(is_error)

    fn _send_set_debugger_property_debugpy(mut self):
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
        var args = json_object()
        args.put(String("skipSuspendOnBreakpointException"), json_array())
        args.put(String("skipPrintBreakpointException"), json_array())
        try:
            _ = self.client.send_request(
                String("setDebuggerProperty"), args^,
            )
        except:
            pass

    fn _do_configure(mut self):
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
                self.state = _STATE_FAILED
                self.failure_reason = String("configurationDone failed: ") + String(e)
                return
            self.state = _STATE_CONFIGURING
            self.client.process.trace(String("state -> configuring"))
        else:
            # Some adapters (older delve, certain attach modes) don't
            # advertise configurationDone. Skip straight to RUNNING.
            self.state = _STATE_RUNNING
            self.client.process.trace(String("state -> running (no configDone)"))
        self._state_entered_ms = monotonic_ms()

    fn _on_launch_response(mut self, msg: DapIncoming):
        # Spec lets the launch response arrive at any point — even after
        # the program has stopped on entry. We only fail the session if
        # success=false; otherwise the response is informational.
        if msg.success and not msg.success.value():
            self.state = _STATE_FAILED
            var why = String("launch rejected")
            if msg.message:
                why = why + String(": ") + msg.message.value()
            self.failure_reason = why

    fn _on_config_done_response(mut self, msg: DapIncoming):
        if msg.success and not msg.success.value():
            self.state = _STATE_FAILED
            self.failure_reason = String("configurationDone rejected")
            return
        if self.state == _STATE_CONFIGURING:
            self.state = _STATE_RUNNING
            self._state_entered_ms = monotonic_ms()
            self.client.process.trace(String("state -> running"))

    fn _on_stopped_event(mut self, msg: DapIncoming, from_subprocess: Bool):
        var tid = 1
        var reason = String("")
        var description = String("")
        var all = False
        if msg.body and msg.body.value().is_object():
            var b = msg.body.value()
            var t = b.object_get(String("threadId"))
            if t and t.value().is_int():
                tid = t.value().as_int()
            var r = b.object_get(String("reason"))
            if r and r.value().is_string():
                reason = r.value().as_str()
            var d = b.object_get(String("description"))
            if d and d.value().is_string():
                description = d.value().as_str()
            var a = b.object_get(String("allThreadsStopped"))
            if a and a.value().is_bool():
                all = a.value().as_bool()
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

    fn _on_output_event(mut self, msg: DapIncoming):
        if not msg.body or not msg.body.value().is_object():
            return
        var b = msg.body.value()
        var category = String("console")
        var text = String("")
        var c = b.object_get(String("category"))
        if c and c.value().is_string():
            category = c.value().as_str()
        var o = b.object_get(String("output"))
        if o and o.value().is_string():
            text = o.value().as_str()
        if len(text.as_bytes()) == 0:
            return
        # Sniff for the runtime-condition-exception marker. We still
        # forward the full text into the output stream so the user sees
        # the traceback in the debug pane; the parsed condition + short
        # error are stashed on the side for the dialog to consume.
        _ = self._maybe_capture_condition_exception(text)
        self._output_events.append(DapOutput(category, text))

    fn _on_debugpy_attach_event(mut self, msg: DapIncoming):
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
        var b = msg.body.value()
        # Pull out connect.host/port. Anything weirdly-shaped → bail;
        # the subprocess will hang but the parent stays usable.
        var c = b.object_get(String("connect"))
        if not c or not c.value().is_object():
            self.client.process.trace(String(
                "debugpyAttach: missing/invalid 'connect' field; ignoring",
            ))
            return
        var co = c.value()
        var host = String("127.0.0.1")
        var hv = co.object_get(String("host"))
        if hv and hv.value().is_string():
            host = hv.value().as_str()
        var port = 0
        var pv = co.object_get(String("port"))
        if pv and pv.value().is_int():
            port = pv.value().as_int()
        if port <= 0:
            self.client.process.trace(String(
                "debugpyAttach: missing/invalid port; ignoring",
            ))
            return
        var spi = -1
        var sv = b.object_get(String("subProcessId"))
        if sv and sv.value().is_int():
            spi = sv.value().as_int()
        var name = String("Subprocess")
        var nv = b.object_get(String("name"))
        if nv and nv.value().is_string():
            name = nv.value().as_str()
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
        proc.trace_fd = self.client.process.trace_fd
        # Reset the subprocess slot in place — direct field access
        # (instead of an Optional swap) avoids copying the live socket
        # fd, which the inert __copyinit__ would lose.
        self._subprocess.client = DapClient(proc^)
        self._subprocess.sub_process_id = spi
        self._subprocess.name = name
        self._subprocess.state = _STATE_INITIALIZING
        self._subprocess.inflight_initialize = 0
        self._subprocess.inflight_attach = 0
        self._subprocess.inflight_config_done = 0
        self._subprocess.got_initialized_event = False
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
        # Mirror the parent's breakpoints into the subprocess so a
        # breakpoint set in shared code (a Django view served from the
        # forked child) actually fires.
        self._subprocess.bp_paths = List[String]()
        self._subprocess.bp_lines = List[Int]()
        self._subprocess.bp_conditions = List[String]()
        self._subprocess.bp_enabled = List[Bool]()
        for i in range(len(self._bp_path)):
            self._subprocess.bp_paths.append(self._bp_path[i])
            self._subprocess.bp_lines.append(self._bp_line[i])
            self._subprocess.bp_conditions.append(self._bp_condition[i])
            self._subprocess.bp_enabled.append(self._bp_enabled[i])
        self.client.process.trace(
            String("debugpyAttach: opened ") + host + String(":")
            + String(port) + String(" pid=") + String(spi)
            + String(" inflight_initialize=")
            + String(self._subprocess.inflight_initialize),
        )


# --- module-level helpers -------------------------------------------------


fn _trim_trailing_newline(s: String) -> String:
    """``s`` minus a single trailing ``\\n``, if any. Keeps trace lines
    one-per-line in the log file."""
    var b = s.as_bytes()
    if len(b) > 0 and b[len(b) - 1] == 0x0A:
        return String(StringSlice(
            ptr=b.unsafe_ptr(), length=len(b) - 1,
        ))
    return s


fn _last_nonempty_line(text: String) -> String:
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
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


fn _state_name(state: UInt8) -> String:
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


fn _default_exception_filters() -> List[String]:
    """Sensible default: break only on uncaught exceptions. ``raised``
    fires on every raise (including ones the program later catches)
    which is rarely useful as a default but easy to flip on via
    ``set_exception_filters``."""
    var out = List[String]()
    out.append(String("uncaught"))
    return out^


# --- response-body parsers ------------------------------------------------


fn _parse_threads(body_opt: Optional[JsonValue]) -> List[DapThread]:
    var out = List[DapThread]()
    if not body_opt:
        return out^
    var b = body_opt.value()
    if not b.is_object():
        return out^
    var arr_opt = b.object_get(String("threads"))
    if not arr_opt or not arr_opt.value().is_array():
        return out^
    var arr = arr_opt.value()
    for i in range(arr.array_len()):
        var t = arr.array_at(i)
        if not t.is_object():
            continue
        var id_opt = t.object_get(String("id"))
        var name_opt = t.object_get(String("name"))
        if not id_opt or not id_opt.value().is_int():
            continue
        var name = String("")
        if name_opt and name_opt.value().is_string():
            name = name_opt.value().as_str()
        out.append(DapThread(id_opt.value().as_int(), name))
    return out^


fn _parse_stack_trace(body_opt: Optional[JsonValue]) -> List[DapStackFrame]:
    var out = List[DapStackFrame]()
    if not body_opt:
        return out^
    var b = body_opt.value()
    if not b.is_object():
        return out^
    var arr_opt = b.object_get(String("stackFrames"))
    if not arr_opt or not arr_opt.value().is_array():
        return out^
    var arr = arr_opt.value()
    for i in range(arr.array_len()):
        var f = arr.array_at(i)
        if not f.is_object():
            continue
        var id_opt = f.object_get(String("id"))
        var name_opt = f.object_get(String("name"))
        var line_opt = f.object_get(String("line"))
        var col_opt = f.object_get(String("column"))
        if not id_opt or not id_opt.value().is_int():
            continue
        if not name_opt or not name_opt.value().is_string():
            continue
        var line = 0
        if line_opt and line_opt.value().is_int():
            line = line_opt.value().as_int()
        var col = 0
        if col_opt and col_opt.value().is_int():
            col = col_opt.value().as_int()
        # Adapters disagree on linesStartAt1: lldb-dap honors our flag;
        # debugpy + delve hardcode 1-based. Subtract 1 with floor at 0
        # so the editor's 0-based row index always lines up.
        if line > 0:
            line = line - 1
        if col > 0:
            col = col - 1
        var path = String("")
        var src_opt = f.object_get(String("source"))
        if src_opt and src_opt.value().is_object():
            var s = src_opt.value()
            var p = s.object_get(String("path"))
            if p and p.value().is_string():
                path = p.value().as_str()
        out.append(DapStackFrame(
            id_opt.value().as_int(), name_opt.value().as_str(),
            path, line, col,
        ))
    return out^


fn _parse_scopes(body_opt: Optional[JsonValue]) -> List[DapScope]:
    var out = List[DapScope]()
    if not body_opt:
        return out^
    var b = body_opt.value()
    if not b.is_object():
        return out^
    var arr_opt = b.object_get(String("scopes"))
    if not arr_opt or not arr_opt.value().is_array():
        return out^
    var arr = arr_opt.value()
    for i in range(arr.array_len()):
        var s = arr.array_at(i)
        if not s.is_object():
            continue
        var name_opt = s.object_get(String("name"))
        var ref_opt = s.object_get(String("variablesReference"))
        var exp_opt = s.object_get(String("expensive"))
        if not name_opt or not name_opt.value().is_string():
            continue
        if not ref_opt or not ref_opt.value().is_int():
            continue
        var expensive = False
        if exp_opt and exp_opt.value().is_bool():
            expensive = exp_opt.value().as_bool()
        out.append(DapScope(
            name_opt.value().as_str(), ref_opt.value().as_int(), expensive,
        ))
    return out^


fn _parse_variables(body_opt: Optional[JsonValue]) -> List[DapVariable]:
    var out = List[DapVariable]()
    if not body_opt:
        return out^
    var b = body_opt.value()
    if not b.is_object():
        return out^
    var arr_opt = b.object_get(String("variables"))
    if not arr_opt or not arr_opt.value().is_array():
        return out^
    var arr = arr_opt.value()
    for i in range(arr.array_len()):
        var v = arr.array_at(i)
        if not v.is_object():
            continue
        var name_opt = v.object_get(String("name"))
        var val_opt = v.object_get(String("value"))
        var type_opt = v.object_get(String("type"))
        var ref_opt = v.object_get(String("variablesReference"))
        if not name_opt or not name_opt.value().is_string():
            continue
        var value = String("")
        if val_opt and val_opt.value().is_string():
            value = val_opt.value().as_str()
        var type_name = String("")
        if type_opt and type_opt.value().is_string():
            type_name = type_opt.value().as_str()
        var vref = 0
        if ref_opt and ref_opt.value().is_int():
            vref = ref_opt.value().as_int()
        out.append(DapVariable(
            name_opt.value().as_str(), value, type_name, vref,
        ))
    return out^
