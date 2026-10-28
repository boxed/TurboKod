"""``Editor.save``: what reaches the disk, and never over a change the
editor hasn't seen."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true
from turbokod.editor import EXT_CHANGE_RELOADED, EXT_CHANGE_UNREADABLE, Editor
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


def test_a_same_size_outside_change_on_a_whole_second_clock_is_merged() raises:
    # filesystems with one-second timestamps: the nanoseconds never differ
    var path = _temp_path(String("_save_race_seconds.txt"))
    assert_true(write_file(path, "one\nmid\ntwo\n"))
    _touch(path, "2020-01-01T00:00:00")
    var ed = Editor.from_file(path)
    assert_true(write_file(path, "one\nmid\nTWO\n"))
    _touch(path, "2020-01-01T00:00:03")
    ed.buffer.insert(0, 3, "!")
    ed.dirty = True
    assert_true(ed.save())
    assert_equal(read_file(path), "one!\nmid\nTWO\n")


def test_new_files_are_not_executable() raises:
    var path = _temp_path(String("_save_new_mode.txt"))
    _ = capture_command(["rm", "-f", path])
    assert_true(write_file(path, "x\n"))
    var mode = String(capture_command(["stat", "-f", "%Lp", path]).stdout.strip())
    if mode.byte_length() == 0:  # GNU stat
        mode = String(capture_command(["stat", "-c", "%a", path]).stdout.strip())
    assert_equal(mode.byte_length(), 3)
    for digit in mode.codepoint_slices():
        assert_true(digit in "0246", mode)  # no execute bit, whatever the umask


def test_a_write_the_disk_cant_take_fails_and_keeps_the_old_file() raises:
    # a file size limit makes the write come up short, as a full disk does
    var path = _temp_path(String("_save_full.txt"))
    assert_true(write_file(path, "old\n"))
    var big = String("")
    for _ in range(500):
        big += "0123456789"
    comptime RLIMIT_FSIZE = Int32(1)
    comptime SIGXFSZ = Int32(25)
    var previous = external_call["signal", Int](SIGXFSZ, Int(1))  # SIG_IGN
    var limits = List[UInt64](length=2, fill=0)
    _ = external_call["getrlimit", Int32](RLIMIT_FSIZE, limits.unsafe_ptr())
    var small = List[UInt64](length=2, fill=0)
    small[0] = 1000
    small[1] = limits[1]
    _ = external_call["setrlimit", Int32](RLIMIT_FSIZE, small.unsafe_ptr())
    var ok = write_file(path, big)
    _ = external_call["setrlimit", Int32](RLIMIT_FSIZE, limits.unsafe_ptr())
    _ = external_call["signal", Int](SIGXFSZ, previous)
    assert_false(ok)
    assert_equal(read_file(path), "old\n")
    assert_equal(capture_command(["ls", path + ".tk-tmp"]).status != 0, True)


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


def _chmod(path: String, mode: Int):
    _ = external_call["chmod", Int32]((path + "\0").unsafe_ptr(), UInt16(mode))


def test_a_file_that_cant_be_read_isnt_opened_as_empty() raises:
    # saving the empty buffer would replace what's in it
    var path = _temp_path(String("_save_unreadable.txt"))
    assert_true(write_file(path, "secret\n"))
    _chmod(path, 0)
    with assert_raises():
        _ = Editor.from_file(path)
    _chmod(path, 0o644)
    assert_equal(read_file(path), "secret\n")


def test_a_file_that_isnt_there_yet_opens_empty() raises:
    var path = _temp_path(String("_save_new_file.txt"))
    _ = capture_command(["rm", "-f", path])
    var ed = Editor.from_file(path)
    assert_equal(ed.buffer.line_count(), 1)
    assert_equal(ed.buffer.line(0), "")
    ed.buffer.insert(0, 0, "new")
    ed.dirty = True
    assert_true(ed.save())
    assert_equal(read_file(path), "new")


def test_a_change_that_cant_be_read_is_neither_loaded_nor_saved_over() raises:
    var path = _temp_path(String("_save_change_unreadable.txt"))
    assert_true(write_file(path, "a\nm\nz\n"))
    var ed = Editor.from_file(path)
    assert_true(write_file(path, "a\nm\nz\nb\n"))
    _chmod(path, 0)
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_UNREADABLE)
    assert_equal(ed.buffer.line(0), "a")
    assert_false(ed.dirty)
    ed.buffer.insert(0, 0, "x")
    ed.dirty = True
    assert_false(ed.save())
    assert_true(ed.dirty)
    _chmod(path, 0o644)
    assert_equal(read_file(path), "a\nm\nz\nb\n")
    # once it can be read, the change is merged in
    assert_true(ed.save())
    assert_equal(read_file(path), "xa\nm\nz\nb\n")


def test_a_clean_buffer_reloads_once_the_change_can_be_read() raises:
    var path = _temp_path(String("_reload_unreadable.txt"))
    assert_true(write_file(path, "a\n"))
    var ed = Editor.from_file(path)
    assert_true(write_file(path, "a\nb\n"))
    _chmod(path, 0)
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_UNREADABLE)
    _chmod(path, 0o644)
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_RELOADED)
    assert_equal(ed.buffer.line(1), "b")


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
