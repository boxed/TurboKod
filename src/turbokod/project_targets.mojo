"""Per-project run/debug target definitions, persisted in
``<project>/.turbokod/targets.json``.

A target is a named action the user can run (Cmd+R) or debug (Cmd+D).
Run and debug share the same shape — they're the same program,
launched two different ways:

* ``name`` — the short label that shows up as a tab in the status bar.
* ``program`` — the executable / script to launch. Resolved relative
  to the working directory: ``"app.py"`` with ``cwd: "src"`` becomes
  ``<project>/src/app.py``. Absolute paths are used as-is.
* ``args`` — argv passed to the program. List of strings.
* ``cwd`` — working directory. Empty means the project root.
  Relative paths are joined onto the project root so a config can
  read ``"cwd": "src"`` without spelling out the absolute path.
* ``debug_language`` — language id (matches ``DebuggerSpec.language_id``)
  used to pick the DAP adapter for the debug action. Empty disables
  Cmd+D for that target.

Format on disk::

    {
      "active": "tests",
      "targets": [
        { "name":     "tests",
          "program":  "tests/run.py",
          "args":     ["--verbose"],
          "cwd":      "",
          "language": "python" }
      ]
    }

Anything missing falls back to defaults. A malformed file silently
yields an empty list — the editor still works without a config.

For backwards compatibility the loader still accepts the old
``"run"`` / ``"debug": {"program", "args", "language"}`` shape;
those fields are merged into the unified ``program`` / ``args`` /
``debug_language`` slots so old configs keep working until the user
re-saves through the dialog.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .file_io import join_path, read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_array, json_object, json_str,
    parse_json,
)
from std.ffi import external_call


comptime TURBOKOD_DIR    = String(".turbokod")
comptime TARGETS_FILE    = String("targets.json")


struct RunTarget(ImplicitlyCopyable, Movable):
    """One named build/run/debug target.

    ``name`` doubles as the identity key — list lookups and the
    ``active`` field both compare on it. Two targets with the same
    name in one config is undefined behaviour; we don't validate.

    ``program`` + ``args`` are shared between Cmd+R (run) and Cmd+D
    (debug). The same binary is invoked both ways; only the
    surrounding plumbing (subprocess capture vs. DAP adapter) differs.
    """
    var name: String
    var program: String
    var args: List[String]
    var cwd: String
    var debug_language: String

    fn __init__(out self):
        self.name = String("")
        self.program = String("")
        self.args = List[String]()
        self.cwd = String("")
        self.debug_language = String("")

    fn __copyinit__(out self, copy: Self):
        self.name = copy.name
        self.program = copy.program
        self.args = copy.args.copy()
        self.cwd = copy.cwd
        self.debug_language = copy.debug_language


struct ProjectTargets(Movable):
    """Loaded targets list + the user's currently selected one.

    ``active`` is an index into ``targets``, or -1 when the list is
    empty. Persisted as a name (so reordering the list doesn't shift
    the user's selection out from under them).
    """
    var targets: List[RunTarget]
    var active: Int

    fn __init__(out self):
        self.targets = List[RunTarget]()
        self.active = -1

    fn __copyinit__(out self, copy: Self):
        self.targets = copy.targets.copy()
        self.active = copy.active

    fn has_active(self) -> Bool:
        return self.active >= 0 and self.active < len(self.targets)

    fn current(self) -> Optional[RunTarget]:
        if not self.has_active():
            return Optional[RunTarget]()
        return Optional[RunTarget](self.targets[self.active])

    fn set_active_by_name(mut self, name: String) -> Bool:
        for i in range(len(self.targets)):
            if self.targets[i].name == name:
                self.active = i
                return True
        return False

    fn set_active_index(mut self, idx: Int) -> Bool:
        if idx < 0 or idx >= len(self.targets):
            return False
        self.active = idx
        return True


fn _targets_dir(project_root: String) -> String:
    if len(project_root.as_bytes()) == 0:
        return String("")
    return join_path(project_root, TURBOKOD_DIR)


fn _targets_path(project_root: String) -> String:
    var dir = _targets_dir(project_root)
    if len(dir.as_bytes()) == 0:
        return String("")
    return join_path(dir, TARGETS_FILE)


fn _ensure_dir(path: String):
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


fn _string_array(value: JsonValue) -> List[String]:
    var out = List[String]()
    if not value.is_array():
        return out^
    for i in range(value.array_len()):
        var item = value.array_at(i)
        if item.is_string():
            out.append(item.as_str())
    return out^


fn _string_field(obj: JsonValue, key: String) -> String:
    var v = obj.object_get(key)
    if v and v.value().is_string():
        return v.value().as_str()
    return String("")


fn _parse_target(node: JsonValue) -> RunTarget:
    """Parse one target node. Accepts both the new flat shape
    (``program`` / ``args`` / ``language``) and the legacy nested
    shape (``run`` / ``debug.{program, args, language}``); fields
    from either form land in the same in-memory slots, so old
    configs keep loading until the user re-saves.

    When both shapes are present we prefer the new flat keys —
    they're what the dialog writes, so a config that has *both* set
    is mid-migration and the flat values are the authoritative ones.
    """
    var t = RunTarget()
    if not node.is_object():
        return t^
    t.name = _string_field(node, String("name"))
    t.cwd = _string_field(node, String("cwd"))
    # New shape — flat keys.
    t.program = _string_field(node, String("program"))
    var args_v = node.object_get(String("args"))
    if args_v:
        t.args = _string_array(args_v.value())
    t.debug_language = _string_field(node, String("language"))
    # Legacy fallback. ``run`` was a shell command string; we drop
    # any space-separated args into ``args`` for backward compat —
    # not perfect for shell-quoted strings but covers the common
    # case (``"run": "python -m foo --verbose"``).
    if len(t.program.as_bytes()) == 0:
        var run_v = node.object_get(String("run"))
        if run_v and run_v.value().is_string():
            var parts = _split_command(run_v.value().as_str())
            if len(parts) > 0:
                t.program = parts[0]
                if len(t.args) == 0:
                    var rest = List[String]()
                    for k in range(1, len(parts)):
                        rest.append(parts[k])
                    t.args = rest^
    var debug_v = node.object_get(String("debug"))
    if debug_v and debug_v.value().is_object():
        if len(t.debug_language.as_bytes()) == 0:
            t.debug_language = _string_field(
                debug_v.value(), String("language"),
            )
        if len(t.program.as_bytes()) == 0:
            t.program = _string_field(debug_v.value(), String("program"))
        if len(t.args) == 0:
            var dargs_v = debug_v.value().object_get(String("args"))
            if dargs_v:
                t.args = _string_array(dargs_v.value())
    return t^


fn _split_command(s: String) -> List[String]:
    """Whitespace-split ``s`` into argv-shaped pieces. Used only by
    the legacy ``run`` migration path — modern configs go through
    the flat ``program`` / ``args`` keys and never hit this."""
    var out = List[String]()
    var b = s.as_bytes()
    var n = len(b)
    var start = 0
    var i = 0
    while i < n:
        if b[i] == 0x20 or b[i] == 0x09:
            if i > start:
                out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    if start < n:
        out.append(String(StringSlice(unsafe_from_utf8=b[start:n])))
    return out^


fn load_project_targets(project_root: String) -> ProjectTargets:
    """Load ``<project>/.turbokod/targets.json``. Returns an empty list
    on any failure (missing dir, malformed JSON, missing keys)."""
    var out = ProjectTargets()
    var path = _targets_path(project_root)
    if len(path.as_bytes()) == 0:
        return out^
    var info = stat_file(path)
    if not info.ok:
        return out^
    var text: String
    try:
        text = read_file(path)
    except:
        return out^
    var root: JsonValue
    try:
        root = parse_json(text)
    except:
        return out^
    if not root.is_object():
        return out^
    var arr_v = root.object_get(String("targets"))
    if not arr_v or not arr_v.value().is_array():
        return out^
    var arr = arr_v.value()
    for i in range(arr.array_len()):
        var t = _parse_target(arr.array_at(i))
        if len(t.name.as_bytes()) == 0:
            continue
        out.targets.append(t^)
    if len(out.targets) == 0:
        return out^
    out.active = 0
    var active_v = root.object_get(String("active"))
    if active_v and active_v.value().is_string():
        _ = out.set_active_by_name(active_v.value().as_str())
    return out^


fn _encode_target(t: RunTarget) -> JsonValue:
    """Encode one target as a JSON object using the new flat shape.

    Only populated fields are emitted; empty ``cwd`` /
    ``debug_language`` / empty ``args`` are dropped so a minimal
    target stays a small ``{name, program}`` pair on disk.
    """
    var obj = json_object()
    obj.put(String("name"), json_str(t.name))
    obj.put(String("program"), json_str(t.program))
    if len(t.args) > 0:
        var args_arr = json_array()
        for k in range(len(t.args)):
            args_arr.append(json_str(t.args[k]))
        obj.put(String("args"), args_arr^)
    if len(t.cwd.as_bytes()) > 0:
        obj.put(String("cwd"), json_str(t.cwd))
    if len(t.debug_language.as_bytes()) > 0:
        obj.put(String("language"), json_str(t.debug_language))
    return obj^


fn write_all_targets(
    project_root: String, targets: ProjectTargets,
) -> Bool:
    """Rewrite ``<project>/.turbokod/targets.json`` from scratch with
    the full in-memory ``targets`` list. Used by the targets dialog
    after the user adds / removes / edits any field — anything less
    than a full rewrite would let stale entries linger on disk.

    Always writes the new flat shape — legacy ``run`` / ``debug``
    keys won't survive a save, which is the migration path.
    """
    var path = _targets_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    _ensure_dir(_targets_dir(project_root))
    var active_name = String("")
    if targets.has_active():
        active_name = targets.targets[targets.active].name
    var root = json_object()
    root.put(String("active"), json_str(active_name))
    var arr = json_array()
    for i in range(len(targets.targets)):
        arr.append(_encode_target(targets.targets[i]))
    root.put(String("targets"), arr^)
    return write_file(path, encode_json(root) + String("\n"))


fn save_project_targets(
    project_root: String, targets: ProjectTargets,
) -> Bool:
    """Persist the currently active selection to disk. Creates the
    ``.turbokod`` directory if needed. Targets list contents themselves
    aren't rewritten — we only update the ``active`` pointer, leaving
    user-authored fields (comments, key order) untouched.

    The simpler-than-it-looks approach: re-parse the existing file,
    swap its ``active`` field, re-encode. If the file doesn't exist
    yet (rare; the user has to have authored some target list to
    have something to switch *between*), we write a minimal stub.
    """
    var path = _targets_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    _ensure_dir(_targets_dir(project_root))
    var active_name = String("")
    if targets.has_active():
        active_name = targets.targets[targets.active].name
    var info = stat_file(path)
    if info.ok:
        var text: String
        try:
            text = read_file(path)
        except:
            text = String("")
        var root: JsonValue
        try:
            root = parse_json(text)
        except:
            root = json_object()
        if not root.is_object():
            root = json_object()
        root.put(String("active"), json_str(active_name))
        # Preserve the existing ``targets`` array; if absent, write an
        # empty one rather than dropping the key.
        var existing_arr = root.object_get(String("targets"))
        if not existing_arr:
            root.put(String("targets"), json_array())
        return write_file(path, encode_json(root) + String("\n"))
    var stub = json_object()
    stub.put(String("active"), json_str(active_name))
    var arr = json_array()
    for i in range(len(targets.targets)):
        arr.append(_encode_target(targets.targets[i]))
    stub.put(String("targets"), arr^)
    return write_file(path, encode_json(stub) + String("\n"))


fn resolved_cwd(project_root: String, target_cwd: String) -> String:
    """Pick the cwd for a target invocation: the target's ``cwd`` if
    set, otherwise the project root. A ``cwd`` that doesn't start with
    ``/`` is joined onto the project root so users can write
    ``"cwd": "subdir"`` without spelling out the absolute path."""
    if len(target_cwd.as_bytes()) == 0:
        return project_root
    var b = target_cwd.as_bytes()
    if len(b) > 0 and b[0] == 0x2F:
        return target_cwd
    return join_path(project_root, target_cwd)


fn resolved_program(
    project_root: String, target_cwd: String, program: String,
) -> String:
    """Resolve ``program`` relative to the *working directory*, not
    the project root.

    The mental model: a target says "from this directory, run this
    binary". Relative ``program`` therefore anchors on the resolved
    cwd, so ``cwd: "build", program: "app"`` runs ``<project>/build/app``
    rather than ``<project>/app``. Absolute paths are passed through
    unchanged.
    """
    if len(program.as_bytes()) == 0:
        return program
    var b = program.as_bytes()
    if len(b) > 0 and b[0] == 0x2F:
        return program
    var cwd = resolved_cwd(project_root, target_cwd)
    return join_path(cwd, program)
