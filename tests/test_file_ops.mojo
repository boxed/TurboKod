"""File operations from the tab and file-tree menus."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal
from turbokod.desktop import Desktop
from turbokod.file_io import read_file, write_file
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


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
