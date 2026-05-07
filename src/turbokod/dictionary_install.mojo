"""Catalog of downloadable spell-check dictionaries.

The bundled wordlists under ``src/turbokod/data/wordlists/`` cover
programmer vocabulary. The OS list at ``/usr/share/dict/words`` covers
English. For everything else we hand the user a fixed catalog of
"download this language's wordlist into your config dir" entries.

Mirrors the shape of ``grammar_install.mojo``:

* ``built_in_downloadable_dictionaries`` is the static catalog.
* ``user_dictionaries_root`` is ``~/.config/turbokod/dictionaries``.
* ``user_dictionary_path`` is where one downloaded list lives:
  ``<root>/<language_id>.txt``.
* ``dictionary_install_command`` is the ``sh -c`` line we hand to
  ``InstallRunner`` (``mkdir -p`` + ``curl -fsSL -o <path>``).
* ``remove_user_dictionary`` deletes the file.
* ``installed_dictionary_languages`` enumerates language ids whose
  ``.txt`` file is present on disk — used by Settings to render the
  "[X] installed" tick next to each catalog row.

The Speller picks up everything in ``user_dictionaries_root`` on the
first ``load_default`` call; ``Speller.reload`` re-reads the dir so a
fresh install / remove takes effect without restart.
"""

from std.collections.list import List
from std.ffi import external_call

from .file_io import join_path, list_directory, stat_file
from .posix import getenv_value


struct DownloadableDictionary(ImplicitlyCopyable, Movable):
    """One downloadable dictionary entry. ``url`` points at a raw
    plain-text wordlist (one word per line, ``#``-prefixed comments
    skipped). ``language_id`` doubles as the filename stem under
    ``user_dictionaries_root``. ``display`` is the human-readable
    label rendered in Settings.
    """
    var language_id: String
    var display: String
    var url: String

    fn __init__(
        out self, var language_id: String, var display: String,
        var url: String,
    ):
        self.language_id = language_id^
        self.display = display^
        self.url = url^

    fn __copyinit__(out self, copy: Self):
        self.language_id = copy.language_id
        self.display = copy.display
        self.url = copy.url


fn built_in_downloadable_dictionaries() -> List[DownloadableDictionary]:
    """The fixed catalog. Each entry points at a permissively-licensed
    plain-text wordlist (one word per line). Add an entry here per
    language we want to offer; nothing else needs to change.

    Sources currently used:
    * ``de`` / ``es`` / ``fr`` — ``lorenbrichter/Words`` (CC0).
    * ``sv``                  — ``martinlindhe/wordlist_swedish`` (MIT).
    """
    var out = List[DownloadableDictionary]()
    out.append(DownloadableDictionary(
        String("de"), String("German"),
        String(
            "https://raw.githubusercontent.com/"
            "lorenbrichter/Words/master/Words/de.txt"
        ),
    ))
    out.append(DownloadableDictionary(
        String("es"), String("Spanish"),
        String(
            "https://raw.githubusercontent.com/"
            "lorenbrichter/Words/master/Words/es.txt"
        ),
    ))
    out.append(DownloadableDictionary(
        String("fr"), String("French"),
        String(
            "https://raw.githubusercontent.com/"
            "lorenbrichter/Words/master/Words/fr.txt"
        ),
    ))
    out.append(DownloadableDictionary(
        String("sv"), String("Swedish"),
        String(
            "https://raw.githubusercontent.com/"
            "martinlindhe/wordlist_swedish/master/swe_wordlist"
        ),
    ))
    return out^


fn find_downloadable_dictionary_by_language(
    specs: List[DownloadableDictionary], language_id: String,
) -> Int:
    for i in range(len(specs)):
        if specs[i].language_id == language_id:
            return i
    return -1


fn user_dictionaries_root() -> String:
    """``~/.config/turbokod/dictionaries``. Empty when ``$HOME`` is unset
    (sandboxed processes); callers treat that as "no user dictionaries
    available" and skip both load and install."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    return home + String("/.config/turbokod/dictionaries")


fn user_dictionary_path(language_id: String) -> String:
    var root = user_dictionaries_root()
    if len(root.as_bytes()) == 0:
        return String("")
    return root + String("/") + language_id + String(".txt")


fn user_dictionary_installed(language_id: String) -> Bool:
    var path = user_dictionary_path(language_id)
    if len(path.as_bytes()) == 0:
        return False
    return stat_file(path).ok


fn installed_dictionary_languages() -> List[String]:
    """Language ids with a ``<lang>.txt`` file under
    ``user_dictionaries_root``. Used by Settings to know which catalog
    rows render with the "installed" tick. Order is filesystem order;
    callers that care about display order should sort by display name
    against the catalog."""
    var out = List[String]()
    var root = user_dictionaries_root()
    if len(root.as_bytes()) == 0:
        return out^
    var entries = list_directory(root)
    for i in range(len(entries)):
        var name = entries[i]
        if name == String(".") or name == String(".."):
            continue
        var b = name.as_bytes()
        var n = len(b)
        if n < 5:
            continue
        if (b[n - 4] != 0x2E or b[n - 3] != 0x74
                or b[n - 2] != 0x78 or b[n - 1] != 0x74):
            continue
        var stem = String(StringSlice(unsafe_from_utf8=b[0:n - 4]))
        out.append(stem^)
    return out^


fn dictionary_install_command(language_id: String, url: String) -> String:
    """Shell command that mkdirs the dictionaries dir and curls the
    wordlist into it. Single ``sh -c`` line so ``InstallRunner`` runs
    it unchanged. ``set -e`` aborts on the first failure so a half-
    fetched list is never left on disk; ``curl -f`` makes 4xx/5xx
    responses non-zero so we don't save a 404 HTML page as the
    wordlist."""
    var root = user_dictionaries_root()
    var dest = user_dictionary_path(language_id)
    return String("set -e; mkdir -p '") + root + String("'; ") \
        + String("curl -fsSL -o '") + dest + String("' '") \
        + url + String("'")


fn remove_user_dictionary(language_id: String) -> Bool:
    """Delete the on-disk wordlist for ``language_id``. Returns True on
    success or when the file was already gone. The caller is expected
    to ``Speller.reload`` afterwards so the in-memory bucket set drops
    those words too."""
    var path = user_dictionary_path(language_id)
    if len(path.as_bytes()) == 0:
        return False
    if not stat_file(path).ok:
        return True
    var c_path = path + String("\0")
    var rc = external_call["unlink", Int32](c_path.unsafe_ptr())
    return Int(rc) == 0
