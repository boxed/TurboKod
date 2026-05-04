"""Language-server registry, modeled on Helix's ``languages.toml``.

The static catalog lives in ``src/turbokod/data/languages.json``, regenerated
from upstream Helix by ``scripts/refresh_languages.py`` (run via
``make update-lsp-list``). We load + parse that JSON at startup rather than
hardcoding the data in Mojo: the upstream list runs to ~150 languages and
churns frequently, so keeping it as a build resource is the difference
between a one-line refresh and a tedious manual port every release.

Why JSON and not TOML directly: Mojo has no TOML parser, but it has the
hand-rolled ``json.mojo`` we use for LSP traffic. The refresh script does
the TOML→JSON flattening once (server table lookup, candidate list
resolution, file-type filtering) so the runtime doesn't have to.

Why this shape:
* Multiple ``argvs`` per language captures Python's reality (pyright,
  basedpyright, pylsp all answer the same wire protocol but ship under
  different binary names) without forcing the user to choose.
* The file-types lookup is independent of which server we end up
  spawning — extension routing stays stable even when the binary on
  PATH changes.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .file_io import read_file
from .json import (
    JsonValue, json_get_string, json_get_string_array, parse_json,
)


comptime LANGUAGES_JSON_PATH = String("src/turbokod/data/languages.json")


struct ServerCandidate(ImplicitlyCopyable, Movable):
    """One concrete binary + argv we can try to spawn for a language."""
    var argv: List[String]

    fn __init__(out self, var argv: List[String]):
        self.argv = argv^

    fn __copyinit__(out self, copy: Self):
        self.argv = copy.argv.copy()


struct LanguageSpec(ImplicitlyCopyable, Movable):
    """Routing entry: which file extensions belong to this language id,
    and the ordered list of server binaries to try (first hit wins).

    ``language_id`` is what ends up in ``didOpen``'s ``languageId`` field;
    ``file_types`` are matched against the lower-cased extension after
    the last ``.`` in the basename. ``install_hint`` is a one-line shell
    command we suggest to the user when none of the candidates are on
    ``$PATH`` — empty string means "no canonical install command, don't
    bother prompting" (e.g. ``mojo-lsp-server`` ships with the toolchain).
    """
    var language_id: String
    var file_types: List[String]
    var candidates: List[ServerCandidate]
    var install_hint: String

    fn __init__(
        out self, var language_id: String,
        var file_types: List[String],
        var candidates: List[ServerCandidate],
        var install_hint: String = String(""),
    ):
        self.language_id = language_id^
        self.file_types = file_types^
        self.candidates = candidates^
        self.install_hint = install_hint^

    fn __copyinit__(out self, copy: Self):
        self.language_id = copy.language_id
        self.file_types = copy.file_types.copy()
        self.candidates = copy.candidates.copy()
        self.install_hint = copy.install_hint


fn _candidate_from_json(v: JsonValue) -> ServerCandidate:
    if not v.is_object():
        return ServerCandidate(List[String]())
    return ServerCandidate(json_get_string_array(v, String("argv")))


fn _spec_from_json(v: JsonValue) -> Optional[LanguageSpec]:
    """Translate one JSON catalog entry into a LanguageSpec. Returns
    None when required fields are missing — corrupt entries are skipped
    rather than aborting the whole load."""
    if not v.is_object():
        return Optional[LanguageSpec]()

    var language_id = json_get_string(v, String("language_id"))
    if len(language_id.as_bytes()) == 0:
        return Optional[LanguageSpec]()

    var file_types = json_get_string_array(v, String("file_types"))

    var candidates = List[ServerCandidate]()
    var cands_v = v.object_get(String("candidates"))
    if cands_v and cands_v.value().is_array():
        var arr = cands_v.value()
        for i in range(arr.array_len()):
            candidates.append(_candidate_from_json(arr.array_at(i)))

    var install_hint = json_get_string(v, String("install_hint"))

    return Optional[LanguageSpec](LanguageSpec(
        language_id^, file_types^, candidates^, install_hint^,
    ))


fn built_in_servers() -> List[LanguageSpec]:
    """Load the curated language-server catalog from the bundled JSON.

    Returns an empty list if the file is missing or malformed — every
    consumer treats an empty catalog as "no built-in routing," which is
    the correct degraded behavior. Run ``make update-lsp-list`` to
    regenerate the catalog from upstream Helix.
    """
    var out = List[LanguageSpec]()
    try:
        var text = read_file(LANGUAGES_JSON_PATH)
        if len(text.as_bytes()) == 0:
            return out^
        var root = parse_json(text)
        if not root.is_array():
            return out^
        for i in range(root.array_len()):
            var spec = _spec_from_json(root.array_at(i))
            if spec:
                out.append(spec.value())
    except:
        pass
    return out^


fn find_language_for_extension(
    specs: List[LanguageSpec], ext: String,
) -> Int:
    """Index of the spec whose ``file_types`` contains ``ext``, or -1.

    Linear scan — the spec list is small (a couple hundred entries even
    fully populated) and this only fires once per file open, so a hash
    table would be over-engineering.
    """
    if len(ext.as_bytes()) == 0:
        return -1
    for i in range(len(specs)):
        for k in range(len(specs[i].file_types)):
            if specs[i].file_types[k] == ext:
                return i
    return -1


fn find_language_by_id(specs: List[LanguageSpec], language_id: String) -> Int:
    for i in range(len(specs)):
        if specs[i].language_id == language_id:
            return i
    return -1
