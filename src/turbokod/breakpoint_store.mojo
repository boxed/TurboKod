"""Per-user breakpoint persistence, stored in
``<project>/.turbokod/per_user/<username>/breakpoints.json``.

Mirrors the ``session_store`` design — encode the current breakpoint set
to JSON, write it, and seed a change-detection cache so we only re-write
when something actually changed. The ``per_user/<username>`` segment
keeps each developer's breakpoints separate so that an accidental
``git add .turbokod`` doesn't clobber a teammate's set.

Format on disk::

    {
      "breakpoints": [
        { "path": "src/foo.mojo", "line": 42, "condition": "i > 10",
          "enabled": true },
        { "path": "src/foo.mojo", "line": 87, "condition": "",
          "enabled": false }
      ]
    }

A missing ``enabled`` field is treated as ``true`` so files written
by older builds round-trip without surprising the user.

Paths inside the project root are stored relative to it (matching
``session_store``), so the file survives moving the project directory.
A malformed or missing file silently yields an empty list.
"""

from std.collections.list import List
from std.ffi import external_call

from .file_io import join_path, read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_object,
    json_str, parse_json,
    json_get_bool, json_get_int, json_get_string,
)
from .posix import getenv_value


comptime BP_DIR_PROJECT = String(".turbokod")
comptime BP_DIR_PER_USER = String("per_user")
comptime BP_FILE = String("breakpoints.json")


@fieldwise_init
struct StoredBreakpoint(ImplicitlyCopyable, Movable):
    """One breakpoint as it lives on disk. ``path`` is project-relative
    when the file lives inside the project root, absolute otherwise.
    ``line`` is 0-based — same convention as ``DapManager._bp_line``.
    ``condition`` is empty for unconditional breakpoints.
    ``enabled`` is False to skip the breakpoint without removing it —
    the gutter still shows it as a faint dot so the user knows it's
    parked there.
    ``wait_for`` identifies a *trigger* breakpoint as
    ``"<full-path>:<1-based-line>"`` — when set, this BP stays inert
    until the trigger fires once in the current session. Empty string
    means "no dependency" (the default). The trigger key uses absolute
    paths since the cross-BP reference doesn't survive the session
    save anyway: each session reloads breakpoints, the wait_for is
    only consulted while debugging, and absolute paths remove ambiguity
    between two files with the same basename."""
    var path: String
    var line: Int
    var condition: String
    var enabled: Bool
    var wait_for: String


fn _current_username() -> String:
    """Best-effort username for the per-user directory.

    Tries ``$USER`` then ``$LOGNAME`` — both are POSIX-standard. Falls
    back to ``"default"`` so we still produce a valid path on a machine
    that has somehow inherited an empty environment."""
    var user = getenv_value(String("USER"))
    if len(user.as_bytes()) > 0:
        return user^
    var logname = getenv_value(String("LOGNAME"))
    if len(logname.as_bytes()) > 0:
        return logname^
    return String("default")


fn _bp_dir(project_root: String) -> String:
    if len(project_root.as_bytes()) == 0:
        return String("")
    var d = join_path(project_root, BP_DIR_PROJECT)
    d = join_path(d, BP_DIR_PER_USER)
    return join_path(d, _current_username())


fn _bp_path(project_root: String) -> String:
    var dir = _bp_dir(project_root)
    if len(dir.as_bytes()) == 0:
        return String("")
    return join_path(dir, BP_FILE)


fn _ensure_dir(path: String):
    """Create ``path`` if missing. ``mkdir`` only creates one level, so
    we walk parents top-down to handle the ``per_user/<username>``
    nesting on first use."""
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


fn _ensure_dirs(project_root: String):
    if len(project_root.as_bytes()) == 0:
        return
    var top = join_path(project_root, BP_DIR_PROJECT)
    _ensure_dir(top)
    var per_user = join_path(top, BP_DIR_PER_USER)
    _ensure_dir(per_user)
    var user_dir = join_path(per_user, _current_username())
    _ensure_dir(user_dir)


fn _bp_relative(project_root: String, full: String) -> String:
    """Project-relative form of ``full`` when inside the project, else
    ``full`` unchanged. Identical algorithm to
    ``session_store._session_relative``."""
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


fn _resolve_bp_path(project_root: String, stored: String) -> String:
    """Anchor a relative ``stored`` path onto ``project_root``. Absolute
    paths and empty roots pass through unchanged."""
    var b = stored.as_bytes()
    if len(b) == 0:
        return stored
    if b[0] == 0x2F:
        return stored
    if len(project_root.as_bytes()) == 0:
        return stored
    return join_path(project_root, stored)


fn load_breakpoints(project_root: String) -> List[StoredBreakpoint]:
    """Parse the per-user breakpoints file. Any failure (missing file,
    malformed JSON, missing keys) yields an empty list — the caller
    distinguishes by checking ``len(out)``."""
    var out = List[StoredBreakpoint]()
    var path = _bp_path(project_root)
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
    var arr_v = root.object_get(String("breakpoints"))
    if not arr_v or not arr_v.value().is_array():
        return out^
    var arr = arr_v.value()
    for i in range(arr.array_len()):
        var node = arr.array_at(i)
        if not node.is_object():
            continue
        var raw_path = json_get_string(node, String("path"))
        if len(raw_path.as_bytes()) == 0:
            continue
        var line = json_get_int(node, String("line"), -1)
        if line < 0:
            continue
        var resolved = _resolve_bp_path(project_root, raw_path)
        var cond = json_get_string(node, String("condition"))
        # Missing ``enabled`` (older files, or hand-edited JSON) defaults
        # to True — preserves prior behaviour of always-firing BPs.
        var en = json_get_bool(node, String("enabled"), True)
        # Missing ``wait_for`` defaults to empty (no dependency) so
        # files written by older builds round-trip without surprising
        # the user.
        var wait = json_get_string(node, String("wait_for"))
        out.append(StoredBreakpoint(resolved^, line, cond^, en, wait^))
    return out^


fn encode_breakpoints(
    project_root: String, breakpoints: List[StoredBreakpoint],
) -> String:
    """Serialize ``breakpoints`` to the on-disk JSON form. Pure function
    — used both for the actual write and for change detection."""
    var root = json_object()
    var arr = json_array()
    for i in range(len(breakpoints)):
        var bp = json_object()
        var rel = _bp_relative(project_root, breakpoints[i].path)
        bp.put(String("path"), json_str(rel))
        bp.put(String("line"), json_int(breakpoints[i].line))
        bp.put(String("condition"), json_str(breakpoints[i].condition))
        bp.put(String("enabled"), json_bool(breakpoints[i].enabled))
        # Only emit ``wait_for`` when set, so a file written from a
        # session that never used the feature stays as compact as
        # before — and a hand-edited JSON without the field still
        # round-trips byte-identically through the next save.
        if len(breakpoints[i].wait_for.as_bytes()) > 0:
            bp.put(
                String("wait_for"), json_str(breakpoints[i].wait_for),
            )
        arr.append(bp^)
    root.put(String("breakpoints"), arr^)
    return encode_json(root) + String("\n")


fn save_breakpoints(
    project_root: String, breakpoints: List[StoredBreakpoint],
) -> Bool:
    """Rewrite the per-user breakpoints file. Creates the directory
    chain (``.turbokod/per_user/<username>``) if missing. Returns the
    underlying ``write_file`` success bool."""
    var path = _bp_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    _ensure_dirs(project_root)
    return write_file(path, encode_breakpoints(project_root, breakpoints))
