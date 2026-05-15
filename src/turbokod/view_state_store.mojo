"""Per-user, per-file view-state persistence, stored in
``<project>/.turbokod/per_user/<username>/view_states.json``.

Mirrors the ``breakpoint_store`` / ``session_store`` design — the
``Desktop`` keeps an in-memory list keyed by path, refreshes the
entries for currently-open file-backed editor windows on every paint,
and writes the JSON when the encoding differs from the last write.

The point of this store (beyond what ``session_store`` already
captures) is that closing a window loses its session entry on the
next paint — reopening the file without a per-file record would
land the user at the top of the buffer. Here the record survives the
close, so reopening restores the scroll and cursor exactly where the
user left them.

Format on disk::

    {
      "views": [
        { "path": "src/foo.mojo",
          "cursor": [42, 4],
          "scroll": [0, 30] }
      ]
    }

Paths inside the project root are stored relative to it (matching the
sibling stores) so the file survives moving the project directory. A
malformed or missing file silently yields an empty list.
"""

from std.collections.list import List
from std.ffi import external_call

from .file_io import join_path, read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_array, json_int, json_object, json_str,
    parse_json, json_get_int, json_get_string,
)
from .posix import getenv_value


comptime VS_DIR_PROJECT = String(".turbokod")
comptime VS_DIR_PER_USER = String("per_user")
comptime VS_FILE = String("view_states.json")


@fieldwise_init
struct StoredViewState(ImplicitlyCopyable, Movable):
    """One file's restorable view state. ``path`` is project-relative
    when the file lives inside the project root, absolute otherwise.
    ``cursor_row`` / ``cursor_col`` are 0-based; ``scroll_x`` /
    ``scroll_y`` are the top-left of the visible viewport in the
    editor's coordinate space — same fields as the Editor itself."""
    var path: String
    var cursor_row: Int
    var cursor_col: Int
    var scroll_x: Int
    var scroll_y: Int


def _current_username() -> String:
    var user = getenv_value(String("USER"))
    if len(user.as_bytes()) > 0:
        return user^
    var logname = getenv_value(String("LOGNAME"))
    if len(logname.as_bytes()) > 0:
        return logname^
    return String("default")


def _vs_dir(project_root: String) -> String:
    if len(project_root.as_bytes()) == 0:
        return String("")
    var d = join_path(project_root, VS_DIR_PROJECT)
    d = join_path(d, VS_DIR_PER_USER)
    return join_path(d, _current_username())


def _vs_path(project_root: String) -> String:
    var dir = _vs_dir(project_root)
    if len(dir.as_bytes()) == 0:
        return String("")
    return join_path(dir, VS_FILE)


def _ensure_dir(path: String):
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


def _ensure_dirs(project_root: String):
    if len(project_root.as_bytes()) == 0:
        return
    var top = join_path(project_root, VS_DIR_PROJECT)
    _ensure_dir(top)
    var per_user = join_path(top, VS_DIR_PER_USER)
    _ensure_dir(per_user)
    var user_dir = join_path(per_user, _current_username())
    _ensure_dir(user_dir)


def _vs_relative(project_root: String, full: String) -> String:
    var rb = project_root.as_bytes()
    var fb = full.as_bytes()
    if len(rb) == 0:
        return full
    if len(fb) <= len(rb) + 1:
        return full
    for k in range(len(rb)):
        if fb[k] != rb[k]:
            return full
    if fb[len(rb)] != 0x2F:
        return full
    return String(StringSlice(unsafe_from_utf8=fb[len(rb) + 1:]))


def _resolve_vs_path(project_root: String, stored: String) -> String:
    var b = stored.as_bytes()
    if len(b) == 0:
        return stored
    if b[0] == 0x2F:
        return stored
    if len(project_root.as_bytes()) == 0:
        return stored
    return join_path(project_root, stored)


def _read_int_pair(
    obj: JsonValue, key: String, fallback_a: Int, fallback_b: Int,
) -> Tuple[Int, Int]:
    var v = obj.object_get(key)
    if v and v.value().is_array() and v.value().array_len() == 2:
        var a_v = v.value().array_at(0)
        var b_v = v.value().array_at(1)
        if a_v.is_int() and b_v.is_int():
            return (a_v.as_int(), b_v.as_int())
    return (fallback_a, fallback_b)


def load_view_states(project_root: String) -> List[StoredViewState]:
    """Parse the per-user view-states file. Any failure (missing file,
    malformed JSON, missing keys) yields an empty list."""
    var out = List[StoredViewState]()
    var path = _vs_path(project_root)
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
    var arr_v = root.object_get(String("views"))
    if not arr_v or not arr_v.value().is_array():
        return out^
    var arr = arr_v.value().copy()
    for i in range(arr.array_len()):
        var node = arr.array_at(i)
        if not node.is_object():
            continue
        var raw_path = json_get_string(node, String("path"))
        if len(raw_path.as_bytes()) == 0:
            continue
        var resolved = _resolve_vs_path(project_root, raw_path)
        var cursor = _read_int_pair(node, String("cursor"), 0, 0)
        var scroll = _read_int_pair(node, String("scroll"), 0, 0)
        out.append(StoredViewState(
            resolved^, cursor[0], cursor[1], scroll[0], scroll[1],
        ))
    return out^


def _encode_int_pair(a: Int, b: Int) -> JsonValue:
    var arr = json_array()
    arr.append(json_int(a))
    arr.append(json_int(b))
    return arr^


def encode_view_states(
    project_root: String, views: List[StoredViewState],
) -> String:
    """Serialize ``views`` to the on-disk JSON form. Pure function —
    used both for the actual write and for change detection."""
    var root = json_object()
    var arr = json_array()
    for i in range(len(views)):
        var v = json_object()
        var rel = _vs_relative(project_root, views[i].path)
        v.put(String("path"), json_str(rel))
        v.put(
            String("cursor"),
            _encode_int_pair(views[i].cursor_row, views[i].cursor_col),
        )
        v.put(
            String("scroll"),
            _encode_int_pair(views[i].scroll_x, views[i].scroll_y),
        )
        arr.append(v^)
    root.put(String("views"), arr^)
    return encode_json(root) + String("\n")


def save_view_states(
    project_root: String, views: List[StoredViewState],
) -> Bool:
    """Rewrite the per-user view-states file. Creates the directory
    chain (``.turbokod/per_user/<username>``) if missing. Returns the
    underlying ``write_file`` success bool."""
    var path = _vs_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    _ensure_dirs(project_root)
    return write_file(path, encode_view_states(project_root, views))
