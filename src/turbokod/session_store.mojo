"""Per-project window session, persisted in
``<project>/.turbokod/session.json``.

Captures the list of file-backed editor windows currently open, their
geometry (rect + maximized state + restore rect), per-buffer view state
(cursor row/col, scroll), the z-order, and which window is focused.
Restored when the project is opened with no current windows so the user
lands back where they left off.

Format on disk::

    {
      "focused": 1,
      "z_order": [0, 2, 1],
      "windows": [
        { "path": "src/foo.mojo",
          "rect": [10, 5, 70, 25],
          "maximized": false,
          "restore_rect": [10, 5, 70, 25],
          "cursor": [12, 4],
          "scroll": [0, 0] }
      ]
    }

Paths inside the project root are stored relative to it; anything
outside (or unresolvable) is stored absolute. A malformed or missing
file silently yields an empty session — the editor still works and
just doesn't restore anything.
"""

from std.collections.list import List
from std.ffi import external_call

from .file_io import (
    join_path, read_file, stat_file, write_file,
)
from .json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_object,
    json_str, parse_json,
)


comptime SESSION_DIR  = String(".turbokod")
comptime SESSION_FILE = String("session.json")


struct SessionWindow(ImplicitlyCopyable, Movable):
    """One file-backed editor window's restorable state.

    ``path`` is project-relative when the file lives inside the project
    root, absolute otherwise — picked at save time by
    ``_session_relative``. ``restore_rect`` is the rect to fall back to
    when the user un-maximizes; for a non-maximized window it equals
    ``rect``.
    """
    var path: String
    var rect_a_x: Int
    var rect_a_y: Int
    var rect_b_x: Int
    var rect_b_y: Int
    var is_maximized: Bool
    var restore_a_x: Int
    var restore_a_y: Int
    var restore_b_x: Int
    var restore_b_y: Int
    var cursor_row: Int
    var cursor_col: Int
    var scroll_x: Int
    var scroll_y: Int

    fn __init__(out self):
        self.path = String("")
        self.rect_a_x = 0
        self.rect_a_y = 0
        self.rect_b_x = 0
        self.rect_b_y = 0
        self.is_maximized = False
        self.restore_a_x = 0
        self.restore_a_y = 0
        self.restore_b_x = 0
        self.restore_b_y = 0
        self.cursor_row = 0
        self.cursor_col = 0
        self.scroll_x = 0
        self.scroll_y = 0

    fn __copyinit__(out self, copy: Self):
        self.path = copy.path
        self.rect_a_x = copy.rect_a_x
        self.rect_a_y = copy.rect_a_y
        self.rect_b_x = copy.rect_b_x
        self.rect_b_y = copy.rect_b_y
        self.is_maximized = copy.is_maximized
        self.restore_a_x = copy.restore_a_x
        self.restore_a_y = copy.restore_a_y
        self.restore_b_x = copy.restore_b_x
        self.restore_b_y = copy.restore_b_y
        self.cursor_row = copy.cursor_row
        self.cursor_col = copy.cursor_col
        self.scroll_x = copy.scroll_x
        self.scroll_y = copy.scroll_y


struct Session(Movable):
    """Snapshot of the windows in a project, plus z-order and focus.

    ``z_order`` and ``focused`` index into ``windows``. Both default to
    "natural order" / "last window" when the persisted file omits them
    or carries stale indices.
    """
    var windows: List[SessionWindow]
    var z_order: List[Int]
    var focused: Int

    fn __init__(out self):
        self.windows = List[SessionWindow]()
        self.z_order = List[Int]()
        self.focused = -1

    fn __copyinit__(out self, copy: Self):
        self.windows = copy.windows.copy()
        self.z_order = copy.z_order.copy()
        self.focused = copy.focused


fn _session_dir(project_root: String) -> String:
    if len(project_root.as_bytes()) == 0:
        return String("")
    return join_path(project_root, SESSION_DIR)


fn _session_path(project_root: String) -> String:
    var dir = _session_dir(project_root)
    if len(dir.as_bytes()) == 0:
        return String("")
    return join_path(dir, SESSION_FILE)


fn _ensure_dir(path: String):
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


