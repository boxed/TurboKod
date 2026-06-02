"""Per-project syntax-grammar overrides, persisted in
``<project>/.turbokod/grammars.json``.

The bundled extension → grammar map in ``highlight._grammar_path_for_ext``
is one-size-fits-all (``.html`` always means vanilla HTML, etc.). Some
projects want a different grammar for an extension — the canonical case
is a Django project whose ``.html`` files are templates that mix
``{% %}`` / ``{{ }}`` with HTML, where the vanilla HTML grammar misses
every Django scope.

Format on disk::

    {
      "extensions": {
        "html": "django-html",
        "txt":  "django-txt"
      }
    }

The values are ``language_id`` strings — the same identifier used by
``DownloadableGrammar.language_id`` and by the bundled grammar map.
Resolution is bundled-first, then user-installed; the user installs the
grammar through the normal "Install <lang> grammar?" prompt and then
adds the extension mapping to opt their project in.

Missing file, malformed JSON, or unknown language IDs all degrade to
"no override" rather than failing — the editor still highlights
something, just with the default grammar.
"""

from std.collections.list import List
from std.ffi import external_call

from .file_io import join_path, read_file, stat_file, write_file
from .json import (
    JsonValue, encode_json, json_object, json_str, parse_json,
)


comptime _TURBOKOD_DIR    = String(".turbokod")
comptime _GRAMMARS_FILE   = String("grammars.json")


@fieldwise_init
struct GrammarOverride(Copyable, Movable):
    """One ext → language_id mapping. ``ext`` is the bare extension
    without leading dot (``"html"``, not ``".html"``)."""
    var ext: String
    var language_id: String


def _grammars_dir(project_root: String) -> String:
    if len(project_root.as_bytes()) == 0:
        return String("")
    return join_path(project_root, _TURBOKOD_DIR)


def _grammars_path(project_root: String) -> String:
    var dir = _grammars_dir(project_root)
    if len(dir.as_bytes()) == 0:
        return String("")
    return join_path(dir, _GRAMMARS_FILE)


def _ensure_dir(path: String):
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


def load_project_grammar_overrides(
    project_root: String,
) -> List[GrammarOverride]:
    """Load ``<project>/.turbokod/grammars.json``. Returns an empty list
    on any failure (no project, missing file, malformed JSON, missing
    keys, non-string values). The editor stays usable in all of those
    cases — overrides are strictly additive."""
    var out = List[GrammarOverride]()
    var path = _grammars_path(project_root)
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
    var exts_v = root.object_get(String("extensions"))
    if not exts_v or not exts_v.value().is_object():
        return out^
    var exts = exts_v.value().copy()
    for i in range(len(exts.obj_v)):
        var member = exts.obj_v[i].copy()
        if not member.value.is_string():
            continue
        var ext = member.key
        var lang = member.value.as_str()
        if len(ext.as_bytes()) == 0 or len(lang.as_bytes()) == 0:
            continue
        out.append(GrammarOverride(ext, lang))
    return out^


def write_grammar_overrides(
    project_root: String, overrides: List[GrammarOverride],
) -> Bool:
    """Rewrite ``<project>/.turbokod/grammars.json`` from ``overrides``.

    Inverse of ``load_project_grammar_overrides`` — emits the same
    ``{"extensions": {ext: language_id}}`` shape the loader reads.
    Rows with an empty extension or language are dropped (the dialog
    can hold half-filled rows mid-edit; they shouldn't reach disk).
    The first mapping for a given extension wins, matching
    ``GrammarRegistry.lookup_override``'s first-match semantics, so a
    duplicate ext added in the UI doesn't silently shadow the original.
    Returns False when there's no project root or the write fails."""
    var path = _grammars_path(project_root)
    if len(path.as_bytes()) == 0:
        return False
    _ensure_dir(_grammars_dir(project_root))
    var exts = json_object()
    var seen = List[String]()
    for i in range(len(overrides)):
        var ext = overrides[i].ext
        var lang = overrides[i].language_id
        if len(ext.as_bytes()) == 0 or len(lang.as_bytes()) == 0:
            continue
        var dup = False
        for j in range(len(seen)):
            if seen[j] == ext:
                dup = True
                break
        if dup:
            continue
        seen.append(ext)
        exts.put(ext, json_str(lang))
    var root = json_object()
    root.put(String("extensions"), exts^)
    return write_file(path, encode_json(root) + String("\n"))
