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

from .catalog import LanguageKeyed
from .file_io import delete_path, list_directory, stat_file
from .posix import user_config_path
from .string_utils import shell_fetch, shell_move_into_place, shell_single_quote


struct DownloadableDictionary(ImplicitlyCopyable, Movable, LanguageKeyed):
    """One downloadable dictionary entry. ``url`` points at a raw
    plain-text wordlist (one word per line, ``#``-prefixed comments
    skipped). ``language_id`` doubles as the filename stem under
    ``user_dictionaries_root``. ``display`` is the human-readable
    label rendered in Settings.
    """
    var language_id: String
    var display: String
    var url: String


    def catalog_language(self) -> String:
        return self.language_id

    def __init__(
        out self, var language_id: String, var display: String,
        var url: String,
    ):
        self.language_id = language_id^
        self.display = display^
        self.url = url^


def built_in_downloadable_dictionaries() -> List[DownloadableDictionary]:
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




def user_dictionaries_root() -> String:
    """``~/.config/turbokod/dictionaries``. Empty when ``$HOME`` is unset
    (sandboxed processes); callers treat that as "no user dictionaries
    available" and skip both load and install."""
    return user_config_path(String("dictionaries"))


def user_dictionary_path(language_id: String) -> String:
    var root = user_dictionaries_root()
    if len(root.as_bytes()) == 0:
        return String("")
    return root + String("/") + language_id + String(".txt")


def user_dictionary_installed(language_id: String) -> Bool:
    var path = user_dictionary_path(language_id)
    if len(path.as_bytes()) == 0:
        return False
    return stat_file(path).ok




def dictionary_install_command(language_id: String, url: String) -> String:
    """Shell command that mkdirs the dictionaries dir and curls the
    wordlist into it. Single ``sh -c`` line so ``InstallRunner`` runs
    it unchanged. The list goes in place only once it's all there (see
    ``shell_fetch``), and ``set -e`` stops before that on a failure;
    ``curl -f`` makes 4xx/5xx
    responses non-zero so we don't save a 404 HTML page as the
    wordlist."""
    var root = user_dictionaries_root()
    var dest = user_dictionary_path(language_id)
    return String("set -e; mkdir -p ") + shell_single_quote(root) + String("; ") \
        + shell_fetch(dest, url) + String("; ") + shell_move_into_place(dest)


def remove_user_dictionary(language_id: String) -> Bool:
    """Delete the on-disk wordlist for ``language_id``. Returns True on
    success or when the file was already gone. The caller is expected
    to ``Speller.reload`` afterwards so the in-memory bucket set drops
    those words too."""
    var path = user_dictionary_path(language_id)
    if len(path.as_bytes()) == 0:
        return False
    if not stat_file(path).ok:
        return True
    return delete_path(path)
