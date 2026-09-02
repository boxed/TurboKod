#!/usr/bin/env python3
"""A scripted LSP server for driving turbokod's client through the protocol.

There is no conformance suite for LSP *clients* — the spec ships no TCK, and
what Microsoft publishes (``vscode-languageserver-node``, ``lsprotocol``)
tests the reference *server*. So the client side has to be driven by a server
we control. This is that server: it does real framing over stdio and answers
from a JSON scenario file, which means a fixture is data, not code, and the
payload under test travels the whole production path — spawn, ``Content-Length``
framing, ``LspManager`` dispatch, the parse functions, the carriers.

Two fixture families it exists to serve:

* **Spec-shape coverage** — every union variant the spec permits for a result
  (``Hover.contents`` as string / MarkedString / array / MarkupContent;
  ``Definition`` as Location / Location[] / LocationLink[]; ``CompletionList``
  vs bare array; ``textEdit`` vs ``insertReplaceEdit``). Real servers pick one
  variant each, so no amount of real-server testing covers the others.
* **Adversarial / non-conforming** — null where an object is declared, wrong
  types, missing required fields, absurd ranges, split frames, lying
  ``Content-Length``. Real servers violate the spec constantly; in practice
  this catches more than spec breadth does.

Invoked as ``mock_lsp.py <scenario.json> [request-log.jsonl]`` (or via
``$MOCK_LSP_SCENARIO`` / ``$MOCK_LSP_LOG``, though argv is what the tests use
— see ``main``). The optional request log records every message the client
sent, which is how the *outbound* half of the protocol gets asserted.

Scenario format (all keys optional)::

    {
      "capabilities":   { ... },        # merged into the initialize result
      "position_encoding": "utf-16",    # shorthand: sets capabilities.positionEncoding
      "omit_position_encoding": true,   # answer without the field at all
      "responses": {                    # method -> result, or a directive
        "textDocument/hover": {"contents": "hi"},
        "textDocument/definition": {"$error": {"code": -32603, "message": "boom"}},
        "textDocument/references": {"$raw": "not json at all"},
        "textDocument/formatting": {"$no_reply": true}
      },
      "on_did_open": [                  # notifications pushed after didOpen
        {"method": "textDocument/publishDiagnostics", "params": {...}}
      ],
      "on_initialized": [ ... ],        # same, after the initialized notification
      "server_requests": [              # server->client requests after didOpen
        {"method": "workspace/applyEdit", "params": {...}}
      ]
    }

``$``-prefixed directives in a response slot:

* ``$error``    — reply with a JSON-RPC error instead of a result.
* ``$raw``      — write these bytes as the frame body verbatim (malformed JSON).
* ``$no_reply`` — receive the request and never answer it.
* ``$split``    — write the frame in two ``write`` calls with a flush between,
                  exercising the client's mid-frame reassembly.
* ``$bad_length`` — send a ``Content-Length`` larger than the body.

Unknown methods get ``result: null``, which is what a server that doesn't
implement a capability does.
"""

import json
import os
import sys
import time

_scenario = {}
_log_path = None
_last_uri = None


def _subst(value):
    """Replace the ``"$SELF"`` placeholder with the last opened document's
    URI. Scenarios are checked-in files but the buffer under test lives at
    a path only the test knows (a temp dir), so a fixture can't hardcode
    the URI it needs to return in a ``Location`` or ``publishDiagnostics``.
    """
    if isinstance(value, str):
        return _last_uri if value == "$SELF" and _last_uri else value
    if isinstance(value, list):
        return [_subst(v) for v in value]
    if isinstance(value, dict):
        # Keys too: ``WorkspaceEdit.changes`` is a ``{uri: TextEdit[]}`` map,
        # so the URI a rename fixture needs is a key, not a value.
        return {_subst(k): _subst(v) for k, v in value.items()}
    return value


def _record(msg):
    """Append every received message to ``$MOCK_LSP_LOG`` as JSON lines.

    This is how a test asserts on what the *client sent* — the outbound
    half of the protocol. Without it a scenario can only check that we
    parse a response correctly, which would leave position encoding,
    capability gating, and params shape untested in the direction that
    actually reaches real servers.
    """
    if not _log_path:
        return
    with open(_log_path, "a") as fh:
        fh.write(json.dumps(msg) + "\n")


def _log(msg):
    """Diagnostics go to stderr — stdout is the protocol channel.

    ``LspManager`` captures stderr and surfaces it in ``failure_reason``,
    so a scenario that misbehaves explains itself in the test output.
    """
    sys.stderr.write("mock_lsp: %s\n" % msg)
    sys.stderr.flush()


