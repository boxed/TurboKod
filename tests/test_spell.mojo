"""Spell checking.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.file_io import read_file, stat_file, write_file
from turbokod.posix import getenv_value, which
from turbokod.spell import (
    Speller, free_spell_base, new_spell_base, find_misspelled_runs, has_spell_noinspection_directive,
    is_library_location, library_words_path, project_dict_path,
    user_dict_path
)
from turbokod.spell_menu import (
    SPELL_ACTION_ADD_PROJECT, SPELL_ACTION_ADD_USER, SPELL_ACTION_NONE,
    SpellMenu
)
from turbokod.settings import Settings
from turbokod.events import (
    Event, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_TAB, KEY_UP, MOUSE_BUTTON_LEFT,
)
from turbokod.geometry import Point, Rect
from turbokod.canvas import Canvas

from turbokod.spell_scan import ProjectSpellScan, spell_scan_files
from turbokod.library_words import LibraryNegatives, library_negatives_path
from turbokod.spelling_dialog import (
    SPELLING_ADD_PROJECT, SPELLING_ADD_USER, SpellingDialog,
)
from turbokod.events import MOD_META, MOD_SHIFT
from turbokod.ui_grid import GridForm
from turbokod.ui_tree import (
    ui_list_anchor, ui_list_row, ui_list_selected, ui_list_selection,
)
from support import (
    _canvas_row, _ensure_dir, _rm_rf, _spell_with_dict, _temp_path,
    setup_test_env,
)


def test_speller_check_word_basic() raises:
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var s = _spell_with_dict(words)
    assert_true(s.check_word(String("hello")))
    assert_true(s.check_word(String("Hello")))   # case-insensitive
    assert_true(s.check_word(String("WORLD")))
    assert_false(s.check_word(String("helo")))
    assert_false(s.check_word(String("xyzzy")))


def test_speller_strips_common_suffixes() raises:
    var words = List[String]()
    words.append(String("dog"))
    words.append(String("dish"))
    words.append(String("walk"))
    words.append(String("love"))
    words.append(String("foo"))
    var s = _spell_with_dict(words)
    assert_true(s.check_word(String("dogs")))    # plural -s
    assert_true(s.check_word(String("dog's")))   # possessive
    assert_true(s.check_word(String("dishes")))  # plural -es
    assert_true(s.check_word(String("walked")))  # past tense
    assert_true(s.check_word(String("walking"))) # gerund
    assert_true(s.check_word(String("loved")))   # foo+d
    assert_true(s.check_word(String("loving")))  # drop-e + ing
    assert_false(s.check_word(String("foob")))


def test_speller_handles_english_contractions() raises:
    """Contractions like ``hasn't`` and ``wouldn't`` must validate against
    their bare-verb head (``has``, ``would``). Without this the editor
    flags ``hasn`` / ``wouldn`` as misspelled because the OS dict
    doesn't list those forms. Both halves of the fix are exercised:
    ``find_misspelled_runs`` keeps the apostrophe inside the word, and
    ``check_word`` strips the trailing contraction."""
    var words = List[String]()
    words.append(String("has"))
    words.append(String("would"))
    words.append(String("did"))
    words.append(String("they"))
    words.append(String("you"))
    words.append(String("can"))
    words.append(String("won"))
    words.append(String("hello"))
    var s = _spell_with_dict(words)

    # n't contractions: head + "n't" must validate.
    assert_true(s.check_word(String("hasn't")))
    assert_true(s.check_word(String("wouldn't")))
    assert_true(s.check_word(String("didn't")))
    # Bare 't (cannot -> can't, will not -> won't).
    assert_true(s.check_word(String("can't")))
    assert_true(s.check_word(String("won't")))
    # 're / 've / 'll / 'd.
    assert_true(s.check_word(String("they're")))
    assert_true(s.check_word(String("they've")))
    assert_true(s.check_word(String("they'll")))
    assert_true(s.check_word(String("they'd")))
    assert_true(s.check_word(String("you're")))
    # Genuine misspellings still fail (head not in dict).
    assert_false(s.check_word(String("xyzzyn't")))

    # The tokenizer keeps apostrophe-in-word together so that the head
    # actually reaches check_word — without that fix, "hasn't" splits
    # into "hasn" + "t" and "hasn" gets flagged.
    var runs = find_misspelled_runs(s, String("hasn't wouldn't didn't"))
    assert_equal(len(runs), 0)


def test_speller_unloaded_returns_true_for_everything() raises:
    """When no dictionary is loaded, ``check_word`` must say "fine" for
    every input — better silent than a screen full of bogus underlines
    on systems without ``/usr/share/dict/words``."""
    var s = Speller()
    assert_true(s.check_word(String("definitelynotaword")))


def test_speller_set_project_loads_idea_dictionary() raises:
    """Words inside ``<project>/.idea/dictionaries/*.xml`` should be
    treated as correctly spelled — that's the team's shared vocabulary
    of names and domain terms. ``set_project`` folds them into
    ``project_buckets`` alongside ``.turbokod/dictionary.txt``."""
    var dir = String("/tmp/turbokod_idea_dict_") + String(
        Int(external_call["getpid", Int32]())
    )
    var idea = dir + String("/.idea")
    var dicts = idea + String("/dictionaries")
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (idea + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (dicts + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var xml_path = dicts + String("/boxed.xml")
    assert_true(write_file(xml_path, String(
        "<component name=\"ProjectDictionaryState\">\n"
        + "  <dictionary name=\"boxed\">\n"
        + "    <words>\n"
        + "      <w>turbokod</w>\n"
        + "      <w>aarrgh</w>\n"
        + "    </words>\n"
        + "  </dictionary>\n"
        + "</component>\n"
    )))
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    s.set_project(dir)
    # Project-specific words should now be looked up via project_buckets.
    assert_true(s.check_word(String("turbokod")))
    assert_true(s.check_word(String("aarrgh")))
    # Case-insensitive lookup still works.
    assert_true(s.check_word(String("Turbokod")))
    # And the previously-loaded baseline is preserved.
    assert_true(s.check_word(String("hello")))
    # An unrelated word stays misspelled.
    assert_false(s.check_word(String("xyzzy")))
    # Switching to a project without IDEA dicts must clear the words —
    # they're per-project, not session-wide.
    s.set_project(String("/tmp/turbokod_no_idea_here_xyzzy"))
    assert_false(s.check_word(String("turbokod")))
    assert_false(s.check_word(String("aarrgh")))
    # The session-wide baseline still holds.
    assert_true(s.check_word(String("hello")))
    _ = external_call["unlink", Int32]((xml_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dicts + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((idea + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_speller_set_project_with_no_idea_dir_is_noop() raises:
    """A project without a ``.idea/dictionaries/`` directory must not
    raise and must leave the existing dictionary untouched."""
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    s.set_project(String("/tmp/turbokod_no_idea_here_xyzzy"))
    assert_true(s.check_word(String("hello")))
    assert_false(s.check_word(String("xyzzy")))


def test_speller_add_user_word_persists_and_check_word_passes() raises:
    """``add_user_word`` should both flip ``check_word`` to True for
    that word *and* append it to ``~/.config/turbokod/dictionary.txt``
    so the addition survives a restart. Tests run with ``HOME`` set to
    a scratch dir, so the file path is predictable."""
    var path = user_dict_path()
    # Defensive cleanup — earlier tests may have written here.
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    assert_false(s.check_word(String("turbokod")))
    assert_true(s.add_user_word(String("turbokod")))
    # In-memory: subsequent lookups pass without touching the file.
    assert_true(s.check_word(String("turbokod")))
    # On-disk: the file exists and contains the word.
    var content = read_file(path)
    var lines = List[String]()
    var b = content.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x0A:
            lines.append(String(StringSpan(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    var saw = False
    for k in range(len(lines)):
        if lines[k] == String("turbokod"):
            saw = True
            break
    assert_true(saw)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_is_library_location_outside_project_or_in_dependency_dirs() raises:
    """A definition outside the project, or under a virtualenv /
    ``node_modules`` / pixi env inside it, is a library's; the project's
    own files aren't, and with no project nothing is."""
    var root = String("/work/proj")
    assert_true(is_library_location(
        String("/usr/lib/python3.12/shutil.py"), root,
    ))
    assert_true(is_library_location(
        String("/work/proj/.venv/lib/python3.12/site-packages/x/y.py"), root,
    ))
    assert_true(is_library_location(
        String("/work/proj/web/node_modules/react/index.d.ts"), root,
    ))
    assert_false(is_library_location(String("/work/proj/src/main.py"), root))
    # A sibling sharing the prefix is outside the project.
    assert_true(is_library_location(String("/work/project2/a.py"), root))
    # A file merely *named* like a dependency dir is the project's.
    assert_false(is_library_location(String("/work/proj/venv"), root))
    assert_false(is_library_location(
        String("/usr/lib/python3.12/shutil.py"), String(""),
    ))


def test_speller_library_words_persist_and_reload() raises:
    """``add_library_word`` writes ``library_words.txt``, not the user
    dictionary, and a fresh ``load_default`` picks it up."""
    var path = library_words_path()
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    var udp = user_dict_path()
    _ = external_call["unlink", Int32]((udp + String("\0")).unsafe_ptr())
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    assert_false(s.check_word(String("rmtree")))
    var v = s.word_version()
    assert_true(s.add_library_word(String("rmtree")))
    assert_true(s.check_word(String("rmtree")))
    assert_true(s.word_version() > v)
    assert_equal(read_file(path), String("rmtree\n"))
    assert_false(stat_file(udp).ok)
    # Already known: the file isn't appended to again.
    assert_true(s.add_library_word(String("rmtree")))
    assert_equal(read_file(path), String("rmtree\n"))
    var fresh = Speller()
    fresh.load_default()
    assert_true(fresh.check_word(String("rmtree")))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_spellers_sharing_a_base_hold_one_word_set() raises:
    """Windows of one process read one main word set
    (``Speller.shared``): what one loads the other knows, and a word added
    through one changes the other's ``word_version`` so its editors
    re-check. Project words stay per speller."""
    var udp = user_dict_path()
    _ = external_call["unlink", Int32]((udp + String("\0")).unsafe_ptr())
    var base = new_spell_base()
    assert_true(base != 0)
    var a = Speller()
    var b = Speller()
    a.shared = base
    b.shared = base
    assert_false(b.is_loaded())
    var seed = List[String]()
    seed.append(String("hello"))
    a.load_words(seed)
    # Loaded through ``a``, known to ``b``.
    assert_true(b.is_loaded())
    assert_true(b.check_word(String("hello")))
    assert_false(b.check_word(String("frobnicate")))
    var v = b.word_version()
    _ = a.add_user_word(String("frobnicate"))
    assert_true(b.check_word(String("frobnicate")))
    assert_true(b.word_version() > v)
    # A speller without the base is untouched.
    var alone = Speller()
    assert_false(alone.is_loaded())
    _ = external_call["unlink", Int32]((udp + String("\0")).unsafe_ptr())
    free_spell_base(base)


def test_speller_load_default_includes_bundled_programmer_terms() raises:
    """``load_default`` must layer the bundled cspell-derived wordlists
    on top of the OS dict so common programmer vocabulary that
    ``/usr/share/dict/words`` lacks (``tokenizer``, ``bitwise``,
    ``regex``, ``hashable``) doesn't show up as misspelled inside
    comments and docstrings. Tests run with cwd = project root so the
    relative path ``src/turbokod/data/wordlists`` resolves."""
    var s = Speller()
    s.load_default()
    # If neither OS list nor bundled list loaded, ``check_word`` returns
    # True for everything and this test is uninformative — but the
    # bundled list ships with the repo so on any developer machine it
    # should always be present.
    assert_true(s.is_loaded())
    assert_true(s.check_word(String("tokenizer")))
    assert_true(s.check_word(String("bitwise")))
    assert_true(s.check_word(String("regex")))
    assert_true(s.check_word(String("hashable")))


def test_speller_load_default_includes_modern_english() raises:
    """The bundled SCOWL ``english.txt`` must cover inflected and modern
    words. macOS's ``/usr/share/dict/words`` is Webster's 1934 with no
    inflections, and the suffix stripper can't reach y→ies, doubled
    consonants or irregular forms. Every word here once had to be
    added to a project dictionary by hand."""
    var s = Speller()
    s.load_default()
    var words = List[String]()
    for w in [
        "newer", "planned", "sitemap", "downtime", "superuser",
        "modifies", "applies", "held", "queries", "planning",
        "verified", "troubleshooting", "checklist", "paid",
        "recursively", "deterministically", "companies", "submitted",
        "summing", "loudest", "catalog", "died", "overridden",
        "copies", "supplied", "notifies", "identified", "meantime",
        "quantities", "standalone",
    ]:
        words.append(String(w))
    for i in range(len(words)):
        if not s.check_word(words[i]):
            raise Error(String("not in dictionary: ") + words[i])
    # A typo must still be caught.
    assert_false(s.check_word(String("recieve")))


def test_speller_load_default_layers_user_dictionary() raises:
    """A subsequent ``Speller`` started after ``add_user_word`` writes
    the file should pick the addition up via ``load_default``. Verifies
    the persistence round-trips end to end."""
    var path = user_dict_path()
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    # Seed the user dict directly via the public API on a throwaway
    # speller so we don't depend on internals of the file layout.
    var primer = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    primer.load_words(seed)
    _ = primer.add_user_word(String("turbokod"))
    # Fresh speller; load_default should fold in the user dict.
    var s = Speller()
    s.load_default()
    # ``loaded`` is True because *something* was loaded — either an OS
    # list or the user dict (depending on the runner). Either way the
    # added word must check out.
    assert_true(s.check_word(String("turbokod")))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_speller_normalizes_unicode_for_lookup() raises:
    """Lookup keys must fold both case and Unicode form so a Swedish
    word like ``Övrigt`` (Ö = U+00D6) matches the on-disk lowercase
    NFC form ``övrigt`` (ö = U+00F6), and so does the NFD form
    ``O`` + combining diaeresis (U+004F U+0308) that macOS-sourced text
    sometimes ships in. Without this fix neither uppercase nor NFD
    forms hashed to the same bucket as the wordlist's NFC lowercase
    entry, and ``Övrigt`` was wrongly flagged as misspelled."""
    var s = Speller()
    var seed = List[String]()
    seed.append(String("övrigt"))
    seed.append(String("café"))
    s.load_words(seed)
    # NFC uppercase: bytes ``0xC3 0x96`` for Ö.
    assert_true(s.check_word(String("Övrigt")))
    # NFC mixed case in the middle.
    assert_true(s.check_word(String("öVrigt")))
    # NFD: O + combining diaeresis (U+004F U+0308).
    # Mojo 1.0 string escapes interpret ``\xCC`` as codepoint U+00CC, not
    # as the raw byte 0xCC — so we build the combining mark via ``chr``
    # to get the intended UTF-8 byte sequence ``CC 88``.
    var nfd_uppercase = String("O") + chr(0x308) + String("vrigt")
    assert_true(s.check_word(nfd_uppercase))
    # NFD lowercase: o + combining diaeresis.
    var nfd_lowercase = String("o") + chr(0x308) + String("vrigt")
    assert_true(s.check_word(nfd_lowercase))
    # And acute (U+0301) on e: ``café`` decomposes to e + U+0301.
    var cafe_nfd = String("cafe") + chr(0x301)
    assert_true(s.check_word(cafe_nfd))


def test_speller_load_default_layers_user_language_dictionaries() raises:
    """A wordlist dropped under ``~/.config/turbokod/dictionaries/`` is
    picked up by ``load_default``, mirroring the bundled-wordlists
    layer. This is the on-disk shape Settings ▸ Spell-check writes via
    its install-runner curl."""
    var home = getenv_value(String("HOME"))
    var dir = home + String("/.config/turbokod/dictionaries")
    _ = external_call["mkdir", Int32](
        ((home + String("/.config")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        ((home + String("/.config/turbokod")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var dict_path = dir + String("/de.txt")
    assert_true(write_file(dict_path, String("Schmetterling\nKühlschrank\n")))
    var s = Speller()
    s.load_default()
    assert_true(s.is_loaded())
    assert_true(s.check_word(String("Schmetterling")))
    assert_true(s.check_word(String("Kühlschrank")))
    _ = external_call["unlink", Int32]((dict_path + String("\0")).unsafe_ptr())


def test_speller_reload_drops_removed_dictionary() raises:
    """``reload`` must rebuild the bucket set from disk so removing the
    on-disk wordlist makes its words fall back to "misspelled" without
    restarting the editor. Used by Settings ▸ Spell-check ▸ Remove."""
    var home = getenv_value(String("HOME"))
    var dir = home + String("/.config/turbokod/dictionaries")
    _ = external_call["mkdir", Int32](
        ((home + String("/.config")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        ((home + String("/.config/turbokod")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var dict_path = dir + String("/sv.txt")
    assert_true(write_file(dict_path, String("kanelbullarna\n")))
    var s = Speller()
    s.load_default()
    assert_true(s.check_word(String("kanelbullarna")))
    # Drop the file and reload — the word must no longer be considered
    # known. Other layers (OS dict, bundled programmer terms) keep
    # ``loaded`` True so ``check_word`` doesn't fall into the
    # everything-passes degraded mode.
    _ = external_call["unlink", Int32]((dict_path + String("\0")).unsafe_ptr())
    s.reload()
    assert_true(s.is_loaded())
    assert_false(s.check_word(String("kanelbullarna")))


def test_speller_add_project_word_persists_in_project_dir() raises:
    """``add_project_word`` writes ``<project>/.turbokod/dictionary.txt``
    and updates ``project_buckets`` in memory. ``set_project`` must
    have been called first; without it the call is a no-op."""
    var dir = String("/tmp/turbokod_proj_dict_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    # Without set_project, the call short-circuits to False and the
    # word stays misspelled.
    assert_false(s.add_project_word(String("turbokod")))
    assert_false(s.check_word(String("turbokod")))
    # With set_project active, the word sticks in memory and lands on
    # disk under .turbokod/dictionary.txt.
    s.set_project(dir)
    assert_true(s.add_project_word(String("turbokod")))
    assert_true(s.check_word(String("turbokod")))
    var dict_path = project_dict_path(dir)
    assert_equal(dict_path, dir + String("/.turbokod/dictionary.txt"))
    var info = stat_file(dict_path)
    assert_true(info.ok)
    # Switching to a different project clears the in-memory entry —
    # project words are per-project, never session-wide.
    s.set_project(String(""))
    assert_false(s.check_word(String("turbokod")))
    # And reloading the same project restores them from disk.
    s.set_project(dir)
    assert_true(s.check_word(String("turbokod")))
    _ = external_call["unlink", Int32](
        (dict_path + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32](
        ((dir + String("/.turbokod")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_a_dictionary_that_cant_be_read_isnt_written_over() raises:
    var dir = _temp_path(String("_proj_dict_unreadable"))
    _rm_rf(dir)
    _ensure_dir(dir + "/.turbokod")
    var dict_path = project_dict_path(dir)
    assert_true(write_file(dict_path, "alpha\nbeta\n"))
    var s = Speller()
    s.set_project(dir)
    _ = external_call["chmod", Int32]((dict_path + "\0").unsafe_ptr(), UInt16(0))
    assert_false(s.add_project_word(String("gamma")))
    _ = external_call["chmod", Int32]((dict_path + "\0").unsafe_ptr(), UInt16(0o644))
    assert_equal(read_file(dict_path), "alpha\nbeta\n")
    _rm_rf(dir)


def test_spell_menu_open_close_default_selection() raises:
    """Open positions selection on row 0 (user dict) regardless of
    whether the project row is enabled — that's the safe default
    every time, easier to undo than accidentally training the team
    dict with a personal word."""
    var m = SpellMenu()
    m.open(String("helo"), Point(10, 5), True)
    assert_true(m.active)
    assert_equal(m.selected, 0)
    assert_equal(m.word, String("helo"))
    assert_true(m.has_project)
    m.close()
    assert_false(m.active)
    # Open without a project: user-dict still selectable, project row
    # rendered but ``has_project=False`` so Enter on it is a no-op.
    m.open(String("helo"), Point(0, 0), False)
    assert_false(m.has_project)


def test_spell_menu_enter_on_user_resolves_with_add_user() raises:
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), True)
    var ev = Event.key_event(KEY_ENTER)
    _ = m.handle_key(ev)
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_ADD_USER)


def test_spell_menu_enter_on_project_disabled_stays_open() raises:
    """When ``has_project=False``, pressing Enter on the project row
    must NOT submit — the menu stays open so the user can arrow back
    up to the user-dict row."""
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), False)
    _ = m.handle_key(Event.key_event(KEY_DOWN))
    assert_equal(m.selected, 1)
    _ = m.handle_key(Event.key_event(KEY_ENTER))
    assert_false(m.submitted)
    assert_true(m.active)
    # Arrow back up — the user-dict pick still works.
    _ = m.handle_key(Event.key_event(KEY_UP))
    assert_equal(m.selected, 0)
    _ = m.handle_key(Event.key_event(KEY_ENTER))
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_ADD_USER)


def test_spell_menu_enter_on_project_enabled_resolves_with_add_project() raises:
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), True)
    _ = m.handle_key(Event.key_event(KEY_DOWN))
    _ = m.handle_key(Event.key_event(KEY_ENTER))
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_ADD_PROJECT)


def test_spell_menu_esc_dismisses() raises:
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), True)
    _ = m.handle_key(Event.key_event(KEY_ESC))
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_NONE)


def test_has_spell_noinspection_directive_parses_intellij_forms() raises:
    """Recognized IntelliJ shapes — comma-separated lists, ``All``
    catch-all, multiple comment markers — must all return True.
    Adversarial near-misses (different inspection name, ``noinspection``
    embedded in a longer identifier) must not."""
    # Bare directive (caller has already stripped the comment marker).
    assert_true(has_spell_noinspection_directive(
        String("noinspection SpellCheckingInspection")
    ))
    # Common in-source forms with the comment marker still attached
    # — the function operates on the slice the editor extracts, which
    # for a Python ``# ...`` comment includes the leading ``#``.
    assert_true(has_spell_noinspection_directive(
        String("# noinspection SpellCheckingInspection")
    ))
    assert_true(has_spell_noinspection_directive(
        String("// noinspection SpellCheckingInspection")
    ))
    assert_true(has_spell_noinspection_directive(
        String("<!-- noinspection SpellCheckingInspection -->")
    ))
    # Comma-separated list with the spell inspection somewhere in it.
    assert_true(has_spell_noinspection_directive(
        String("# noinspection PyUnresolvedReferences,SpellCheckingInspection")
    ))
    assert_true(has_spell_noinspection_directive(
        String("# noinspection SpellCheckingInspection,PyUnresolvedReferences")
    ))
    # Catch-all ``All`` disables every inspection — including spell.
    assert_true(has_spell_noinspection_directive(
        String("# noinspection All")
    ))
    # Negative cases.
    assert_false(has_spell_noinspection_directive(
        String("# helo world")
    ))
    assert_false(has_spell_noinspection_directive(
        String("# noinspection PyUnresolvedReferences")
    ))
    # Word boundary on the keyword itself: ``xnoinspection`` mustn't
    # count.
    assert_false(has_spell_noinspection_directive(
        String("# xnoinspection SpellCheckingInspection")
    ))
    # Empty / no-trailing-list directive is a no-op.
    assert_false(has_spell_noinspection_directive(
        String("# noinspection")
    ))


def _scan_fixture(root: String) raises -> List[String]:
    _rm_rf(root)
    _ensure_dir(root)
    var files = List[String]()
    files.append(root + String("/a.py"))
    _ = write_file(files[0], String(
        "# zorbly zorbly words here\n"
        "zorbly = 1  # identifiers are checked too\n"
        "s = 'Zorbly and frobnix'\n"
        "# noinspection SpellCheckingInspection\n"
        "# frobnix is suppressed on this line\n"
    ))
    files.append(root + String("/b.py"))
    _ = write_file(files[1], String("# frobnix's quux words\n"))
    files.append(root + String("/blob.bin"))
    _ = write_file(files[2], String("zorbly\x00zorbly\n"))
    files.append(root + String("/missing.py"))
    return files^


def _fixture_speller() -> Speller:
    var dict_words = List[String]()
    for w in ["words", "here", "identifiers", "are", "never", "checked",
              "and", "noinspection", "is", "suppressed", "on", "this",
              "line", "SpellCheckingInspection"]:
        dict_words.append(String(w))
    return _spell_with_dict(dict_words)


def test_project_spell_scan_counts_flagged_words() raises:
    """Counts every word the editor would underline — identifiers too,
    nothing under a ``noinspection`` directive — folds case and
    possessives into one row, and skips binary and unreadable files."""
    var root = _temp_path(String("_spell_scan"))
    var files = _scan_fixture(root)
    var speller = _fixture_speller()
    var scan = ProjectSpellScan()
    scan.start(files^)
    var spins = 0
    while scan.step(5, speller) and spins < 1000:
        spins += 1
    assert_false(scan.active)
    assert_equal(scan.files_checked, 2)
    var zorbly = -1
    var frobnix = -1
    var quux = -1
    for i in range(len(scan.words)):
        if scan.words[i].key == String("zorbly"):
            zorbly = i
        elif scan.words[i].key == String("frobnix"):
            frobnix = i
        elif scan.words[i].key == String("quux"):
            quux = i
    assert_equal(len(scan.words), 3)
    # Two in the first comment, the identifier, and the capitalized one
    # in the string.
    assert_equal(scan.words[zorbly].count, 4)
    assert_equal(scan.words[zorbly].word, String("zorbly"))
    assert_equal(scan.words[zorbly].line, 1)
    # ``frobnix's`` groups with ``frobnix``; the suppressed line doesn't count.
    assert_equal(scan.words[frobnix].count, 2)
    assert_equal(scan.words[quux].count, 1)
    var drop = List[String]()
    drop.append(String("zorbly"))
    scan.remove_keys(drop)
    assert_equal(len(scan.words), 2)
    _rm_rf(root)


def test_project_spell_scan_counts_across_many_files() raises:
    """Every file is checked exactly once however the time budget slices
    the work, and progress reaches 100%."""
    var root = _temp_path(String("_spell_many"))
    _rm_rf(root)
    _ensure_dir(root)
    var files = List[String]()
    for i in range(24):
        var p = root + String("/f") + String(i) + String(".py")
        var body = String("")
        for k in range(i + 1):
            body += String("# zorbly line ") + String(k) + String(" quuxed\n")
        _ = write_file(p, body)
        files.append(p)
    var speller = _fixture_speller()
    var scan = ProjectSpellScan()
    scan.start(files^)
    var spins = 0
    while scan.step(0, speller) and spins < 5000:
        spins += 1
    assert_false(scan.active)
    assert_equal(scan.files_checked, 24)
    assert_equal(len(scan.words), 2)    # zorbly, quuxed
    for i in range(len(scan.words)):
        assert_equal(scan.words[i].count, 300)
    assert_true(scan.progress() >= 1.0)
    _rm_rf(root)


def test_spell_scan_files_skips_binaries_by_extension() raises:
    """Binaries are dropped before anything is read: known extensions,
    and everything inside a bundle directory that has one — but only
    below the project root, so a root under ``Foo.app/`` still scans."""
    var root = _temp_path(String("_spell_files.app"))
    _rm_rf(root)
    _ensure_dir(root + String("/Design.pxd/data"))
    _ = write_file(root + String("/a.py"), String("# hi\n"))
    _ = write_file(root + String("/photo.JPG"), String("x"))
    _ = write_file(root + String("/font.woff2"), String("x"))
    _ = write_file(root + String("/Design.pxd/data/blob"), String("x"))
    # Translation catalogs are other languages' text, not misspellings.
    _ = write_file(root + String("/django.po"), String("msgid \"x\"\n"))
    _ = write_file(root + String("/django.pot"), String("msgid \"x\"\n"))
    _ = write_file(root + String("/django.mo"), String("x"))
    var files = spell_scan_files(root)
    assert_equal(len(files), 1)
    assert_true(files[0].endswith("/a.py"))
    _rm_rf(root)


def _drive(mut d: SpellingDialog, mut g: GridForm, ev: Event, screen: Rect):
    """One event through the grid projector, applied as the host does."""
    var evs = g.handle_event(d.ui(), ev, screen)
    for i in range(len(evs)):
        if evs[i].is_action:
            d.ui_act(evs[i].key)
        else:
            d.ui_set(evs[i].key, evs[i].value)


def _row_of(c: Canvas, word: String) -> Int:
    for y in range(c.height):
        if word in _canvas_row(c, y, 0, c.width):
            return y
    return -1


def test_spelling_dialog_multi_select_and_submit() raises:
    """Rows sort by count; in the grid projection click, Shift-click and
    Cmd-click build the selection (a Cmd-click one the list reports row by
    row); an Add button submits the selected keys and ``acknowledge``
    removes them."""
    var root = _temp_path(String("_spell_dialog"))
    var files = _scan_fixture(root)
    var speller = _fixture_speller()
    var d = SpellingDialog()
    d.open(files^, True, root)
    var spins = 0
    while d.scan.active and spins < 1000:
        d.tick(speller)
        spins += 1
    d.tick(speller)
    var screen = Rect(0, 0, 100, 40)
    var canvas = Canvas(100, 40)
    var g = GridForm()
    g.paint(d.ui(), canvas, screen)
    assert_equal(len(d.order), 3)
    assert_equal(d.scan.words[d.order[0]].key, String("zorbly"))
    assert_equal(d.scan.words[d.order[1]].key, String("frobnix"))
    assert_equal(d.scan.words[d.order[2]].key, String("quux"))
    var top = _row_of(canvas, String("zorbly"))
    assert_true(top > 0)
    assert_equal(_row_of(canvas, String("quux")), top + 2)
    var x = -1
    for cx in range(canvas.width - 6):
        if _canvas_row(canvas, top, cx, cx + 6) == String("zorbly"):
            x = cx
            break
    assert_true(x > 0)
    # Click row 0, Shift-click row 2: all three.
    _drive(d, g, Event.mouse_event(Point(x, top), MOUSE_BUTTON_LEFT), screen)
    _drive(d, g, Event.mouse_event(
        Point(x, top + 2), MOUSE_BUTTON_LEFT, mods=MOD_SHIFT,
    ), screen)
    assert_equal(len(d.selected_keys()), 3)
    # Cmd-click row 1 drops it: no longer one range.
    _drive(d, g, Event.mouse_event(
        Point(x, top + 1), MOUSE_BUTTON_LEFT, mods=MOD_META,
    ), screen)
    var keys = d.selected_keys()
    assert_equal(len(keys), 2)
    assert_equal(keys[0], String("zorbly"))
    assert_equal(keys[1], String("quux"))
    # The selection follows its words through a repaint (a re-sort).
    d._resort()
    g.paint(d.ui(), canvas, screen)
    assert_equal(len(d.selected_keys()), 2)
    # Down moves the cursor and selects just that row.
    _drive(d, g, Event.key_event(KEY_DOWN), screen)
    keys = d.selected_keys()
    assert_equal(len(keys), 1)
    assert_equal(keys[0], String("quux"))
    d.ui_act(String("user"))
    assert_true(d.submitted)
    assert_equal(d.action, SPELLING_ADD_USER)
    d.acknowledge(d.selected_keys())
    assert_false(d.submitted)
    assert_equal(len(d.order), 2)
    assert_equal(len(d.selected_keys()), 0)
    _drive(d, g, Event.key_event(KEY_ESC), screen)
    assert_false(d.active)
    _rm_rf(root)


def test_list_selection_values() raises:
    """A ``UI_MULTI`` list's value: a row, a range, or rows listed."""
    assert_equal(ui_list_selection(-1, 3, [3]), String("3"))
    assert_equal(ui_list_selection(1, 3, [1, 2, 3]), String("1:3"))
    var v = ui_list_selection(1, 3, [1, 3])
    assert_equal(v, String("1:3:1,3"))
    assert_equal(ui_list_row(v), 3)
    assert_equal(ui_list_anchor(v), 1)
    var rows = ui_list_selected(v)
    assert_equal(len(rows), 2)
    assert_equal(rows[1], 3)
    assert_equal(len(ui_list_selected(String("4:2"))), 3)
    assert_equal(len(ui_list_selected(String(""))), 0)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_spell_scan_keeps_occurrences_for_the_library_check() raises:
    """Each word keeps up to three occurrences, on different lines, with
    0-based row and byte column — what the library check looks up."""
    var root = _temp_path(String("_spell_occ"))
    var files = _scan_fixture(root)
    var speller = _fixture_speller()
    var scan = ProjectSpellScan()
    scan.start(files^)
    while scan.step(5, speller):
        pass
    for i in range(len(scan.words)):
        ref occ = scan.occurrences[i]
        if scan.words[i].key == String("zorbly"):
            # Four occurrences, two on the first line: rows 0, 1, 2.
            assert_equal(len(occ), 3)
            assert_equal(occ[0].row, 0)
            assert_equal(occ[0].col, 2)
            assert_equal(occ[1].row, 1)
            assert_equal(occ[2].row, 2)
            assert_equal(occ[2].col, 5)
        elif scan.words[i].key == String("quux"):
            assert_equal(len(occ), 1)
            assert_equal(occ[0].path, root + String("/b.py"))
            assert_equal(occ[0].col, 12)
    _rm_rf(root)


def test_library_negatives_persist_merge_and_expire() raises:
    """Ruled-out words survive a reload, two writers' entries merge, and
    an entry older than the TTL counts as unknown again."""
    var root = _temp_path(String("_lib_neg"))
    _rm_rf(root)
    _ensure_dir(root)
    var a = LibraryNegatives()
    a.set_project(root)
    var b = LibraryNegatives()
    b.set_project(root)
    a.add(String("zorbly"))
    b.add(String("frobnix"))
    a.flush()
    b.flush()
    var c = LibraryNegatives()
    c.set_project(root)
    assert_true(c.contains(String("zorbly")))
    assert_true(c.contains(String("frobnix")))
    assert_false(c.contains(String("quux")))
    _ = write_file(library_negatives_path(root), String("stale\t1\n"))
    var d = LibraryNegatives()
    d.set_project(root)
    assert_false(d.contains(String("stale")))
    # No project: nothing is recorded.
    var e = LibraryNegatives()
    e.add(String("zorbly"))
    assert_false(e.contains(String("zorbly")))
    _rm_rf(root)


def test_spelling_dialog_library_check_jobs() raises:
    """After the scan, the library check queues each word's kept
    occurrences grouped by file, minus ruled-out words; a hit drops the
    word's row and its remaining lookups, and a word missed at every
    occurrence is reported ruled out — unless one couldn't be looked up."""
    var root = _temp_path(String("_spell_libcheck"))
    var files = _scan_fixture(root)
    var speller = _fixture_speller()
    var negatives = LibraryNegatives()
    negatives.set_project(root)
    negatives.add(String("quux"))
    var d = SpellingDialog()
    d.open(files^, True, root)
    while d.scan.active:
        d.tick(speller)
    assert_true(d.library_check_due())
    d.start_library_check(negatives)
    assert_false(d.library_check_due())
    assert_true(d.library_checking())
    var seen = List[String]()
    var ruled_out = List[String]()
    while True:
        var job = d.peek_library_job()
        if not job:
            break
        var j = job.value()
        d.pop_library_job()
        seen.append(j.key + String("@") + String(j.at.row))
        assert_true(j.key != String("quux"))
        if j.key == String("zorbly"):
            _ = d.library_result(j.key, True)
        elif d.library_result(j.key, False):
            ruled_out.append(j.key)
    assert_false(d.library_checking())
    # zorbly is looked up once: the hit skips its other two occurrences.
    # a.py's lookups come before b.py's.
    assert_equal(len(seen), 3)
    assert_equal(seen[0], String("zorbly@0"))
    assert_equal(seen[1], String("frobnix@2"))
    assert_equal(seen[2], String("frobnix@0"))
    assert_equal(len(ruled_out), 1)
    assert_equal(ruled_out[0], String("frobnix"))
    d.tick(speller)
    assert_equal(len(d.scan.words), 2)
    for i in range(len(d.order)):
        assert_true(d.scan.words[d.order[i]].key != String("zorbly"))
    # A skipped occurrence keeps a word from being ruled out.
    d.start_library_check(LibraryNegatives())
    var skipped_once = False
    var frobnix_out = False
    while True:
        var job = d.peek_library_job()
        if not job:
            break
        var j = job.value()
        d.pop_library_job()
        if j.key != String("frobnix"):
            _ = d.library_result(j.key, False)
        elif not skipped_once:
            skipped_once = True
            d.library_skip(j.key)
        elif d.library_result(j.key, False):
            frobnix_out = True
    assert_true(skipped_once)
    assert_false(frobnix_out)
    _rm_rf(root)
