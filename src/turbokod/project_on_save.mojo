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

from .per_user_store import project_config_path, write_project_config_json
from .config import OnSaveAction
from .file_io import load_json_array
from .json import json_array, json_object


comptime _ON_SAVE_FILE   = String("on_save.json")


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
        and a.args == b.args
    )


def _on_save_path(project_root: String) -> String:
    return project_config_path(project_root, _ON_SAVE_FILE)


def load_project_on_save(project_root: String) -> List[OnSaveAction]:
    """Load ``<project>/.turbokod/on_save.json``. Returns an empty list on
    any failure (no project, missing file, malformed JSON, missing keys)."""
    var out = List[OnSaveAction]()
    var path = _on_save_path(project_root)
    if len(path.as_bytes()) == 0:
        return out^
    var arr = load_json_array(path, String("actions"))
    for i in range(arr.array_len()):
        var item = arr.array_at(i)
        if not item.is_object():
            continue
        var act = OnSaveAction.from_json(item)
        if len(act.program.as_bytes()) > 0:
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
    var arr = json_array()
    for ref act in actions:
        if len(act.program.as_bytes()) > 0:
            arr.append(act.to_json())
    var root = json_object()
    root.put(String("actions"), arr)
    return write_project_config_json(project_root, _ON_SAVE_FILE, root)
