"""End-to-end smoke test for the PTY-backed terminal pane.

Spawns ``/bin/echo`` (or ``printf`` for ANSI sequence variants) under
a controlling pty, drains the master fd, feeds the bytes into the
emulator, and checks that the resulting grid matches what a real
terminal would show.

This is the test that catches "everything compiles but nothing works"
regressions — the integration between ``tk_pty_spawn``, the pty's
non-blocking reads, the ``Vt`` parser, and the cell grid. If any
link breaks (fork failure, lost output, parser confusion) you see
mismatched cells here.

Skipped on platforms where ``forkpty``-style spawn isn't available —
but that's anywhere POSIX, which is the platform set we target.

Run with::

    ./run.sh tests/test_pty_smoke.mojo
"""

from std.collections.list import List
from std.testing import assert_equal, assert_true

from turbokod.posix import (
    alloc_zero_buffer, getenv_value, poll_stdin, read_into, setenv_value,
    waitpid_nohang,
)
from turbokod.pty import PtyProcess
from turbokod.terminal_pane import TerminalPane
from turbokod.vt import Vt


def _drain_until_exit(mut pty: PtyProcess, mut vt: Vt, deadline_ms: Int):
    """Pump bytes off ``pty.master_fd`` into ``vt`` until the child
    exits, with a hard deadline. We poll with a short timeout so the
    loop doesn't spin and so a missing EOF (rare but possible if the
    pty close racy) eventually trips the deadline rather than hanging
    the test."""
    var scratch = alloc_zero_buffer(4096)
    var waited = 0
    while waited < deadline_ms:
        var got_data = poll_stdin(pty.master_fd, Int32(20))
        if got_data:
            var n = read_into(pty.master_fd, scratch, 4096)
            if n > 0:
                var span = Span[UInt8, origin_of(scratch)](
                    unsafe_ptr=scratch.unsafe_ptr(), length=n,
                )
                vt.feed(span)
                continue
            # n == 0: EOF on the slave side, child closed its end.
        # No data right now — check whether the child has exited.
        var pair = waitpid_nohang(pty.pid)
        if Int(pair[0]) == Int(pty.pid):
            # Drain one more time in case bytes landed between read
            # and waitpid (the pty's kernel buffer survives the child).
            while poll_stdin(pty.master_fd, Int32(0)):
                var n2 = read_into(pty.master_fd, scratch, 4096)
                if n2 <= 0: break
                var span2 = Span[UInt8, origin_of(scratch)](
                    unsafe_ptr=scratch.unsafe_ptr(), length=n2,
                )
                vt.feed(span2)
            return
        waited += 20


def test_pty_echo_writes_into_grid() raises:
    # ``/bin/echo hi`` — the most boring possible child. After it
    # exits, the grid's first row should contain "hi".
    var argv = List[String]()
    argv.append(String("/bin/echo"))
    argv.append(String("hi"))
    var pty = PtyProcess.spawn(argv, cols=40, rows=10)
    assert_true(pty.pid > 0)
    assert_true(pty.master_fd >= 0)
    var vt = Vt(40, 10)
    _drain_until_exit(pty, vt, 2000)
    pty.terminate()
    assert_equal(vt.cell_at(0, 0).glyph, String("h"))
    assert_equal(vt.cell_at(0, 1).glyph, String("i"))


def test_pty_printf_ansi_color_lands_as_red_fg() raises:
    # ``printf '\\e[31mR\\e[0m'`` — exercises the SGR parser at the
    # other end. After draining, cell (0,0) should hold ``R`` with
    # red foreground.
    var argv = List[String]()
    argv.append(String("/usr/bin/printf"))
    argv.append(String("\x1b[31mR\x1b[0m"))
    var pty = PtyProcess.spawn(argv, cols=10, rows=4)
    var vt = Vt(10, 4)
    _drain_until_exit(pty, vt, 2000)
    pty.terminate()
    assert_equal(vt.cell_at(0, 0).glyph, String("R"))
    # RED is palette index 1.
    assert_equal(Int(vt.cell_at(0, 0).attr.fg), Int(UInt8(1)))


def test_pty_child_runs_in_requested_cwd() raises:
    # ``/bin/pwd`` prints its working directory. Spawning it with
    # ``cwd="/tmp"`` should produce ``/tmp`` (a path that exists on
    # every POSIX system). Regression for "new terminal panes should
    # start in the project root, not in the editor's launch dir."
    var argv = List[String]()
    argv.append(String("/bin/pwd"))
    var pty = PtyProcess.spawn(argv, cwd=String("/tmp"), cols=40, rows=4)
    var vt = Vt(40, 4)
    _drain_until_exit(pty, vt, 2000)
    pty.terminate()
    # /tmp may resolve to /private/tmp on macOS via the per-user
    # /tmp → /private/tmp symlink, so accept either prefix.
    var got = vt.cell_at(0, 0).glyph + vt.cell_at(0, 1).glyph \
        + vt.cell_at(0, 2).glyph + vt.cell_at(0, 3).glyph
    var ok = got == String("/tmp") or got == String("/pri")
    assert_true(ok)


