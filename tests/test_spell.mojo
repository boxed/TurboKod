"""Spell checking.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.file_io import read_file, stat_file, write_file
from turbokod.posix import getenv_value, which
from turbokod.spell import (
    Speller, find_misspelled_runs, has_spell_noinspection_directive,
    project_dict_path, user_dict_path
)
from turbokod.spell_menu import (
    SPELL_ACTION_ADD_PROJECT, SPELL_ACTION_ADD_USER, SPELL_ACTION_NONE,
    SpellMenu
)
from turbokod.settings import Settings
from turbokod.events import Event, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP
from turbokod.geometry import Point

from support import _spell_with_dict, setup_test_env


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
            lines.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    var saw = False
    for k in range(len(lines)):
        if lines[k] == String("turbokod"):
            saw = True
            break
    assert_true(saw)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


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
    assert_true(s.loaded)
    assert_true(s.check_word(String("tokenizer")))
    assert_true(s.check_word(String("bitwise")))
    assert_true(s.check_word(String("regex")))
    assert_true(s.check_word(String("hashable")))


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
    assert_true(s.loaded)
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
    assert_true(write_file(dict_path, String("smörgåsbord\n")))
    var s = Speller()
    s.load_default()
    assert_true(s.check_word(String("smörgåsbord")))
    # Drop the file and reload — the word must no longer be considered
    # known. Other layers (OS dict, bundled programmer terms) keep
    # ``loaded`` True so ``check_word`` doesn't fall into the
    # everything-passes degraded mode.
    _ = external_call["unlink", Int32]((dict_path + String("\0")).unsafe_ptr())
    s.reload()
    assert_true(s.loaded)
    assert_false(s.check_word(String("smörgåsbord")))


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


def main() raises:
    setup_test_env()
    test_speller_check_word_basic()
    test_speller_strips_common_suffixes()
    test_speller_handles_english_contractions()
    test_speller_unloaded_returns_true_for_everything()
    test_speller_set_project_loads_idea_dictionary()
    test_speller_set_project_with_no_idea_dir_is_noop()
    test_speller_add_user_word_persists_and_check_word_passes()
    test_speller_load_default_includes_bundled_programmer_terms()
    test_speller_load_default_layers_user_dictionary()
    test_speller_normalizes_unicode_for_lookup()
    test_speller_load_default_layers_user_language_dictionaries()
    test_speller_reload_drops_removed_dictionary()
    test_speller_add_project_word_persists_in_project_dir()
    test_spell_menu_open_close_default_selection()
    test_spell_menu_enter_on_user_resolves_with_add_user()
    test_spell_menu_enter_on_project_disabled_stays_open()
    test_spell_menu_enter_on_project_enabled_resolves_with_add_project()
    test_spell_menu_esc_dismisses()
    test_has_spell_noinspection_directive_parses_intellij_forms()
    print("spell: 19 tests passed")
