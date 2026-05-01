"""Per-project run/debug target definitions, persisted in
``<project>/.turbokod/targets.json``.

A target is a named action the user can run (Cmd+R) or debug (Cmd+D).
Each target carries:

* ``name`` — the short label that shows up as a tab in the status bar.
* ``run_command`` — a shell command (``sh -c``) executed by the run
  manager. Free-form so a target can call ``pixi run …``, ``cargo
  test``, ``./run.sh examples/foo.mojo``, etc.
* ``debug_language`` — language id (matches ``DebuggerSpec.language_id``)
  used to pick the DAP adapter for the debug action. Empty disables
  debug for that target.
* ``debug_program`` — path passed as ``program`` in the launch
  arguments. Resolved relative to the project root if not absolute.
* ``debug_args`` — argv passed to the debugged program.
* ``cwd`` — working directory for both run and debug. Empty means the
  project root.

Format on disk::

    {
      "active": "tests",
      "targets": [
        { "name": "tests",
          "run":   "pixi run test",
          "debug": { "language": "python",
                     "program":  "tests/run.py",
                     "args":     ["--verbose"] } }
      ]
    }

Anything missing falls back to defaults. A malformed file silently
yields an empty list — the editor still works without a config.
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
    name in one config is undefined behavior; we don't validate.
    """
    var name: String
    var run_command: String
    var debug_language: String
    var debug_program: String
    var debug_args: List[String]
    var cwd: String

    fn __init__(out self):
        self.name = String("")
        self.run_command = String("")
        self.debug_language = String("")
        self.debug_program = String("")
        self.debug_args = List[String]()
        self.cwd = String("")

    fn __copyinit__(out self, copy: Self):
        self.name = copy.name
        self.run_command = copy.run_command
        self.debug_language = copy.debug_language
        self.debug_program = copy.debug_program
        self.debug_args = copy.debug_args.copy()
        self.cwd = copy.cwd


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
    var t = RunTarget()
    if not node.is_object():
        return t^
    t.name = _string_field(node, String("name"))
    # ``run`` is the canonical key; accept ``run_command`` as a synonym
    # so a hand-edited config that mirrors the in-memory field name
    # still loads.
    var run_v = node.object_get(String("run"))
    if run_v and run_v.value().is_string():
        t.run_command = run_v.value().as_str()
    else:
        t.run_command = _string_field(node, String("run_command"))
    t.cwd = _string_field(node, String("cwd"))
    var debug_v = node.object_get(String("debug"))
    if debug_v and debug_v.value().is_object():
        t.debug_language = _string_field(debug_v.value(), String("language"))
        t.debug_program  = _string_field(debug_v.value(), String("program"))
        var args_v = debug_v.value().object_get(String("args"))
        if args_v:
            t.debug_args = _string_array(args_v.value())
    return t^


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
        var t = targets.targets[i]
        var obj = json_object()
        obj.put(String("name"), json_str(t.name))
        obj.put(String("run"), json_str(t.run_command))
        if len(t.cwd.as_bytes()) > 0:
            obj.put(String("cwd"), json_str(t.cwd))
        if len(t.debug_language.as_bytes()) > 0:
            var dbg = json_object()
            dbg.put(String("language"), json_str(t.debug_language))
            if len(t.debug_program.as_bytes()) > 0:
                dbg.put(String("program"), json_str(t.debug_program))
            if len(t.debug_args) > 0:
                var args_arr = json_array()
                for k in range(len(t.debug_args)):
                    args_arr.append(json_str(t.debug_args[k]))
                obj.put(String("args"), args_arr^)
            obj.put(String("debug"), dbg^)
        arr.append(obj^)
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


fn resolved_program(project_root: String, target_program: String) -> String:
    """Same anchoring rule as ``resolved_cwd`` but for the debug
    ``program`` field — relative paths anchor at the project root."""
    if len(target_program.as_bytes()) == 0:
        return target_program
    var b = target_program.as_bytes()
    if len(b) > 0 and b[0] == 0x2F:
        return target_program
    return join_path(project_root, target_program)