def test_pty_isatty_detected_by_child() raises:
    # The whole point of switching to a pty: ``test -t 0`` (which
    # ``[ -t 0 ]`` in /bin/sh reduces to) must exit 0 when stdin is
    # a tty. With pipes it exited 1, which is what caused ``claude``
    # to fall into ``--print`` mode and time out. We run it under
    # /bin/sh so we get a real exit code we can read back via the
    # output (sh's last-status echo) rather than waitpid (the child's
    # exit is the sh exit, not the test exit).
    var argv = List[String]()
    argv.append(String("/bin/sh"))
    argv.append(String("-c"))
    argv.append(String("[ -t 0 ] && echo TTY || echo PIPE"))
    var pty = PtyProcess.spawn(argv, cols=40, rows=4)
    var vt = Vt(40, 4)
    _drain_until_exit(pty, vt, 2000)
    pty.terminate()
    # First row should be "TTY". A failed isatty would have printed
    # "PIPE" — the prior pipe-backed implementation hit that path.
    assert_equal(vt.cell_at(0, 0).glyph, String("T"))
    assert_equal(vt.cell_at(0, 1).glyph, String("T"))
    assert_equal(vt.cell_at(0, 2).glyph, String("Y"))


def test_pty_terminate_reaps_the_child() raises:
    """``terminate`` must actually collect the child, not just signal it.

    It used to issue a single ``waitpid_nohang`` microseconds after the
    ``kill`` — long before the child had been scheduled to die, so it
    always came back empty — and then ``untrack_child`` anyway, which
    took the pid away from the shim's exit reaper too. Every terminal-pane
    close and every test run left a zombie for the life of the process.

    A still-reapable pid after ``terminate`` is exactly that zombie, so
    the second ``waitpid`` below must find nothing.
    """
    var pids = List[Int]()
    for _ in range(3):
        var argv = List[String]()
        argv.append(String("/bin/sh"))
        argv.append(String("-c"))
        argv.append(String("sleep 30"))
        var p = PtyProcess.spawn(argv)
        assert_true(p.pid > 0)
        pids.append(Int(p.pid))
        p.terminate()
        # The master fd must come back too.
        assert_equal(Int(p.master_fd), -1)
    for i in range(len(pids)):
        var pair = waitpid_nohang(Int32(pids[i]))
        assert_true(Int(pair[0]) != pids[i])


def test_pty_terminate_after_the_child_exited_on_its_own() raises:
    """A child that exited by itself is still reclaimable.

    ``terminate`` used to open with ``if not self.alive: return``, and
    ``alive`` is cleared from the *outside* — a pane's drain loop latches
    it False the moment its read reports EOF. So a shell the user ended
    with ``exit`` (the normal way to end one) turned every later
    ``terminate`` into an early return, and the master fd, the zombie and
    the shim's tracked-pid entry all survived to process exit. One leaked
    descriptor per shell.

    The guards are now per-resource (``pid > 0``, ``master_fd >= 0``), so
    this sequence — drain to EOF, latch, terminate — reclaims both.
    """
    var argv = List[String]()
    argv.append(String("/bin/sh"))
    argv.append(String("-c"))
    argv.append(String("echo bye"))
    var p = PtyProcess.spawn(argv)
    var pid = p.pid
    assert_true(pid > 0)
    var fd = Int(p.master_fd)
    assert_true(fd >= 0)
    # Exactly what a pane's tick does: read until EOF, then latch ``alive``.
    var scratch = alloc_zero_buffer(4096)
    var spins = 0
    while p.alive and spins < 5000:
        spins += 1
        if not poll_stdin(p.master_fd, Int32(20)):
            continue
        var n = read_into(p.master_fd, scratch, 4096)
        if n <= 0:
            p.alive = False
    assert_equal(p.alive, False)
    # The drain loop itself doesn't (and shouldn't) close anything.
    assert_equal(Int(p.master_fd), fd)
    p.terminate()
    assert_equal(Int(p.master_fd), -1)
    assert_true(Int(waitpid_nohang(pid)[0]) != Int(pid))


def test_terminal_pane_reclaims_the_pty_when_the_shell_exits() raises:
    """The pane hands the pty back when its shell exits on its own.

    The pane-level half of the same bug: ``tick`` latched ``alive`` False
    on EOF and stopped there, leaving the fd for a ``close`` that could no
    longer act on it — and for an ``ensure_started`` that would overwrite
    the whole ``PtyProcess`` and make it unreachable.
    """
    var saved_shell = getenv_value(String("SHELL"))
    _ = setenv_value(String("SHELL"), String("/bin/sh"))
    var pane = TerminalPane()
    pane.startup_command = String("exit 0")
    pane.ensure_started()
    var pid = pane.pty.pid
    assert_true(pid > 0)
    assert_true(pane.pty.master_fd >= 0)
    var spins = 0
    while pane.pty.alive and spins < 5000:
        pane.tick()
        spins += 1
    assert_equal(pane.pty.alive, False)
    # Reclaimed by ``tick`` itself, before anyone closes the pane.
    assert_equal(Int(pane.pty.master_fd), -1)
    assert_true(Int(waitpid_nohang(pid)[0]) != Int(pid))
    # And the pane still works afterwards: a fresh shell on the next start.
    pane.close()
    if len(saved_shell.as_bytes()) > 0:
        _ = setenv_value(String("SHELL"), saved_shell)


def main() raises:
    test_pty_echo_writes_into_grid()
    test_pty_printf_ansi_color_lands_as_red_fg()
    test_pty_child_runs_in_requested_cwd()
    test_pty_isatty_detected_by_child()
    test_pty_terminate_reaps_the_child()
    test_pty_terminate_after_the_child_exited_on_its_own()
    test_terminal_pane_reclaims_the_pty_when_the_shell_exits()
    print("all pty smoke tests passed")
