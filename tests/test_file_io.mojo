"""``file_io``: saving and deleting must never touch more, or less, than
the file the user means."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.file_io import delete_tree, load_json_object, read_file, stat_file, write_file
from turbokod.lsp import capture_command
from turbokod.posix import getcwd_path


def _sh(script: String) raises -> String:
    var argv = List[String]()
    argv.append(String("sh"))
    argv.append(String("-c"))
    argv.append(script)
    return capture_command(argv).stdout


def _scratch(name: String) raises -> String:
    """A fresh directory under ``.build`` for this process."""
    var pid = external_call["getpid", Int32]()
    var dir = getcwd_path() + "/.build/file_io_test_" + String(Int(pid)) + "/" + name
    _ = _sh("rm -rf '" + dir + "' && mkdir -p '" + dir + "'")
    return dir


def test_deleting_a_directory_leaves_what_its_symlinks_point_to() raises:
    var dir = _scratch("delete_links")
    _ = _sh(
        "cd '" + dir + "' && mkdir -p outside tree/sub && echo keep > outside/precious.txt"
        + " && echo x > tree/sub/file.txt && ln -s ../outside tree/link"
    )
    assert_true(delete_tree(dir + "/tree", True))
    assert_false(stat_file(dir + "/tree").ok)
    assert_equal(read_file(dir + "/outside/precious.txt"), "keep\n")


def test_deleting_a_symlink_to_a_directory_removes_only_the_link() raises:
    var dir = _scratch("delete_link_itself")
    _ = _sh("cd '" + dir + "' && mkdir outside && echo keep > outside/precious.txt && ln -s outside link")
    # the file tree lists a symlink to a directory as a directory
    assert_true(delete_tree(dir + "/link", True))
    assert_equal(_sh("cd '" + dir + "' && ls"), "outside\n")
    assert_equal(read_file(dir + "/outside/precious.txt"), "keep\n")


def test_saving_keeps_the_file_mode() raises:
    var dir = _scratch("modes")
    _ = _sh("cd '" + dir + "' && echo old > run.sh && chmod 755 run.sh && echo old > secret && chmod 600 secret")
    assert_true(write_file(dir + "/run.sh", "new\n"))
    assert_true(write_file(dir + "/secret", "new\n"))
    assert_equal(_sh("cd '" + dir + "' && stat -f '%Lp' run.sh secret 2>/dev/null || stat -c '%a' run.sh secret"), "755\n600\n")
    assert_equal(read_file(dir + "/run.sh"), "new\n")


def test_saving_through_a_symlink_writes_its_target() raises:
    var dir = _scratch("save_link")
    _ = _sh("cd '" + dir + "' && echo old > real.txt && ln -s real.txt link.txt")
    assert_true(write_file(dir + "/link.txt", "new\n"))
    assert_equal(_sh("cd '" + dir + "' && test -L link.txt && echo still a link"), "still a link\n")
    assert_equal(read_file(dir + "/real.txt"), "new\n")


def test_saving_a_new_file() raises:
    var dir = _scratch("new_file")
    assert_true(write_file(dir + "/fresh.txt", "hello\n"))
    assert_equal(read_file(dir + "/fresh.txt"), "hello\n")
    assert_equal(_sh("cd '" + dir + "' && ls"), "fresh.txt\n")


def test_a_new_file_is_not_executable() raises:
    var dir = _scratch("new_mode")
    assert_true(write_file(dir + "/fresh.txt", "x\n"))
    assert_equal(_sh("cd '" + dir + "' && test -x fresh.txt || echo not executable"), "not executable\n")


def test_saving_through_a_dangling_symlink_still_saves() raises:
    var dir = _scratch("dangling")
    _ = _sh("cd '" + dir + "' && ln -s missing.txt link.txt")
    assert_true(write_file(dir + "/link.txt", "saved\n"))
    assert_equal(read_file(dir + "/link.txt"), "saved\n")


def test_a_directory_that_cant_be_fully_deleted_reports_failure() raises:
    var dir = _scratch("locked")
    _ = _sh("cd '" + dir + "' && mkdir -p tree/locked && echo x > tree/locked/f && chmod 555 tree/locked")
    assert_false(delete_tree(dir + "/tree", True))
    _ = _sh("chmod 755 '" + dir + "/tree/locked'")
    assert_equal(read_file(dir + "/tree/locked/f"), "x\n")


def test_an_unreadable_store_file_is_kept_for_recovery() raises:
    # the stores save over what they load: a file they can't read would be
    # overwritten with nothing
    var dir = _scratch("corrupt")
    assert_true(write_file(dir + "/drafts.json", "{\"drafts\": [{\"content\": \"unsaved wo"))
    assert_false(Bool(load_json_object(dir + "/drafts.json")))
    assert_false(stat_file(dir + "/drafts.json").ok)
    assert_equal(read_file(dir + "/drafts.json.corrupt"), "{\"drafts\": [{\"content\": \"unsaved wo")
    # and a second one doesn't replace the first
    assert_true(write_file(dir + "/drafts.json", "[]"))
    assert_false(Bool(load_json_object(dir + "/drafts.json")))
    assert_equal(read_file(dir + "/drafts.json.corrupt.1"), "[]")
    assert_true(write_file(dir + "/drafts.json", "3"))
    assert_false(Bool(load_json_object(dir + "/drafts.json")))
    assert_equal(read_file(dir + "/drafts.json.corrupt.2"), "3")


def test_a_missing_store_file_is_nothing_saved_yet() raises:
    var dir = _scratch("missing")
    assert_false(Bool(load_json_object(dir + "/drafts.json")))
    assert_equal(_sh("cd '" + dir + "' && ls"), "")


def test_a_store_file_reads_back() raises:
    var dir = _scratch("good")
    assert_true(write_file(dir + "/s.json", "{\"a\": 1}"))
    assert_true(Bool(load_json_object(dir + "/s.json")))
    assert_true(stat_file(dir + "/s.json").ok)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
