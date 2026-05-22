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

from .file_io import join_path, read_file, stat_file
from .json import JsonValue, parse_json


comptime _TURBOKOD_DIR    = String(".turbokod")
comptime _GRAMMARS_FILE   = String("grammars.json")


@fieldwise_init
struct GrammarOverride(Copyable, Movable):
    """One ext → language_id mapping. ``ext`` is the bare extension
    without leading dot (``"html"``, not ``".html"``)."""
    var ext: String
    var language_id: String


def _grammars_path(project_root: String) -> String:
    if len(project_root.as_bytes()) == 0:
        return String("")
    return join_path(
        join_path(project_root, _TURBOKOD_DIR), _GRAMMARS_FILE,
    )


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
