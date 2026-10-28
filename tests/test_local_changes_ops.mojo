"""The git view's asynchronous operations: the child it spawns for a pull /
push / commit has to be reaped however the view is left, including closing
it while the child is still running."""

from std.testing import TestSuite, assert_false, assert_true
from turbokod.local_changes import LocalChanges, _GITOP_PULL
from turbokod.posix import sleep_ms
from turbokod.string_utils import string_list
from support import setup_test_env


def test_closing_mid_op_still_reaps_the_git_child() raises:
    """``close`` used to reset the in-flight op, after which ``tick``
    returned early forever and the child was never reaped — closing the
    view on a file open while a push ran stranded the process."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    lc._start_git_op(
        _GITOP_PULL, String("slow op"),
        string_list(String("sh"), String("-c"), String("sleep 0.2")),
    )
    assert_true(lc.git_runner.is_active())
    lc.close()
    for _ in range(300):
        lc.tick()
        if not lc.git_runner.is_active():
            break
        sleep_ms(10)
    assert_false(lc.git_runner.is_active())
    lc.release()


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
