"""The terminal frontend's SIGHUP / SIGTERM: recorded for the main loop to
quit as Quit does (saving, and keeping what's unsaved with the drafts),
instead of ending the process on the spot. A suite of its own: deferring
changes the handlers for the whole process."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal


def _raise(sig: Int32):
    _ = external_call["kill", Int32](external_call["getpid", Int32](), sig)


def test_deferred_quit_signals_are_recorded_not_fatal() raises:
    assert_equal(external_call["tk_quit_signal", Int32](), 0)
    external_call["tk_defer_quit_signals", NoneType]()
    _raise(15)  # SIGTERM
    # still running, and the loop can see why it should quit
    assert_equal(external_call["tk_quit_signal", Int32](), 15)
    _raise(1)  # SIGHUP: the terminal closed
    assert_equal(external_call["tk_quit_signal", Int32](), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
