"""Settings ▸ Projects and File ▸ Quick open project (Cmd+Shift+O).

Shared fixtures live in ``tests/support.mojo`` and
``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.config import TurbokodConfig, _config_from_json, _config_to_json
from turbokod.desktop import (
    Desktop, PROJECT_QUICK_OPEN, _abbreviate_home, _expand_home
)
from turbokod.events import Event, KEY_ENTER
from turbokod.file_io import join_path, write_file
from turbokod.settings import Settings, _FOCUS_PROJ_INPUT, _FOCUS_PROJ_REMOVE

from support import _SCREEN, _ensure_dir, _key, _test_home, setup_test_env


def _type(mut s: Settings, text: String):
    for cp in text.codepoints():
        _ = s.handle_key(_key(UInt32(Int(cp))))


def test_project_dirs_round_trip_through_config_json() raises:
    var cfg = TurbokodConfig()
    cfg.project_dirs.append(String("~/Projects"))
    cfg.project_dirs.append(String("/work"))
    var back = _config_from_json(_config_to_json(cfg))
    assert_equal(len(back.project_dirs), 2)
    assert_equal(back.project_dirs[0], String("~/Projects"))
    assert_equal(back.project_dirs[1], String("/work"))


def test_home_expansion_and_abbreviation() raises:
    var home = String("/Users/me")
    assert_equal(_expand_home(String("~"), home), home)
    assert_equal(_expand_home(String("~/src"), home), String("/Users/me/src"))
    assert_equal(_expand_home(String("~bob/x"), home), String("~bob/x"))
    assert_equal(_expand_home(String("/abs"), home), String("/abs"))
    assert_equal(
        _abbreviate_home(String("/Users/me/src/a"), home), String("~/src/a"),
    )
    assert_equal(
        _abbreviate_home(String("/Users/meow/a"), home),
        String("/Users/meow/a"),
    )


def test_settings_projects_add_and_remove() raises:
    """Typing a folder and pressing Enter appends it (trailing slash
    dropped, duplicates ignored) and raises ``dirty``; Remove drops the
    selected row."""
    var existing = List[String]()
    existing.append(String("/work"))
    var s = Settings()
    s.open(False, project_dirs=existing^)
    assert_equal(s.selected_project_dir, 0)
    s.focus = _FOCUS_PROJ_INPUT
    _type(s, String("~/Projects/"))
    _ = s.handle_key(Event.key_event(KEY_ENTER))
    assert_true(s.dirty)
    assert_equal(len(s.project_dirs), 2)
    assert_equal(s.project_dirs[1], String("~/Projects"))
    assert_equal(s.selected_project_dir, 1)
    # Re-adding an existing folder just selects it.
    _type(s, String("/work"))
    _ = s.handle_key(Event.key_event(KEY_ENTER))
    assert_equal(len(s.project_dirs), 2)
    assert_equal(s.selected_project_dir, 0)
    s.focus = _FOCUS_PROJ_REMOVE
    _ = s.handle_key(Event.key_event(KEY_ENTER))
    assert_equal(len(s.project_dirs), 1)
    assert_equal(s.project_dirs[0], String("~/Projects"))


def test_quick_open_project_lists_subdirectories() raises:
    """The picker lists the non-hidden subdirectories of every configured
    folder (files skipped), sorted, ``~``-abbreviated; Enter opens the
    picked one as the project."""
    var root = join_path(_test_home(), String("qop_projects"))
    _ensure_dir(join_path(root, String("beta")))
    _ensure_dir(join_path(root, String("alpha")))
    _ensure_dir(join_path(root, String(".hidden")))
    _ = write_file(join_path(root, String("notes.txt")), String("x"))
    var d = Desktop()
    d.config.project_dirs.append(String("~/qop_projects"))
    _ = d.dispatch_action(PROJECT_QUICK_OPEN, _SCREEN)
    assert_true(d.quick_open.active)
    assert_true(d.quick_open.picks_project)
    assert_equal(len(d.quick_open.entries), 2)
    assert_equal(d.quick_open.entries[0], String("~/qop_projects/alpha"))
    assert_equal(d.quick_open.entries[1], String("~/qop_projects/beta"))
    _ = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_false(d.quick_open.active)
    assert_true(d.project)
    # ``open_project`` canonicalizes (``/tmp`` → ``/private/tmp``).
    assert_true(d.project.value().endswith(String("/qop_projects/alpha")))
    d.shutdown()


def test_quick_open_project_without_folders_does_not_open() raises:
    var d = Desktop()
    _ = d.dispatch_action(PROJECT_QUICK_OPEN, _SCREEN)
    assert_false(d.quick_open.active)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
