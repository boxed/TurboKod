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

At quit (and Close Project) a file-backed buffer that is still unsaved —
its save failed, or auto-save is off and quitting can't ask — is kept
here too, with its ``path`` and the on-disk text it was edited against
(``base``). The next restore puts the edits back into the file's window
and merges in whatever changed on disk since.

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

from .file_io import load_json_array
from .json import (
    JsonValue, encode_json, json_array, json_int, json_object, json_str,
    json_get_int, json_get_string,
)
from .per_user_store import per_user_path, write_per_user_file
from .session_store import StoredWindow


comptime DRAFTS_FILE = String("drafts.json")


struct StoredDraft(ImplicitlyCopyable, Movable):
    """One untitled buffer's restorable state. ``content`` is the raw
    buffer text (lines joined with ``\\n``, no trailing newline — the
    same shape ``Editor.text_snapshot`` produces and ``Editor(text)``
    consumes)."""
    var seq: Int
    var content: String
    var win: StoredWindow
    var path: String
    """Empty for an untitled buffer. Otherwise the file whose unsaved
    edits these are, kept at quit because they couldn't be saved (or
    auto-save is off, and quitting can't ask)."""
    var base: String
    """For a file's draft: the file as it was on disk when it was edited,
    so a change made on disk since can be merged with the draft."""

    def __init__(out self):
        self.seq = 0
        self.content = String("")
        self.win = StoredWindow()
        self.path = String("")
        self.base = String("")


def _drafts_path(project_root: String) -> String:
    return per_user_path(project_root, DRAFTS_FILE)


def _parse_draft(node: JsonValue) -> StoredDraft:
    var d = StoredDraft()
    if not node.is_object():
        return d^
    d.seq = json_get_int(node, String("seq"), 0)
    d.content = json_get_string(node, String("content"))
    d.win = StoredWindow.from_json(node)
    d.path = json_get_string(node, String("path"))
    d.base = json_get_string(node, String("base"))
    return d^


def load_drafts(project_root: String) -> List[StoredDraft]:
    """Parse the per-user drafts file. Any failure (missing file,
    malformed JSON, missing keys) yields an empty list."""
    var out = List[StoredDraft]()
    var path = _drafts_path(project_root)
    if len(path.as_bytes()) == 0:
        return out^
    var arr = load_json_array(path, String("drafts"))
    for i in range(arr.array_len()):
        out.append(_parse_draft(arr.array_at(i)))
    return out^


def _encode_draft(d: StoredDraft) -> JsonValue:
    var obj = json_object()
    obj.put(String("seq"), json_int(d.seq))
    obj.put(String("content"), json_str(d.content))
    d.win.put_json(obj)
    if len(d.path.as_bytes()) > 0:
        obj.put(String("path"), json_str(d.path))
        obj.put(String("base"), json_str(d.base))
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
    root.put(String("drafts"), arr)
    return encode_json(root) + String("\n")


def save_drafts(project_root: String, drafts: List[StoredDraft]) -> Bool:
    """Rewrite the per-user drafts file. Creates the directory chain
    (``.turbokod/per_user/<username>``) if missing. Returns the
    underlying ``write_file`` success bool — the Desktop ignores
    failures (we'll retry next paint)."""
    return write_per_user_file(project_root, DRAFTS_FILE, encode_drafts(drafts))
