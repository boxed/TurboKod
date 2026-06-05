"""Per-project on-save actions, persisted in
``<project>/.turbokod/on_save.json``.

On-save actions are a *global library* (``TurbokodConfig.on_save_actions``)
that the user enables per project. Enabling an action **copies** its
definition into this file — a frozen snapshot — and only a project's own
copies run after a save there. Editing the library entry later does not
touch a project that already enabled it; the edited version instead shows
up as a fresh "suggestion" row in Project Settings next to the project's
still-enabled frozen copy.

Format on disk — the same shape ``config.mojo`` uses for the global list::

    {
      "actions": [
        { "language_id": "python",
          "program":     "/usr/local/bin/black",
          "args":        ["--quiet", "$FilePath$"],
          "cwd":         "" }
      ]
    }

Missing file / malformed JSON / missing keys all degrade to an empty list
— a project with no on-save config simply runs nothing on save.
"""

from std.collections.list import List
from std.ffi import external_call

from .config import OnSaveAction
from .file_io import join_path, read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_array, json_get_string,
    json_get_string_array, json_object, json_str, parse_json,
)


comptime _TURBOKOD_DIR  = String(".turbokod")
comptime _ON_SAVE_FILE   = String("on_save.json")


def _args_equal(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def on_save_equal(a: OnSaveAction, b: OnSaveAction) -> Bool:
    """Structural identity for on-save actions: equal across all four
    fields. ``OnSaveAction`` carries no id key, so this is what decides
    a Project-Settings checkbox state (is a library entry already in the
    project?), an enable/disable toggle, and library back-fill dedup. A
    copied-then-reloaded entry compares equal to its library original,
    which is what keeps the frozen-snapshot model coherent."""
    return (
        a.language_id == b.language_id
        and a.program == b.program
        and a.cwd == b.cwd
        and _args_equal(a.args, b.args)
    )


def _on_save_dir(project_root: String) -> String:
    if len(project_root.as_bytes()) == 0:
        return String("")
    return join_path(project_root, _TURBOKOD_DIR)


def _on_save_path(project_root: String) -> String:
    var dir = _on_save_dir(project_root)
    if len(dir.as_bytes()) == 0:
        return String("")
    return join_path(dir, _ON_SAVE_FILE)


def _ensure_dir(path: String):
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


def load_project_on_save(project_root: String) -> List[OnSaveAction]:
    """Load ``<project>/.turbokod/on_save.json``. Returns an empty list on
    any failure (no project, missing file, malformed JSON, missing keys)."""
    var out = List[OnSaveAction]()
    var path = _on_save_path(project_root)
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
    var arr_v = root.object_get(String("actions"))
    if not arr_v or not arr_v.value().is_array():
        return out^
    var arr = arr_v.value().copy()
    for i in range(arr.array_len()):
        var item = arr.array_at(i)
        if not item.is_object():
            continue
        var act = OnSaveAction()
        act.language_id = json_get_string(item, String("language_id"))
        act.program = json_get_string(item, String("program"))
        act.args = json_get_string_array(item, String("args"))
        act.cwd = json_get_string(item, String("cwd"))
        if len(act.program.as_bytes()) == 0:
            continue
        out.append(act^)
    return out^


def write_project_on_save(
    project_root: String, actions: List[OnSaveAction],
) -> Bool:
    """Rewrite ``<project>/.turbokod/on_save.json`` from ``actions``.

    Full rewrite (like ``write_all_targets``) — the project file is the
    derived projection of the enabled set, so a stale entry must not
    linger. Rows with an empty ``program`` are dropped (the section can
    hold half-filled state mid-edit). Returns False when there's no
    project root or the write fails."""
    var path = _on_save_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    _ensure_dir(_on_save_dir(project_root))
    var arr = json_array()
    for i in range(len(actions)):
        var act = actions[i].copy()
        if len(act.program.as_bytes()) == 0:
            continue
        var obj = json_object()
        obj.put(String("language_id"), json_str(act.language_id))
        obj.put(String("program"), json_str(act.program))
        var aarr = json_array()
        for k in range(len(act.args)):
            aarr.append(json_str(act.args[k]))
        obj.put(String("args"), aarr^)
        obj.put(String("cwd"), json_str(act.cwd))
        arr.append(obj^)
    var root = json_object()
    root.put(String("actions"), arr^)
    return write_file(path, encode_json(root) + String("\n"))
