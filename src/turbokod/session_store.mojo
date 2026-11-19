"""Per-user window session, persisted in
``<project>/.turbokod/per_user/<username>/session.json``.

Captures the list of file-backed editor windows currently open, their
geometry (rect + maximized state + restore rect), per-buffer view state
(cursor row/col, scroll), the z-order, and which window is focused.
Restored when the project is opened with no current windows so the user
lands back where they left off. The ``per_user/<username>`` segment
mirrors ``view_state_store`` / ``breakpoint_store`` so an accidental
``git add .turbokod`` doesn't clobber a teammate's open-window set.

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

from .file_io import load_json_object
from .geometry import Rect
from .json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_object,
    json_str, json_get_bool, json_get_int, json_get_string, encode_int_pair,
    encode_int_quad, read_int_pair, read_int_quad,
)
from .per_user_store import per_user_path, write_per_user_file


comptime SESSION_FILE = String("session.json")


struct StoredWindow(ImplicitlyCopyable, Movable):
    """An editor window's restorable geometry and view, as both the session
    and the drafts store keep it: its ``rect``, whether it's maximized, the
    ``restore`` rect it un-maximizes to (equal to ``rect`` for a window
    that isn't), the caret and scroll, and when it was last focused."""
    var rect: Rect
    var restore: Rect
    var maximized: Bool
    var cursor_row: Int
    var cursor_col: Int
    var scroll_x: Int
    var scroll_y: Int
    var last_focus_ms: Int
    """Wall-clock ms of the last time this window was focused (``0`` if
    never). Persisted so a restore can prefer the most-recently-used
    documents when the open count would exceed ``max_open_windows``."""

    def __init__(out self):
        self.rect = Rect(0, 0, 0, 0)
        self.restore = Rect(0, 0, 0, 0)
        self.maximized = False
        self.cursor_row = 0
        self.cursor_col = 0
        self.scroll_x = 0
        self.scroll_y = 0
        self.last_focus_ms = 0

    @staticmethod
    def from_json(node: JsonValue) -> Self:
        """Read the fields ``put_json`` writes; a missing one keeps its
        default, and a missing ``restore_rect`` is the ``rect``."""
        var w = Self()
        var r = read_int_quad(node, String("rect"), 0, 0, 0, 0)
        w.rect = Rect(r[0], r[1], r[2], r[3])
        w.maximized = json_get_bool(node, String("maximized"), False)
        var q = read_int_quad(
            node, String("restore_rect"), r[0], r[1], r[2], r[3],
        )
        w.restore = Rect(q[0], q[1], q[2], q[3])
        var cursor = read_int_pair(node, String("cursor"), 0, 0)
        w.cursor_row = cursor[0]
        w.cursor_col = cursor[1]
        var scroll = read_int_pair(node, String("scroll"), 0, 0)
        w.scroll_x = scroll[0]
        w.scroll_y = scroll[1]
        w.last_focus_ms = json_get_int(node, String("last_focus_ms"), 0)
        return w

    def put_json(self, mut obj: JsonValue):
        obj.put(String("rect"), _encode_rect(self.rect))
        obj.put(String("maximized"), json_bool(self.maximized))
        obj.put(String("restore_rect"), _encode_rect(self.restore))
        obj.put(
            String("cursor"), encode_int_pair(self.cursor_row, self.cursor_col),
        )
        obj.put(String("scroll"), encode_int_pair(self.scroll_x, self.scroll_y))
        obj.put(String("last_focus_ms"), json_int(self.last_focus_ms))


def _encode_rect(r: Rect) -> JsonValue:
    return encode_int_quad(r.a.x, r.a.y, r.b.x, r.b.y)


struct SessionWindow(ImplicitlyCopyable, Movable):
    """One file-backed editor window's restorable state.

    ``path`` is project-relative when the file lives inside the project
    root, absolute otherwise — picked at save time by
    ``project_relative``.
    """
    var path: String
    var win: StoredWindow

    def __init__(out self):
        self.path = String("")
        self.win = StoredWindow()

struct Session(Copyable, Movable):
    """Snapshot of the windows in a project, plus z-order and focus.

    ``z_order`` and ``focused`` index into ``windows``. Both default to
    "natural order" / "last window" when the persisted file omits them
    or carries stale indices.
    """
    var windows: List[SessionWindow]
    var z_order: List[Int]
    var focused: Int

    def __init__(out self):
        self.windows = List[SessionWindow]()
        self.z_order = List[Int]()
        self.focused = -1


def _session_path(project_root: String) -> String:
    return per_user_path(project_root, SESSION_FILE)


def _int_array(value: JsonValue) -> List[Int]:
    var out = List[Int]()
    if not value.is_array():
        return out^
    for i in range(value.array_len()):
        var item = value.array_at(i)
        if item.is_int():
            out.append(item.as_int())
    return out^


def _parse_session_window(node: JsonValue) -> SessionWindow:
    var w = SessionWindow()
    if not node.is_object():
        return w^
    w.path = json_get_string(node, String("path"))
    w.win = StoredWindow.from_json(node)
    return w^


def load_session(project_root: String) -> Session:
    """Parse ``<project>/.turbokod/per_user/<username>/session.json``.
    Any failure (missing file, malformed JSON, missing keys) yields an
    empty session — the caller distinguishes by checking
    ``len(session.windows)``."""
    var out = Session()
    var path = _session_path(project_root)
    if len(path.as_bytes()) == 0:
        return out^
    var loaded = load_json_object(path)
    if not loaded:
        return out^
    ref root = loaded.value()
    var arr_v = root.object_get(String("windows"))
    if not arr_v or not arr_v.value().is_array():
        return out^
    var arr = arr_v.value().copy()
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
    out.focused = json_get_int(root, String("focused"), -1)
    if out.focused < 0 or out.focused >= len(out.windows):
        out.focused = len(out.windows) - 1
    return out^


def _encode_session_window(w: SessionWindow) -> JsonValue:
    var obj = json_object()
    obj.put(String("path"), json_str(w.path))
    w.win.put_json(obj)
    return obj^


def encode_session(session: Session) -> String:
    """Serialize ``session`` to the on-disk JSON form. Pure function —
    used both for the actual write and for change detection (the
    Desktop caches the previous encoding and only writes when the new
    one differs)."""
    var root = json_object()
    root.put(String("focused"), json_int(session.focused))
    var z = json_array()
    for i in range(len(session.z_order)):
        z.append(json_int(session.z_order[i]))
    root.put(String("z_order"), z)
    var arr = json_array()
    for i in range(len(session.windows)):
        arr.append(_encode_session_window(session.windows[i]))
    root.put(String("windows"), arr)
    return encode_json(root) + String("\n")


def save_session(project_root: String, session: Session) -> Bool:
    """Rewrite ``<project>/.turbokod/per_user/<username>/session.json``
    from ``session``. Creates the directory chain if missing. Returns
    the underlying ``write_file`` success bool — the Desktop ignores
    failures (the user can keep editing; we'll just retry next paint)."""
    return write_per_user_file(project_root, SESSION_FILE, encode_session(session))