fn _has_prefix(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


fn _session_relative(project_root: String, full: String) -> String:
    """Project-relative form of ``full``, or ``full`` unchanged when the
    file lives outside the project. Mirrors ``_project_relative`` in
    ``project.mojo`` but used at save time so the on-disk session
    survives moving the project directory."""
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


fn _resolve_session_path(project_root: String, stored: String) -> String:
    """Inverse of ``_session_relative``: anchor a stored relative path
    onto the project root. Absolute paths and empty roots pass
    through. ``..``-prefixed entries are kept as-is — the user is
    presumed to have authored them deliberately if any."""
    var b = stored.as_bytes()
    if len(b) == 0:
        return stored
    if b[0] == 0x2F:        # absolute
        return stored
    if len(project_root.as_bytes()) == 0:
        return stored
    return join_path(project_root, stored)


fn _int_field(obj: JsonValue, key: String, default: Int) -> Int:
    var v = obj.object_get(key)
    if v and v.value().is_int():
        return v.value().as_int()
    return default


fn _bool_field(obj: JsonValue, key: String, default: Bool) -> Bool:
    var v = obj.object_get(key)
    if v and v.value().is_bool():
        return v.value().as_bool()
    return default


fn _string_field(obj: JsonValue, key: String) -> String:
    var v = obj.object_get(key)
    if v and v.value().is_string():
        return v.value().as_str()
    return String("")


fn _int_array(value: JsonValue) -> List[Int]:
    var out = List[Int]()
    if not value.is_array():
        return out^
    for i in range(value.array_len()):
        var item = value.array_at(i)
        if item.is_int():
            out.append(item.as_int())
    return out^


fn _read_int_pair(
    obj: JsonValue, key: String, fallback_a: Int, fallback_b: Int,
) -> Tuple[Int, Int]:
    var v = obj.object_get(key)
    if v and v.value().is_array() and v.value().array_len() == 2:
        var a_v = v.value().array_at(0)
        var b_v = v.value().array_at(1)
        if a_v.is_int() and b_v.is_int():
            return (a_v.as_int(), b_v.as_int())
    return (fallback_a, fallback_b)


fn _read_int_quad(
    obj: JsonValue, key: String,
    fa: Int, fb: Int, fc: Int, fd: Int,
) -> Tuple[Int, Int, Int, Int]:
    var v = obj.object_get(key)
    if v and v.value().is_array() and v.value().array_len() == 4:
        var a = v.value().array_at(0)
        var b = v.value().array_at(1)
        var c = v.value().array_at(2)
        var d = v.value().array_at(3)
        if a.is_int() and b.is_int() and c.is_int() and d.is_int():
            return (a.as_int(), b.as_int(), c.as_int(), d.as_int())
    return (fa, fb, fc, fd)


fn _parse_session_window(node: JsonValue) -> SessionWindow:
    var w = SessionWindow()
    if not node.is_object():
        return w^
    w.path = _string_field(node, String("path"))
    var rect = _read_int_quad(node, String("rect"), 0, 0, 0, 0)
    w.rect_a_x = rect[0]
    w.rect_a_y = rect[1]
    w.rect_b_x = rect[2]
    w.rect_b_y = rect[3]
    w.is_maximized = _bool_field(node, String("maximized"), False)
    var restore = _read_int_quad(
        node, String("restore_rect"),
        w.rect_a_x, w.rect_a_y, w.rect_b_x, w.rect_b_y,
    )
    w.restore_a_x = restore[0]
    w.restore_a_y = restore[1]
    w.restore_b_x = restore[2]
    w.restore_b_y = restore[3]
    var cursor = _read_int_pair(node, String("cursor"), 0, 0)
    w.cursor_row = cursor[0]
    w.cursor_col = cursor[1]
    var scroll = _read_int_pair(node, String("scroll"), 0, 0)
    w.scroll_x = scroll[0]
    w.scroll_y = scroll[1]
    return w^


fn load_session(project_root: String) -> Session:
    """Parse ``<project>/.turbokod/session.json``. Any failure (missing
    file, malformed JSON, missing keys) yields an empty session — the
    caller distinguishes by checking ``len(session.windows)``."""
    var out = Session()
    var path = _session_path(project_root)
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
    var arr_v = root.object_get(String("windows"))
    if not arr_v or not arr_v.value().is_array():
        return out^
    var arr = arr_v.value()
    for i in range(arr.array_len()):
        var w = _parse_session_window(arr.array_at(i))
        if len(w.path.as_bytes()) == 0:
            continue
        out.windows.append(w^)
    if len(out.windows) == 0:
        return out^
    var z_v = root.object_get(String("z_order"))
    if z_v:
        out.z_order = _int_array(z_v.value())
    out.focused = _int_field(root, String("focused"), -1)
    if out.focused < 0 or out.focused >= len(out.windows):
        out.focused = len(out.windows) - 1
    return out^


fn _encode_int_pair(a: Int, b: Int) -> JsonValue:
    var arr = json_array()
    arr.append(json_int(a))
    arr.append(json_int(b))
    return arr^


fn _encode_int_quad(a: Int, b: Int, c: Int, d: Int) -> JsonValue:
    var arr = json_array()
    arr.append(json_int(a))
    arr.append(json_int(b))
    arr.append(json_int(c))
    arr.append(json_int(d))
    return arr^


fn _encode_session_window(w: SessionWindow) -> JsonValue:
    var obj = json_object()
    obj.put(String("path"), json_str(w.path))
    obj.put(
        String("rect"),
        _encode_int_quad(w.rect_a_x, w.rect_a_y, w.rect_b_x, w.rect_b_y),
    )
    obj.put(String("maximized"), json_bool(w.is_maximized))
    obj.put(
        String("restore_rect"),
        _encode_int_quad(
            w.restore_a_x, w.restore_a_y, w.restore_b_x, w.restore_b_y,
        ),
    )
    obj.put(String("cursor"), _encode_int_pair(w.cursor_row, w.cursor_col))
    obj.put(String("scroll"), _encode_int_pair(w.scroll_x, w.scroll_y))
    return obj^


fn encode_session(session: Session) -> String:
    """Serialize ``session`` to the on-disk JSON form. Pure function —
    used both for the actual write and for change detection (the
    Desktop caches the previous encoding and only writes when the new
    one differs)."""
    var root = json_object()
    root.put(String("focused"), json_int(session.focused))
    var z = json_array()
    for i in range(len(session.z_order)):
        z.append(json_int(session.z_order[i]))
    root.put(String("z_order"), z^)
    var arr = json_array()
    for i in range(len(session.windows)):
        arr.append(_encode_session_window(session.windows[i]))
    root.put(String("windows"), arr^)
    return encode_json(root) + String("\n")


fn save_session(project_root: String, session: Session) -> Bool:
    """Rewrite ``<project>/.turbokod/session.json`` from ``session``.
    Creates the ``.turbokod`` directory if missing. Returns the
    underlying ``write_file`` success bool — the Desktop ignores
    failures (the user can keep editing; we'll just retry next paint)."""
    var path = _session_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    _ensure_dir(_session_dir(project_root))
    return write_file(path, encode_session(session))
