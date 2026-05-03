"""Catalog of TextMate grammars we can offer to download on demand.

The bundled grammars under ``src/turbokod/grammars/`` cover the core
languages we ship support for. For everything else, this module holds
a small registry of "we know where to fetch the grammar JSON for this
extension" entries — opening a file with such an extension triggers a
one-shot "Install <lang> grammar?" prompt in ``Desktop``. On accept,
the same single-slot ``InstallRunner`` that handles LSP/docs installs
runs ``curl`` to drop the JSON at
``~/.config/turbokod/languages/<lang>/<lang>.tmLanguage.json``.

The highlighter checks that path on every refresh (``_grammar_path_for_ext``
in ``highlight.mojo``), so a fresh install lights up syntax color the
next paint without restart.
"""

from std.collections.list import List

from .file_io import stat_file
from .posix import getenv_value


struct DownloadableGrammar(ImplicitlyCopyable, Movable):
    """One downloadable grammar entry. ``url`` points at a raw JSON
    ``.tmLanguage.json`` file (typically a vscode plugin's
    ``syntaxes/...json``); ``language_id`` doubles as the directory
    name under ``~/.config/turbokod/languages/`` and the filename stem.
    ``display`` is the human-readable label for prompts.
    """
    var language_id: String
    var file_types: List[String]
    var url: String
    var display: String

    fn __init__(
        out self, var language_id: String,
        var file_types: List[String],
        var url: String,
        var display: String,
    ):
        self.language_id = language_id^
        self.file_types = file_types^
        self.url = url^
        self.display = display^

    fn __copyinit__(out self, copy: Self):
        self.language_id = copy.language_id
        self.file_types = copy.file_types.copy()
        self.url = copy.url
        self.display = copy.display


fn _exts(*items: String) -> List[String]:
    var out = List[String]()
    for x in items:
        out.append(String(x))
    return out^


fn built_in_downloadable_grammars() -> List[DownloadableGrammar]:
    """The fixed catalog. Add an entry per language we want to offer.

    Pick URLs from open-source vscode plugin repos (raw JSON), since
    those are the maintained sources the wider TextMate-grammar
    ecosystem already converges on. Grammars that pull in external
    scopes (``include: source.css`` etc.) won't fully resolve unless
    those scopes are bundled — pick self-contained grammars when
    possible.
    """
    var out = List[DownloadableGrammar]()
    out.append(DownloadableGrammar(
        String("elm"),
        _exts(String("elm")),
        String(
            "https://raw.githubusercontent.com/"
            "elm-tooling/elm-language-client-vscode/"
            "master/syntaxes/elm-syntax.json"
        ),
        String("Elm"),
    ))
    return out^


fn find_downloadable_grammar_for_extension(
    specs: List[DownloadableGrammar], ext: String,
) -> Int:
    """Index of the spec whose ``file_types`` contains ``ext``, or -1."""
    if len(ext.as_bytes()) == 0:
        return -1
    for i in range(len(specs)):
        for k in range(len(specs[i].file_types)):
            if specs[i].file_types[k] == ext:
                return i
    return -1


fn find_downloadable_grammar_by_language(
    specs: List[DownloadableGrammar], language_id: String,
) -> Int:
    for i in range(len(specs)):
        if specs[i].language_id == language_id:
            return i
    return -1


fn user_grammar_root() -> String:
    """``~/.config/turbokod/languages``. Empty when ``$HOME`` is unset
    (sandboxed processes); callers treat that as "no user grammars
    available" and skip both load and install."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    return home + String("/.config/turbokod/languages")


fn user_grammar_dir(lang: String) -> String:
    """Per-language directory: ``~/.config/turbokod/languages/<lang>``."""
    var root = user_grammar_root()
    if len(root.as_bytes()) == 0:
        return String("")
    return root + String("/") + lang


fn user_grammar_path(lang: String) -> String:
    """Where the downloaded ``<lang>.tmLanguage.json`` lives on disk."""
    var dir = user_grammar_dir(lang)
    if len(dir.as_bytes()) == 0:
        return String("")
    return dir + String("/") + lang + String(".tmLanguage.json")


fn user_grammar_installed(lang: String) -> Bool:
    var path = user_grammar_path(lang)
    if len(path.as_bytes()) == 0:
        return False
    return stat_file(path).ok


fn user_grammar_path_for_ext(ext: String) -> String:
    """Return the user-installed grammar path for ``ext`` if present
    on disk, else empty. Highlighter calls this after the bundled-
    extension lookup misses, so a downloaded Elm grammar transparently
    plugs into the same load path bundled grammars take."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_for_extension(specs, ext)
    if idx < 0:
        return String("")
    var path = user_grammar_path(specs[idx].language_id)
    if len(path.as_bytes()) == 0:
        return String("")
    if not stat_file(path).ok:
        return String("")
    return path


fn grammar_install_command(lang: String, url: String) -> String:
    """Shell command that mkdirs the per-language dir and curls the
    grammar JSON into it. Single ``sh -c`` line so ``InstallRunner``
    runs it unchanged. ``set -e`` aborts on the first failure so a
    half-fetched grammar is never left on disk masquerading as
    installed; ``curl -f`` makes 4xx/5xx responses non-zero so we
    don't save a 404 HTML page as the grammar JSON."""
    var dir = user_grammar_dir(lang)
    var dest = user_grammar_path(lang)
    return String("set -e; mkdir -p '") + dir + String("'; ") \
        + String("curl -fsSL -o '") + dest + String("' '") \
        + url + String("'")
