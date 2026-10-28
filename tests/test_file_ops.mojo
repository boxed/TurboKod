"""File operations from the tab and file-tree menus."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.desktop import Desktop
from turbokod.file_io import list_directory, read_file, stat_file, write_file
from turbokod.geometry import Rect
from support import _temp_path, setup_test_env


def test_duplicating_an_open_file_keeps_its_line_endings() raises:
    var dir = _temp_path(String("_dup_crlf"))
    _ = external_call["system", Int32]((String("rm -rf '") + dir + String("'; mkdir -p '") + dir + String("'\0")).unsafe_ptr())
    var path = dir + String("/win.txt")
    assert_equal(write_file(path, String("one\r\ntwo\r\n")), True)
    var d = Desktop()
    d.open_file(path, Rect(0, 0, 80, 30))
    d._file_op_path = path
    d._do_duplicate_file(String("copy.txt"))
    assert_equal(read_file(dir + String("/copy.txt")), String("one\r\ntwo\r\n"))


def _fresh_dir(name: String) -> String:
    var dir = _temp_path(name)
    _ = external_call["system", Int32]((String("rm -rf '") + dir + String("'; mkdir -p '") + dir + String("'\0")).unsafe_ptr())
    return dir^


def test_renaming_only_the_case_of_a_name() raises:
    # On a case-insensitive disk the new name "exists": it's the same file
    var dir = _fresh_dir(String("_rename_case"))
    assert_true(write_file(dir + String("/readme.md"), String("hi\n")))
    var d = Desktop()
    d._file_op_path = dir + String("/readme.md")
    d._do_rename_file(String("README.md"))
    var names = list_directory(dir)
    assert_equal(len(names), 1)
    assert_equal(names[0], String("README.md"))


def test_renaming_onto_another_file_is_refused() raises:
    var dir = _fresh_dir(String("_rename_taken"))
    assert_true(write_file(dir + String("/a.txt"), String("a\n")))
    assert_true(write_file(dir + String("/b.txt"), String("b\n")))
    var d = Desktop()
    d._file_op_path = dir + String("/a.txt")
    d._do_rename_file(String("b.txt"))
    assert_equal(read_file(dir + String("/a.txt")), String("a\n"))
    assert_equal(read_file(dir + String("/b.txt")), String("b\n"))


def test_renaming_an_open_file_moves_its_editor_along() raises:
    # The tree's path and the editor's can differ (/tmp is /private/tmp):
    # an editor left on the old path would write the old file back on save
    var dir = _fresh_dir(String("_rename_open"))
    var path = dir + String("/a.txt")
    assert_true(write_file(path, String("a\n")))
    var d = Desktop()
    d.open_file(path, Rect(0, 0, 80, 30))
    d._file_op_path = path
    d._do_rename_file(String("b.txt"))
    var ed_path = d.windows.windows[d._focused_editor_idx()].editor.file_path
    assert_true(ed_path.endswith(String("/b.txt")))
    assert_false(stat_file(path).ok)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