def _write_frame(body_bytes, content_length=None, split=False):
    header = b"Content-Length: %d\r\n\r\n" % (
        len(body_bytes) if content_length is None else content_length
    )
    out = sys.stdout.buffer
    if split:
        # Header and a first slice, flushed, then the rest: the client must
        # hold the partial frame rather than parsing what it has.
        out.write(header)
        half = max(1, len(body_bytes) // 2)
        out.write(body_bytes[:half])
        out.flush()
        time.sleep(0.02)
        out.write(body_bytes[half:])
        out.flush()
        return
    out.write(header)
    out.write(body_bytes)
    out.flush()


def _send(payload, split=False, bad_length=False):
    body = json.dumps(_subst(payload)).encode("utf-8")
    _write_frame(
        body,
        content_length=len(body) + 64 if bad_length else None,
        split=split,
    )


def _send_result(req_id, result):
    _send({"jsonrpc": "2.0", "id": req_id, "result": result})


def _read_frame():
    """Read one ``Content-Length``-framed message from stdin.

    Returns None at EOF. Header parsing is deliberately lenient about
    extra headers (``Content-Type`` is legal) and strict about the blank
    line, mirroring what a real server accepts.
    """
    stdin = sys.stdin.buffer
    length = None
    while True:
        line = stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    if length is None:
        return None
    body = b""
    while len(body) < length:
        chunk = stdin.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    try:
        return json.loads(body.decode("utf-8"))
    except ValueError:
        _log("unparseable request body: %r" % body[:200])
        return {}


def _initialize_result():
    caps = dict(_scenario.get("capabilities") or {})
    # A server advertises what it supports; default to a broad set so a
    # scenario only has to name the capability it wants to *withhold*.
    caps.setdefault("hoverProvider", True)
    caps.setdefault("definitionProvider", True)
    caps.setdefault("referencesProvider", True)
    caps.setdefault("documentSymbolProvider", True)
    caps.setdefault("completionProvider", {"triggerCharacters": ["."]})
    caps.setdefault("renameProvider", True)
    caps.setdefault("documentFormattingProvider", True)
    caps.setdefault("codeActionProvider", True)
    caps.setdefault("textDocumentSync", {"openClose": True, "change": 1})
    if _scenario.get("omit_position_encoding"):
        caps.pop("positionEncoding", None)
    elif _scenario.get("position_encoding"):
        caps["positionEncoding"] = _scenario["position_encoding"]
    return {"capabilities": caps, "serverInfo": {"name": "mock_lsp"}}


def _push(entries):
    for entry in entries or []:
        payload = {"jsonrpc": "2.0", "method": entry["method"]}
        if "params" in entry:
            payload["params"] = entry["params"]
        _send(payload)


def _push_server_requests(entries, next_id):
    for entry in entries or []:
        _send({
            "jsonrpc": "2.0",
            "id": next_id,
            "method": entry["method"],
            "params": entry.get("params", {}),
        })
        next_id += 1
    return next_id


def _answer(req_id, method):
    responses = _scenario.get("responses") or {}
    if method not in responses:
        _send_result(req_id, None)
        return
    spec = responses[method]
    if isinstance(spec, dict):
        if "$no_reply" in spec:
            _log("withholding reply for %s" % method)
            return
        if "$error" in spec:
            _send({"jsonrpc": "2.0", "id": req_id, "error": spec["$error"]})
            return
        if "$raw" in spec:
            _write_frame(spec["$raw"].encode("utf-8"))
            return
        if "$split" in spec:
            _send(
                {"jsonrpc": "2.0", "id": req_id, "result": spec["$split"]},
                split=True,
            )
            return
        if "$bad_length" in spec:
            _send(
                {"jsonrpc": "2.0", "id": req_id, "result": spec["$bad_length"]},
                bad_length=True,
            )
            return
    _send_result(req_id, spec)


def main():
    global _scenario, _log_path, _last_uri
    # argv first, env second. The client spawns children with an *allowlist*
    # envp (``_build_envp_from_parent`` in lsp.mojo), so a test-only env var
    # would silently not arrive — argv always does.
    path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "MOCK_LSP_SCENARIO",
    )
    _log_path = sys.argv[2] if len(sys.argv) > 2 else os.environ.get(
        "MOCK_LSP_LOG",
    )
    if path:
        with open(path) as fh:
            _scenario = json.load(fh)
        _log("scenario %s" % path)
    else:
        _log("no scenario; answering null to everything")

    server_req_id = 10_000
    while True:
        msg = _read_frame()
        if msg is None:
            return 0
        _record(msg)
        method = msg.get("method")
        req_id = msg.get("id")
        if method == "initialize":
            _send_result(req_id, _initialize_result())
        elif method == "initialized":
            _push(_scenario.get("on_initialized"))
        elif method == "shutdown":
            # ``ignore_shutdown`` models a server that accepts the request
            # and never answers — the case the client's grace budget exists
            # for. Without a scenario knob there is no way to test that the
            # budget is actually enforced rather than merely written down.
            if not _scenario.get("ignore_shutdown"):
                _send_result(req_id, None)
        elif method == "exit":
            # ``ignore_exit`` keeps the process alive past ``exit``, so the
            # client has to fall through to SIGTERM.
            if not _scenario.get("ignore_exit"):
                return 0
        elif method == "textDocument/didOpen":
            try:
                _last_uri = msg["params"]["textDocument"]["uri"]
            except (KeyError, TypeError):
                pass
            _push(_scenario.get("on_did_open"))
            server_req_id = _push_server_requests(
                _scenario.get("server_requests"), server_req_id,
            )
        elif req_id is not None:
            _answer(req_id, method)
        # Notifications we don't script (didChange, didSave, …) need no reply.


if __name__ == "__main__":
    sys.exit(main())
