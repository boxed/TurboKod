"""``Editor.save``: what reaches the disk, and never over a change the
editor hasn't seen."""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.editor import Editor
from turbokod.file_io import read_file, write_file
from turbokod.lsp import capture_command
from support import _temp_path, setup_test_env


def _touch(path: String, when: String) raises:
    """Set ``path``'s mtime to ``when`` (YYYY-MM-DDThh:mm:ss.frac)."""
    var argv = List[String]()
    for a in ["touch", "-m", "-d", when]:
        argv.append(String(a))
    argv.append(path)
    _ = capture_command(argv)


def test_a_same_second_same_size_outside_change_is_merged_not_overwritten() raises:
    # only the nanoseconds tell the two versions apart
    var path = _temp_path(String("_save_race.txt"))
    assert_true(write_file(path, "one\nmid\ntwo\n"))
    _touch(path, "2020-01-01T00:00:00.1")
    var ed = Editor.from_file(path)
    assert_true(write_file(path, "one\nmid\nTWO\n"))
    _touch(path, "2020-01-01T00:00:00.2")
    ed.buffer.insert(0, 3, "!")
    ed.dirty = True
    assert_true(ed.save())
    assert_equal(read_file(path), "one!\nmid\nTWO\n")


def test_saving_without_a_file_does_nothing() raises:
    var ed = Editor(String("text"))
    assert_false(ed.save())


def test_a_failed_save_leaves_the_buffer_unsaved() raises:
    var path = _temp_path(String("_save_fails.txt"))
    assert_true(write_file(path, "a\n"))
    var ed = Editor.from_file(path)
    ed.file_path = path + "_missing_dir/file.txt"
    ed.buffer.insert(0, 0, "x")
    ed.dirty = True
    assert_false(ed.save())
    assert_true(ed.dirty)


def test_a_failed_save_as_keeps_the_old_file() raises:
    var path = _temp_path(String("_save_as_fails.txt"))
    assert_true(write_file(path, "a\n"))
    var ed = Editor.from_file(path)
    assert_false(ed.save_as(path + "_missing_dir/file.txt"))
    assert_equal(ed.file_path, path)


def test_nothing_is_written_while_a_merge_is_pending() raises:
    var path = _temp_path(String("_save_merge_pending.txt"))
    assert_true(write_file(path, "a\n"))
    var ed = Editor.from_file(path)
    ed.buffer.insert(0, 0, "x")
    ed.dirty = True
    ed.merge_pending = True
    assert_false(ed.save())
    assert_equal(read_file(path), "a\n")


def test_without_a_final_newline_setting_the_trailing_one_goes() raises:
    var path = _temp_path(String("_save_no_final_newline.txt"))
    assert_true(write_file(path, "a\nb\n"))
    var ed = Editor.from_file(path)
    ed.default_insert_final_newline = 0
    ed.dirty = True
    assert_true(ed.save())
    assert_equal(read_file(path), "a\nb")


def test_editorconfig_turning_off_the_final_newline_beats_the_default() raises:
    var path = _temp_path(String("_save_ec_final_newline.txt"))
    assert_true(write_file(path, "a"))
    var ed = Editor.from_file(path)
    ed.default_insert_final_newline = 1
    ed.editorconfig.insert_final_newline = 0
    ed.dirty = True
    assert_true(ed.save())
    assert_equal(read_file(path), "a")


def test_an_empty_file_stays_empty() raises:
    var path = _temp_path(String("_save_empty.txt"))
    assert_true(write_file(path, ""))
    var ed = Editor.from_file(path)
    ed.default_insert_final_newline = 1
    ed.dirty = True
    assert_true(ed.save())
    assert_equal(read_file(path), "")


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
