"""Debug Adapter Protocol (DAP) client.

Sister module to ``lsp.mojo``. DAP and LSP share an identical wire
framing — ``Content-Length: N\\r\\n\\r\\n`` headers + a JSON body — but
the JSON envelope is different:

* LSP speaks JSON-RPC 2.0:  ``{"jsonrpc":"2.0","id":N,"method":...,"params":...}``
* DAP speaks its own shape: ``{"seq":N,"type":"request","command":...,"arguments":...}``

So we reuse ``LspProcess`` as a generic Content-Length-framed transport
(don't be fooled by the name — it's protocol-agnostic about the body)
and bolt a DAP-flavored envelope on top in ``DapClient``.

Three message types in DAP:

* ``request`` — client → adapter. Has ``seq``, ``command``, ``arguments``.
* ``response`` — adapter → client. Has ``request_seq`` (NOT ``id``),
  ``success``, ``command``, optional ``message``, optional ``body``.
* ``event`` — adapter → client. Has ``event``, optional ``body``.

Adapters can also send requests *to* the client (``runInTerminal``,
``startDebugging``); we surface those through the same ``DapIncoming``
classification so the dispatch layer can answer them.

Phase 2 here doesn't yet wire responses into the editor — that lives in
``dap_dispatch.mojo`` (handshake, breakpoints, threads, stack frames,
scopes, variables, execution control).
"""

from std.collections.list import List
from std.collections.optional import Optional

from .json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_null,
    json_object, json_str, parse_json,
)
from .lsp import LspProcess


# --- DapClient -------------------------------------------------------------


comptime DAP_RESPONSE     = UInt8(0)
comptime DAP_EVENT        = UInt8(1)
comptime DAP_REQUEST      = UInt8(2)


@fieldwise_init
struct DapIncoming(ImplicitlyCopyable, Movable):
    """A classified message from the adapter.

    * ``DAP_RESPONSE``: ``request_seq``, ``success``, ``command``, optional
      ``message`` (error text), optional ``body``.
    * ``DAP_EVENT``: ``event`` + optional ``body``.
    * ``DAP_REQUEST``: ``seq``, ``command``, optional ``arguments`` —
      reverse requests like ``runInTerminal`` / ``startDebugging``.
    """
    var kind: UInt8
    var seq: Int                 # adapter's own seq for this message
    var request_seq: Optional[Int]    # for responses
    var command: Optional[String]     # for requests + responses
    var event: Optional[String]       # for events
    var success: Optional[Bool]       # for responses
    var message: Optional[String]     # response error text (when success=false)
    var body: Optional[JsonValue]     # response.body or event.body
    var arguments: Optional[JsonValue]  # for reverse requests


struct DapClient(Movable):
    """Adds DAP envelope handling on top of ``LspProcess``.

    Outgoing seq numbers start at 1 and increment monotonically.
    Responses are matched by ``request_seq`` against the seq we issued.
    """
    var process: LspProcess
    var _next_seq: Int

    fn __init__(out self, var process: LspProcess):
        self.process = process^
        self._next_seq = 1

    @staticmethod
    fn spawn(argv: List[String]) raises -> Self:
        var p = LspProcess.spawn(argv)
        return DapClient(p^)

    fn send_request(
        mut self, command: String, arguments: JsonValue,
    ) raises -> Int:
        """Send a DAP request and return the issued seq number.

        Callers correlate responses by matching ``request_seq`` in the
        ``DapIncoming`` against the seq returned here.
        """
        var seq = self._next_seq
        self._next_seq += 1
        var envelope = json_object()
        envelope.put(String("seq"), json_int(seq))
        envelope.put(String("type"), json_str(String("request")))
        envelope.put(String("command"), json_str(command))
        envelope.put(String("arguments"), arguments)
        self.process.write_message(encode_json(envelope))
        return seq

    fn send_response(
        mut self, request_seq: Int, command: String, success: Bool,
        body: JsonValue,
    ) raises:
        """Reply to a *reverse* request (adapter → client). The dispatch
        layer uses this to answer ``runInTerminal`` and friends."""
        var seq = self._next_seq
        self._next_seq += 1
        var envelope = json_object()
        envelope.put(String("seq"), json_int(seq))
        envelope.put(String("type"), json_str(String("response")))
        envelope.put(String("request_seq"), json_int(request_seq))
        envelope.put(String("success"), json_bool(success))
        envelope.put(String("command"), json_str(command))
        envelope.put(String("body"), body)
        self.process.write_message(encode_json(envelope))

    fn poll(mut self, timeout_ms: Int32) raises -> Optional[DapIncoming]:
        var maybe = self.process.poll_message(timeout_ms)
        if not maybe:
            return Optional[DapIncoming]()
        var v = parse_json(maybe.value())
        return Optional[DapIncoming](classify_dap_message(v))

    fn terminate(mut self):
        self.process.terminate()


