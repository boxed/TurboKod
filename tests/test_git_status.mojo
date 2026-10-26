"""The status bar's async git summary (``git_status_poll``).

Separate from ``test_git.mojo``, which is already past the size where a
suite stays quick to compile.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from turbokod.file_io import join_path, write_file
from turbokod.git_status_poll import (
    GitStatusParser, GitStatusPoller, GitStatusSummary,
)
from turbokod.posix import sleep_ms
from turbokod.string_utils import string_list
from support import _ensure_dir, _rm_rf, _run_git, _temp_path, setup_test_env


def _parse(*lines: String) -> GitStatusSummary:
    var p = GitStatusParser()
    for line in lines:
        p.feed(String(line))
    return p.summary()


def test_status_parser_clean_branch_with_upstream() raises:
    var s = _parse(
        String("# branch.oid 0123456789abcdef0123456789abcdef01234567"),
        String("# branch.head main"),
        String("# branch.upstream origin/main"),
        String("# branch.ab +3 -1"),
    )
    assert_false(s.dirty)
    assert_equal(s.unpushed, 3)
    assert_equal(s.branch, String("main"))


def test_status_parser_dirty_no_upstream() raises:
    var s = _parse(
        String("# branch.oid 0123456789abcdef0123456789abcdef01234567"),
        String("# branch.head feature"),
        String("? new.txt"),
    )
    assert_true(s.dirty)
    assert_equal(s.unpushed, 0)
    assert_equal(s.branch, String("feature"))


def test_status_parser_detached_shows_short_sha() raises:
    var s = _parse(
        String("# branch.oid 0123456789abcdef0123456789abcdef01234567"),
        String("# branch.head (detached)"),
    )
    assert_equal(s.branch, String("(0123456)"))


def test_status_parser_no_output_is_empty() raises:
    # Not a repo: git exits non-zero with nothing on stdout.
    var s = GitStatusParser().summary()
    assert_false(s.dirty)
    assert_equal(s.unpushed, 0)
    assert_equal(s.branch, String(""))


def _poll(mut p: GitStatusPoller, root: String) raises -> GitStatusSummary:
    assert_true(p.start(root))
    for _ in range(5000):
        var got = p.tick()
        if got:
            assert_false(p.is_active())
            return got.value()
        sleep_ms(1)
    raise Error("git status poll never finished")


def test_status_poller_reports_branch_and_dirty() raises:
    var dir = _temp_path(String("_git_status_poll"))
    _rm_rf(dir)
    _ensure_dir(dir)
    if _run_git(dir, string_list(
        String("init"), String("-q"), String("-b"), String("trunk"),
    )) != 0:
        _rm_rf(dir)   # no git on PATH
        return
    _ = _run_git(dir, string_list(
        String("config"), String("user.email"), String("t@example.com"),
    ))
    _ = _run_git(dir, string_list(String("config"), String("user.name"), String("T")))
    assert_true(write_file(join_path(dir, String("a.txt")), String("a\n")))
    _ = _run_git(dir, string_list(String("add"), String("a.txt")))
    _ = _run_git(dir, string_list(
        String("commit"), String("-q"), String("-m"), String("init"),
    ))
    var p = GitStatusPoller()
    var clean = _poll(p, dir)
    assert_false(clean.dirty)
    assert_equal(clean.branch, String("trunk"))
    assert_equal(clean.unpushed, 0)
    assert_true(write_file(join_path(dir, String("b.txt")), String("b\n")))
    var dirty = _poll(p, dir)
    assert_true(dirty.dirty)
    assert_equal(dirty.branch, String("trunk"))
    _rm_rf(dir)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
