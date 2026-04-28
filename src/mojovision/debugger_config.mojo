"""Debug-adapter registry, modeled on Helix's ``[language.debugger]``
sections in ``languages.toml``.

For each known language id, we know:

* the adapter binary + argv we'd spawn (with fallbacks where the
  ecosystem is fragmented — e.g., ``debugpy-adapter`` vs.
  ``python -m debugpy.adapter`` for Python),
* the *transport* hint (``stdio`` vs. a TCP port the adapter listens on),
* the request kind (``launch`` vs. ``attach``) we default to,
* the launch-arguments template, with placeholder substitution for
  ``${program}``, ``${cwd}``, ``${args}`` so callers can plug in a
  concrete program / cwd / argv at session start.

Why this shape mirrors ``language_config.mojo`` rather than reusing it:

* The two registries answer different questions — "which LSP server
  speaks this file?" vs. "which adapter debugs this language?" — and
  collapsing them would couple unrelated changes.
* Helix's TOML keeps them in separate tables for the same reason.

Coverage is deliberately narrow. Only the half-dozen adapters most
people have installed (debugpy, lldb-dap / codelldb, delve) plus a
``custom`` slot for users who want to point at something else. Add
entries here when the need is real, not speculative.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .json import (
    JsonValue, json_array, json_bool, json_int, json_object, json_str,
)


# --- transport hints -------------------------------------------------------

comptime DAP_TRANSPORT_STDIO = UInt8(0)
"""Adapter speaks DAP over its own stdin/stdout — like an LSP server."""

comptime DAP_TRANSPORT_TCP = UInt8(1)
"""Adapter listens on a TCP port we connect to. Not yet implemented in
the transport layer; entries are tagged this way so future TCP support
can light them up without changing the registry shape."""


# --- request kind ---------------------------------------------------------

comptime DAP_REQUEST_LAUNCH = UInt8(0)
"""Default: adapter spawns the debuggee."""

comptime DAP_REQUEST_ATTACH = UInt8(1)
"""Adapter attaches to an already-running process. Caller supplies a pid
or host:port via the launch arguments."""


# --- structures ----------------------------------------------------------


struct AdapterCandidate(ImplicitlyCopyable, Movable):
    """One concrete way to invoke a DAP adapter for a language.

    ``argv`` is the full command. For Python's ``python -m`` style
    invocation, this holds [``python``, ``-m``, ``debugpy.adapter``];
    for native binaries it's a single-element list.
    """
    var argv: List[String]
    var transport: UInt8

    fn __init__(out self, var argv: List[String], transport: UInt8):
        self.argv = argv^
        self.transport = transport

    fn __copyinit__(out self, copy: Self):
        self.argv = copy.argv.copy()
        self.transport = copy.transport


struct DebuggerSpec(ImplicitlyCopyable, Movable):
    """Per-language debugger config: which adapters can serve it, what
    request kind to default to, and the body of arguments we send with
    that request.

    ``language_id`` matches the same id used in ``language_config.mojo``
    so callers can route from "this file's language" to "the right
    adapter" with a single string lookup.
    """
    var language_id: String
    var candidates: List[AdapterCandidate]
    var request_kind: UInt8
    var name: String  # human-readable, e.g. "debugpy"

    fn __init__(
        out self, var language_id: String,
        var candidates: List[AdapterCandidate],
        request_kind: UInt8, var name: String,
    ):
        self.language_id = language_id^
        self.candidates = candidates^
        self.request_kind = request_kind
        self.name = name^

    fn __copyinit__(out self, copy: Self):
        self.language_id = copy.language_id
        self.candidates = copy.candidates.copy()
        self.request_kind = copy.request_kind
        self.name = copy.name


# --- helpers ---------------------------------------------------------------


fn _argv1(a: String, transport: UInt8 = DAP_TRANSPORT_STDIO) -> AdapterCandidate:
    var v = List[String]()
    v.append(a)
    return AdapterCandidate(v^, transport)


fn _argv2(
    a: String, b: String, transport: UInt8 = DAP_TRANSPORT_STDIO,
) -> AdapterCandidate:
    var v = List[String]()
    v.append(a)
    v.append(b)
    return AdapterCandidate(v^, transport)


fn _argv3(
    a: String, b: String, c: String, transport: UInt8 = DAP_TRANSPORT_STDIO,
) -> AdapterCandidate:
    var v = List[String]()
    v.append(a)
    v.append(b)
    v.append(c)
    return AdapterCandidate(v^, transport)


# --- built-ins ------------------------------------------------------------


fn built_in_debuggers() -> List[DebuggerSpec]:
    """Curated debugger registry, keyed on ``language_id``.

    Order within ``candidates`` is the spawn-priority order — first
    binary present on ``$PATH`` wins. The list is small (a handful of
    languages even fully populated) so a hash-table lookup would be
    over-engineering; ``find_debugger_for_language`` is a linear scan.
    """
    var out = List[DebuggerSpec]()

    # --- Python (debugpy) -------------------------------------------
    # ``debugpy-adapter`` is what's installed by ``pip install debugpy``;
    # ``python -m debugpy.adapter`` is the explicit form for environments
    # where the script wrapper isn't on $PATH (pixi, conda).
    var py = List[AdapterCandidate]()
    py.append(_argv1(String("debugpy-adapter")))
    py.append(_argv3(String("python"), String("-m"), String("debugpy.adapter")))
    py.append(_argv3(String("python3"), String("-m"), String("debugpy.adapter")))
    out.append(DebuggerSpec(
        String("python"), py^, DAP_REQUEST_LAUNCH, String("debugpy"),
    ))

    # --- C / C++ / Rust (lldb-dap / codelldb) -----------------------
    # ``lldb-dap`` ships with recent LLDB (Xcode 15+, LLVM 18+).
    # ``codelldb`` is the VS Code community fork — better defaults for
    # Rust, but a heavier install.
    var native = List[AdapterCandidate]()
    native.append(_argv1(String("lldb-dap")))
    native.append(_argv1(String("codelldb")))
    out.append(DebuggerSpec(
        String("cpp"), native^, DAP_REQUEST_LAUNCH, String("lldb-dap"),
    ))
    var native_rust = List[AdapterCandidate]()
    native_rust.append(_argv1(String("codelldb")))
    native_rust.append(_argv1(String("lldb-dap")))
    out.append(DebuggerSpec(
        String("rust"), native_rust^, DAP_REQUEST_LAUNCH, String("lldb-dap"),
    ))

    # --- Go (delve) -------------------------------------------------
    # ``dlv dap`` since delve 1.7. The previous JSON-RPC transport is
    # deprecated and we don't bother supporting it.
    var go = List[AdapterCandidate]()
    go.append(_argv2(String("dlv"), String("dap")))
    out.append(DebuggerSpec(
        String("go"), go^, DAP_REQUEST_LAUNCH, String("delve"),
    ))

    return out^


fn find_debugger_for_language(
    specs: List[DebuggerSpec], language_id: String,
) -> Int:
    """Index of the spec for ``language_id``, or -1 if no debugger is
    registered for that language. Linear scan; the list is tiny."""
    if len(language_id.as_bytes()) == 0:
        return -1
    for i in range(len(specs)):
        if specs[i].language_id == language_id:
            return i
    return -1


# --- launch-arguments builders --------------------------------------------


fn launch_arguments_for(
    spec: DebuggerSpec, program: String, cwd: String,
    var args: List[String], stop_on_entry: Bool = False,
) -> JsonValue:
    """Build the ``arguments`` body for the ``launch`` request.

    The shape is adapter-specific — we dispatch on ``spec.name`` so each
    adapter's quirks are isolated. ``program`` is the executable / script
    to run, ``cwd`` the working directory, ``args`` the program's argv
    (excluding ``program`` itself).

    ``stop_on_entry`` is honored where supported — useful when the user
    wants to set additional breakpoints before the program starts running.
    """
    if spec.name == String("debugpy"):
        return _launch_args_debugpy(program, cwd, args^, stop_on_entry)
    elif spec.name == String("lldb-dap"):
        return _launch_args_lldb(program, cwd, args^, stop_on_entry)
    elif spec.name == String("delve"):
        return _launch_args_delve(program, cwd, args^, stop_on_entry)
    # Fallback: the union of the common keys. Unknown adapters that
    # follow the spec literally (program/cwd/args/stopOnEntry) work
    # off this shape.
    return _launch_args_generic(program, cwd, args^, stop_on_entry)


fn _launch_args_debugpy(
    program: String, cwd: String, var args: List[String],
    stop_on_entry: Bool,
) -> JsonValue:
    """``debugpy``: ``program`` + ``args`` + ``cwd`` + ``console``.

    ``console: "internalConsole"`` keeps stdout/stderr coming back as
    DAP ``output`` events instead of being routed to a separate
    terminal — that's what we want, since we'll surface those events
    in the editor's debug pane.

    ``justMyCode`` is *false* on purpose. With ``true``, debugpy
    filters frames through its "user code" heuristic — and one
    failure mode of that filtering, when called from a Mojo client
    that doesn't perfectly match VS Code's expectations, is to stall
    the ``variables`` request indefinitely (debugpy is waiting on
    the debuggee to classify a frame and never gets an answer).
    Letting all code through avoids the trap; users who specifically
    want to skip stdlib frames can set the flag back via the
    debugger's ``setDebuggerProperty`` mechanism later.
    """
    var o = json_object()
    o.put(String("program"), json_str(program))
    o.put(String("cwd"), json_str(cwd))
    o.put(String("args"), _string_list_to_json(args^))
    o.put(String("console"), json_str(String("internalConsole")))
    o.put(String("stopOnEntry"), json_bool(stop_on_entry))
    o.put(String("justMyCode"), json_bool(False))
    return o^


fn _launch_args_lldb(
    program: String, cwd: String, var args: List[String],
    stop_on_entry: Bool,
) -> JsonValue:
    """``lldb-dap`` / ``codelldb``: ``program`` + ``args`` + ``cwd``
    + ``stopOnEntry``. ``runInTerminal`` is intentionally *not* set —
    we'd need to answer the reverse request, which we don't yet."""
    var o = json_object()
    o.put(String("program"), json_str(program))
    o.put(String("cwd"), json_str(cwd))
    o.put(String("args"), _string_list_to_json(args^))
    o.put(String("stopOnEntry"), json_bool(stop_on_entry))
    return o^


fn _launch_args_delve(
    program: String, cwd: String, var args: List[String],
    stop_on_entry: Bool,
) -> JsonValue:
    """``dlv dap``: ``mode`` + ``program`` + ``cwd`` + ``args``.

    ``mode: "debug"`` builds and debugs a Go package directly (analogous
    to ``go run`` + breakpoints). ``"exec"`` would expect ``program`` to
    already be a built binary — we default to ``debug`` because pointing
    at a ``.go`` file is the more common entry point.
    """
    var o = json_object()
    o.put(String("mode"), json_str(String("debug")))
    o.put(String("program"), json_str(program))
    o.put(String("cwd"), json_str(cwd))
    o.put(String("args"), _string_list_to_json(args^))
    o.put(String("stopOnEntry"), json_bool(stop_on_entry))
    return o^


fn _launch_args_generic(
    program: String, cwd: String, var args: List[String],
    stop_on_entry: Bool,
) -> JsonValue:
    var o = json_object()
    o.put(String("program"), json_str(program))
    o.put(String("cwd"), json_str(cwd))
    o.put(String("args"), _string_list_to_json(args^))
    o.put(String("stopOnEntry"), json_bool(stop_on_entry))
    return o^


fn _string_list_to_json(var args: List[String]) -> JsonValue:
    var arr = json_array()
    for i in range(len(args)):
        arr.append(json_str(args[i]))
    return arr^