# --- classification --------------------------------------------------------


fn classify_dap_message(v: JsonValue) -> DapIncoming:
    """Examine a parsed DAP envelope and tag it as response / event /
    (reverse) request. Top-level utility for tests + clients.

    A malformed envelope with no recognizable ``type`` is reported as a
    response with seq 0 and no fields populated — callers ignore those
    rather than crashing the loop.
    """
    var seq: Int = 0
    var request_seq_opt = Optional[Int]()
    var command_opt = Optional[String]()
    var event_opt = Optional[String]()
    var success_opt = Optional[Bool]()
    var message_opt = Optional[String]()
    var body_opt = Optional[JsonValue]()
    var arguments_opt = Optional[JsonValue]()
    var type_str = String("")
    if v.is_object():
        var maybe_seq = v.object_get(String("seq"))
        if maybe_seq and maybe_seq.value().is_int():
            seq = maybe_seq.value().as_int()
        var maybe_type = v.object_get(String("type"))
        if maybe_type and maybe_type.value().is_string():
            type_str = maybe_type.value().as_str()
        var maybe_cmd = v.object_get(String("command"))
        if maybe_cmd and maybe_cmd.value().is_string():
            command_opt = Optional[String](maybe_cmd.value().as_str())
        var maybe_event = v.object_get(String("event"))
        if maybe_event and maybe_event.value().is_string():
            event_opt = Optional[String](maybe_event.value().as_str())
        var maybe_rseq = v.object_get(String("request_seq"))
        if maybe_rseq and maybe_rseq.value().is_int():
            request_seq_opt = Optional[Int](maybe_rseq.value().as_int())
        var maybe_success = v.object_get(String("success"))
        if maybe_success and maybe_success.value().is_bool():
            success_opt = Optional[Bool](maybe_success.value().as_bool())
        var maybe_msg = v.object_get(String("message"))
        if maybe_msg and maybe_msg.value().is_string():
            message_opt = Optional[String](maybe_msg.value().as_str())
        var maybe_body = v.object_get(String("body"))
        if maybe_body:
            body_opt = Optional[JsonValue](maybe_body.value())
        var maybe_args = v.object_get(String("arguments"))
        if maybe_args:
            arguments_opt = Optional[JsonValue](maybe_args.value())
    var kind: UInt8
    if type_str == String("event"):
        kind = DAP_EVENT
    elif type_str == String("request"):
        kind = DAP_REQUEST
    else:
        # ``response`` and anything malformed both land here. The
        # dispatch layer only acts on responses with a known
        # request_seq, so malformed messages are silently dropped.
        kind = DAP_RESPONSE
    return DapIncoming(
        kind, seq, request_seq_opt, command_opt, event_opt,
        success_opt, message_opt, body_opt, arguments_opt,
    )


# --- High-level helpers used by tests + dispatch ---------------------------


fn dap_initialize_arguments(client_id: String, adapter_id: String) -> JsonValue:
    """Build the bare-minimum ``initialize`` arguments most adapters accept.

    ``adapterID`` is required by the spec; ``debugpy`` and ``lldb-dap``
    accept any non-empty string here. ``linesStartAt1`` /
    ``columnsStartAt1`` are set to ``false`` because the editor stores
    cursor positions 0-based — keeping the wire format aligned avoids
    off-by-one mistakes when surfacing breakpoint hits.
    """
    var args = json_object()
    args.put(String("clientID"), json_str(client_id))
    args.put(String("clientName"), json_str(String("mojovision")))
    args.put(String("adapterID"), json_str(adapter_id))
    args.put(String("locale"), json_str(String("en")))
    args.put(String("linesStartAt1"), json_bool(False))
    args.put(String("columnsStartAt1"), json_bool(False))
    args.put(String("pathFormat"), json_str(String("path")))
    args.put(String("supportsVariableType"), json_bool(True))
    args.put(String("supportsVariablePaging"), json_bool(False))
    args.put(String("supportsRunInTerminalRequest"), json_bool(False))
    args.put(String("supportsStartDebuggingRequest"), json_bool(False))
    args.put(String("supportsProgressReporting"), json_bool(False))
    args.put(String("supportsInvalidatedEvent"), json_bool(False))
    return args^
