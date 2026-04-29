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
from .posix import monotonic_ms, realpath, which


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
    """
    var thread_id: Int
    var reason: String
    var description: String
    var all_threads_stopped: Bool


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
        self._exception_filters = _default_exception_filters()
        self._inflight_evaluate_seqs = List[Int]()
        self._inflight_evaluate_exprs = List[String]()
        self._evaluations_expr = List[String]()
        self._evaluations_value = List[String]()
        self._evaluations_type = List[String]()
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
        self._exception_filters = _default_exception_filters()
        self._inflight_evaluate_seqs = List[Int]()
        self._inflight_evaluate_exprs = List[String]()
        self._evaluations_expr = List[String]()
        self._evaluations_value = List[String]()
        self._evaluations_type = List[String]()
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
        var trace_path = String("/tmp/mojovision-dap.log\0")
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
            String("mojovision"), spec.name,
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
        self._continued_pending = False

    fn reset_for_restart(mut self):
        """Return to ``NOT_STARTED`` so ``start()`` can run again,
        preserving the persistent debugger configuration the user has
        accumulated this run.

        Kept across restarts:
          * Breakpoints (``_bp_path``/``_bp_line``/``_bp_condition``)
          * Exception filter selection (``_exception_filters``)

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
        self._inflight_evaluate_seqs = List[Int]()
        self._inflight_evaluate_exprs = List[String]()
        self._evaluations_expr = List[String]()
        self._evaluations_value = List[String]()
        self._evaluations_type = List[String]()
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
        else:
            self._bp_condition[found] = condition^
        self._push_breakpoints_for_path(path)

    fn breakpoint_condition(self, path: String, line: Int) -> String:
        """Current condition for the breakpoint at ``(path, line)``,
        or empty string when none / unconditional."""
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path and self._bp_line[i] == line:
                return self._bp_condition[i]
        return String("")

    fn _remove_bp_at(mut self, idx: Int):
        """Compact the parallel breakpoint lists by skipping ``idx``."""
        var new_paths = List[String]()
        var new_lines = List[Int]()
        var new_conds = List[String]()
        for k in range(len(self._bp_path)):
            if k == idx:
                continue
            new_paths.append(self._bp_path[k])
            new_lines.append(self._bp_line[k])
            new_conds.append(self._bp_condition[k])
        self._bp_path = new_paths^
        self._bp_line = new_lines^
        self._bp_condition = new_conds^

    fn breakpoints_for(self, path: String) -> List[Int]:
        """Return a copy of the breakpoint lines for ``path``, 0-based."""
        var out = List[Int]()
        for i in range(len(self._bp_path)):
            if self._bp_path[i] == path:
                out.append(self._bp_line[i])
        return out^

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
        for i in range(len(self._bp_path)):
            if self._bp_path[i] != path:
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
        args.put(String("breakpoints"), bps)
        args.put(String("sourceModified"), json_bool(False))
        try:
            _ = self.client.send_request(String("setBreakpoints"), args)
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
        """
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("expression"), json_str(expression))
        if frame_id != 0:
            args.put(String("frameId"), json_int(frame_id))
        args.put(String("context"), json_str(context^))
        var seq: Int
        try:
            seq = self.client.send_request(String("evaluate"), args)
        except:
            return False
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

    fn _send_thread_command(mut self, command: String) -> Bool:
        if not self.is_active():
            return False
        var tid = 1
        if self._stopped:
            tid = self._stopped.value().thread_id
        var args = json_object()
        args.put(String("threadId"), json_int(tid))
        try:
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
        try:
            self._inflight_stack_trace = self.client.send_request(
                String("stackTrace"), args,
            )
        except:
            return False
        return True

    fn request_scopes(mut self, frame_id: Int) -> Bool:
        if not self.is_active():
            return False
        var args = json_object()
        args.put(String("frameId"), json_int(frame_id))
        try:
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
        try:
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
                return
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
            self._on_stopped_event(msg)
            return
        if event == String("continued"):
            self._is_stopped = False
            self._stopped = Optional[DapStopped]()
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
        # Other responses (setBreakpoints, continue/next/etc.) — ignored.
        # ``setBreakpoints`` does return a verified-status array per
        # breakpoint that we could surface in the gutter, but until
        # the UI has the real estate for a "verified" indicator there's
        # no point parsing it.

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

    fn _on_evaluate_response(mut self, idx: Int, msg: DapIncoming):
        """Pop ``idx`` from the in-flight evaluate lists and stash the
        result. ``msg.body`` shape: ``{result, type?, variablesReference}``;
        we surface ``result`` as the value text and ``type`` as the
        type when present."""
        var expr = self._inflight_evaluate_exprs[idx]
        # Compact the inflight lists.
        var new_seqs = List[Int]()
        var new_exprs = List[String]()
        for k in range(len(self._inflight_evaluate_seqs)):
            if k == idx:
                continue
            new_seqs.append(self._inflight_evaluate_seqs[k])
            new_exprs.append(self._inflight_evaluate_exprs[k])
        self._inflight_evaluate_seqs = new_seqs^
        self._inflight_evaluate_exprs = new_exprs^
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
        self._evaluations_expr.append(expr)
        self._evaluations_value.append(value^)
        self._evaluations_type.append(type_name^)

    fn _do_configure(mut self):
        """Push all breakpoints + exception filters, then send
        ``configurationDone``."""
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

    fn _on_stopped_event(mut self, msg: DapIncoming):
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
            tid, reason, description, all,
        ))
        self._is_stopped = True

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
        self._output_events.append(DapOutput(category, text))


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
