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

from .file_io import join_path, list_directory, stat_file
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


fn python_debugger_spec_for_venv(
    spec: DebuggerSpec, venv_dir: String,
) -> DebuggerSpec:
    """Return a copy of ``spec`` with venv-resolved adapter candidates
    prepended, so a Python debug session uses the venv's debugpy
    instead of whatever's first on ``$PATH``.

    Two venv-aware candidates are added in priority order:

      1. ``<venv>/bin/debugpy-adapter`` — the script wrapper installed
         by ``pip install debugpy``. Preferred when present.
      2. ``<venv>/bin/python -m debugpy.adapter`` — the explicit form
         for venvs whose pip didn't drop the script wrapper (some
         conda layouts).

    The original PATH-resolved candidates remain as a fallback so a
    half-installed venv doesn't break a previously-working debug flow.
    No-op for non-Python specs and for empty ``venv_dir``.
    """
    if spec.language_id != String("python") \
            or len(venv_dir.as_bytes()) == 0:
        return spec
    var bin_dir = join_path(venv_dir, String("bin"))
    var venv_cands = List[AdapterCandidate]()
    var direct = join_path(bin_dir, String("debugpy-adapter"))
    var info_d = stat_file(direct)
    if info_d.ok and not info_d.is_dir():
        venv_cands.append(_argv1(direct))
    var py = join_path(bin_dir, String("python"))
    var info_p = stat_file(py)
    if info_p.ok and not info_p.is_dir():
        venv_cands.append(_argv3(py, String("-m"), String("debugpy.adapter")))
    if len(venv_cands) == 0:
        return spec
    var combined = venv_cands^
    for i in range(len(spec.candidates)):
        combined.append(spec.candidates[i])
    return DebuggerSpec(
        spec.language_id, combined^, spec.request_kind, spec.name,
    )


