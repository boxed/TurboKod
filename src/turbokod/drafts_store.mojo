"""Per-user persistence for *untitled* (file-less) editor buffers, stored in
``<project>/.turbokod/per_user/<username>/drafts.json``.

Sibling of ``session_store`` / ``view_state_store``. The session store keys
windows by ``path`` and deliberately skips Untitled buffers — they have no
disk file to restore from. This store fills that gap: it captures the *full
content* of every untitled buffer (plus its geometry and cursor) so a brand-new
"Untitled" scratch document survives a quit/restart instead of being lost.

The buffer is written to disk here but the editor still reports itself as
**unsaved** (``dirty == True``) — the draft file is an autosave shadow, not a
"real" save. Doing a proper Save As migrates the buffer to a normal file: it
then carries a ``file_path`` and drops out of this store on the next write
(picked up by ``session_store`` instead). Closing an untitled window discards
its draft the same way — the next snapshot no longer includes it.

Format on disk::

    {
      "drafts": [
        { "seq": 1,
          "content": "hello\nworld",
          "rect": [10, 5, 70, 25],
          "maximized": false,
          "restore_rect": [10, 5, 70, 25],
          "cursor": [1, 4],
          "scroll": [0, 0],
          "last_focus_ms": 1234567890 }
      ]
    }

``seq`` is the value of the Desktop's ``_untitled_count`` at the moment the
window was created — it both reconstructs the window title ("Untitled" for
``seq == 1``, "Untitled N" otherwise) and lets the restore bump
``_untitled_count`` past the highest restored draft so a freshly-created
untitled buffer never collides with a restored one. A malformed or missing
file silently yields an empty list — the editor still works, it just doesn't
restore any drafts.
"""

from std.collections.list import List

from .file_io import read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_object,
    json_str, parse_json,
    json_get_bool, json_get_int, json_get_string,
    encode_int_pair, encode_int_quad, read_int_pair, read_int_quad,
)
from .per_user_store import ensure_per_user_dir, per_user_path


comptime DRAFTS_FILE = String("drafts.json")


struct StoredDraft(ImplicitlyCopyable, Movable):
    """One untitled buffer's restorable state. ``content`` is the raw
    buffer text (lines joined with ``\\n``, no trailing newline — the
    same shape ``Editor.text_snapshot`` produces and ``Editor(text)``
    consumes). ``restore_rect`` is the un-maximized rect; it equals
    ``rect`` for a non-maximized window."""
    var seq: Int
    var content: String
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
    var last_focus_ms: Int

    def __init__(out self):
        self.seq = 0
        self.content = String("")
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
        self.last_focus_ms = 0

    def __copyinit__(mut self, copy: Self):
        self.seq = copy.seq
        self.content = copy.content
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
        self.last_focus_ms = copy.last_focus_ms


def _drafts_path(project_root: String) -> String:
    return per_user_path(project_root, DRAFTS_FILE)


def _parse_draft(node: JsonValue) -> StoredDraft:
    var d = StoredDraft()
    if not node.is_object():
        return d^
    d.seq = json_get_int(node, String("seq"), 0)
    d.content = json_get_string(node, String("content"))
    var rect = read_int_quad(node, String("rect"), 0, 0, 0, 0)
    d.rect_a_x = rect[0]
    d.rect_a_y = rect[1]
    d.rect_b_x = rect[2]
    d.rect_b_y = rect[3]
    d.is_maximized = json_get_bool(node, String("maximized"), False)
    var restore = read_int_quad(
        node, String("restore_rect"),
        d.rect_a_x, d.rect_a_y, d.rect_b_x, d.rect_b_y,
    )
    d.restore_a_x = restore[0]
    d.restore_a_y = restore[1]
    d.restore_b_x = restore[2]
    d.restore_b_y = restore[3]
    var cursor = read_int_pair(node, String("cursor"), 0, 0)
    d.cursor_row = cursor[0]
    d.cursor_col = cursor[1]
    var scroll = read_int_pair(node, String("scroll"), 0, 0)
    d.scroll_x = scroll[0]
    d.scroll_y = scroll[1]
    d.last_focus_ms = json_get_int(node, String("last_focus_ms"), 0)
    return d^


def load_drafts(project_root: String) -> List[StoredDraft]:
    """Parse the per-user drafts file. Any failure (missing file,
    malformed JSON, missing keys) yields an empty list."""
    var out = List[StoredDraft]()
    var path = _drafts_path(project_root)
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
    var arr_v = root.object_get(String("drafts"))
    if not arr_v or not arr_v.value().is_array():
        return out^
    var arr = arr_v.value().copy()
    for i in range(arr.array_len()):
        out.append(_parse_draft(arr.array_at(i)))
    return out^


def _encode_draft(d: StoredDraft) -> JsonValue:
    var obj = json_object()
    obj.put(String("seq"), json_int(d.seq))
    obj.put(String("content"), json_str(d.content))
    obj.put(
        String("rect"),
        encode_int_quad(d.rect_a_x, d.rect_a_y, d.rect_b_x, d.rect_b_y),
    )
    obj.put(String("maximized"), json_bool(d.is_maximized))
    obj.put(
        String("restore_rect"),
        encode_int_quad(
            d.restore_a_x, d.restore_a_y, d.restore_b_x, d.restore_b_y,
        ),
    )
    obj.put(String("cursor"), encode_int_pair(d.cursor_row, d.cursor_col))
    obj.put(String("scroll"), encode_int_pair(d.scroll_x, d.scroll_y))
    obj.put(String("last_focus_ms"), json_int(d.last_focus_ms))
    return obj^


def encode_drafts(drafts: List[StoredDraft]) -> String:
    """Serialize ``drafts`` to the on-disk JSON form. Pure function —
    used both for the actual write and for change detection (the
    Desktop caches the previous encoding and only writes when the new
    one differs)."""
    var root = json_object()
    var arr = json_array()
    for i in range(len(drafts)):
        arr.append(_encode_draft(drafts[i]))
    root.put(String("drafts"), arr^)
    return encode_json(root) + String("\n")


def save_drafts(project_root: String, drafts: List[StoredDraft]) -> Bool:
    """Rewrite the per-user drafts file. Creates the directory chain
    (``.turbokod/per_user/<username>``) if missing. Returns the
    underlying ``write_file`` success bool — the Desktop ignores
    failures (we'll retry next paint)."""
    var path = _drafts_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    ensure_per_user_dir(project_root)
    return write_file(path, encode_drafts(drafts))