fn python_venv_has_debugpy(venv_dir: String) -> Bool:
    """Return True if ``venv_dir`` has debugpy importable.

    Two probes:

      1. ``<venv>/bin/debugpy-adapter`` — script wrapper from a normal
         ``pip install debugpy`` (the common case).
      2. ``<venv>/lib/python<X>.<Y>/site-packages/debugpy/`` — covers
         conda layouts where the script wrapper isn't dropped, and any
         other env where pip put the package directly.

    Both checks are filesystem-only (no subprocess), so this is cheap
    enough to call on every debug start. Empty ``venv_dir`` → False.
    """
    if len(venv_dir.as_bytes()) == 0:
        return False
    var bin_dir = join_path(venv_dir, String("bin"))
    var direct = join_path(bin_dir, String("debugpy-adapter"))
    var info_d = stat_file(direct)
    if info_d.ok and not info_d.is_dir():
        return True
    var lib_dir = join_path(venv_dir, String("lib"))
    var entries = list_directory(lib_dir)
    var prefix = String("python")
    var pb = prefix.as_bytes()
    for i in range(len(entries)):
        var name = entries[i]
        var nb = name.as_bytes()
        if len(nb) <= len(pb):
            continue
        var matches = True
        for k in range(len(pb)):
            if nb[k] != pb[k]:
                matches = False
                break
        if not matches:
            continue
        var pkg = join_path(
            join_path(join_path(lib_dir, name), String("site-packages")),
            String("debugpy"),
        )
        var info_pkg = stat_file(pkg)
        if info_pkg.ok and info_pkg.is_dir():
            return True
    return False


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
    """``debugpy``: ``program``-or-``module`` + ``args`` + ``cwd`` +
    ``console``.

    Targets that look like ``python <script> [...]`` or
    ``python -m <name> [...]`` get rewritten:

    * ``python script.py [args]`` → ``program: script.py, args: [args]``
    * ``python -m pytest [args]`` → ``module: pytest, args: [args]``

    debugpy's ``program`` field is for Python script paths and runpy's
    the file directly, so passing ``<venv>/bin/python`` would have it
    try to runpy the python binary (meaningless — that's what causes
    debugpy to stall on ``_run_code`` in ``runpy.py``). The rewrite is
    what lets a single ``python manage.py runserver`` or ``python -m
    pytest`` Run target be debugged without the user having to
    hand-author launch JSON.

    ``console: "internalConsole"`` keeps stdout/stderr coming back as
    DAP ``output`` events instead of being routed to a separate
    terminal — that's what we want, since we'll surface those events
    in the editor's debug pane.

    ``justMyCode: false`` exposes the full call chain. ``true`` (the
    debugpy default) is faster — it confines tracing to user code so
    the debuggee runs at near-native speed when no breakpoint is
    pending — but it also *hides library / stdlib frames from the
    stackTrace response*, even with ``format.includeAll: true``, so
    when you stop in your own code you can't see who called you from
    the framework / runtime side. The visibility loss outweighs the
    tracing-overhead win for the IDE use case: at a breakpoint the
    program is already paused, and the few extra milliseconds per
    function call between breakpoints is usually invisible to a
    human. Apps where it *does* matter (Django ``runserver`` serving
    real traffic under the debugger) are rare enough to be worth a
    future per-target opt-out.

    ``subProcess: true`` enables subprocess debugging. When the
    debuggee forks/execs, debugpy emits a ``debugpyAttach`` event
    with the host/port of a TCP listener the IDE connects to in
    order to debug the child. Frameworks that fork (Django
    ``runserver`` spawning the actual HTTP server, multiprocessing
    pools, pytest-xdist) need this — without subprocess attach the
    child blocks at startup waiting for the IDE that never arrives,
    so e.g. ``runserver``'s port never opens.
    """
    var module_name = String("")
    var script_program = String("")
    if _is_python_interpreter(program) and len(args) >= 1:
        if args[0] == String("-m") and len(args) >= 2:
            module_name = args[1]
            var rest = List[String]()
            for i in range(2, len(args)):
                rest.append(args[i])
            args = rest^
        elif not _starts_with_dash(args[0]):
            # ``python script.py [args...]`` → debug ``script.py`` with
            # the residual args as its argv. Skipped when ``args[0]``
            # starts with a flag (``-c``, ``-X opt``, ``-W ignore``, …)
            # since those need bespoke handling we don't do yet —
            # better to forward the unrewritten args and let debugpy
            # error explicitly than to silently drop a flag.
            script_program = args[0]
            var rest = List[String]()
            for i in range(1, len(args)):
                rest.append(args[i])
            args = rest^
    var o = json_object()
    if len(module_name.as_bytes()) > 0:
        o.put(String("module"), json_str(module_name))
    elif len(script_program.as_bytes()) > 0:
        o.put(String("program"), json_str(script_program))
    else:
        o.put(String("program"), json_str(program))
    o.put(String("cwd"), json_str(cwd))
    o.put(String("args"), _string_list_to_json(args^))
    o.put(String("console"), json_str(String("internalConsole")))
    o.put(String("stopOnEntry"), json_bool(stop_on_entry))
    o.put(String("justMyCode"), json_bool(False))
    o.put(String("subProcess"), json_bool(True))
    return o^


fn _starts_with_dash(s: String) -> Bool:
    var b = s.as_bytes()
    return len(b) > 0 and b[0] == 0x2D


fn _is_python_interpreter(program: String) -> Bool:
    """Return True if ``program``'s basename looks like a Python
    interpreter — ``python``, ``python3``, ``python3.11``, etc. Used
    to detect the ``python -m <module>`` idiom in run targets so a
    debug launch can be rewritten to debugpy's ``module`` mode.

    Filesystem-free: just inspects the path string. Won't be fooled
    by a binary literally named ``mypython``, since the prefix has
    to be ``python`` exactly at the start of the basename.
    """
    var pb = program.as_bytes()
    var n = len(pb)
    var start = n
    while start > 0 and pb[start - 1] != 0x2F:    # '/'
        start -= 1
    var basename_len = n - start
    var prefix = String("python")
    var pre_b = prefix.as_bytes()
    if basename_len < len(pre_b):
        return False
    for k in range(len(pre_b)):
        if pb[start + k] != pre_b[k]:
            return False
    # Trailing chars after "python" must be empty / digits / dots,
    # so ``python``, ``python3``, ``python3.11`` match but ``pythonw``
    # and ``python-config`` don't.
    for k in range(len(pre_b), basename_len):
        var c = pb[start + k]
        var is_digit = c >= 0x30 and c <= 0x39
        var is_dot = c == 0x2E
        if not (is_digit or is_dot):
            return False
    return True


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
