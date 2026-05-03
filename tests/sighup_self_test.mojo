"""Driver for the sighup integration check.

Spawns a long-running ``sleep`` child via ``LspProcess.spawn`` (so it
gets registered in the kill-on-parent-death registry), prints the
child's PID, then sleeps so the test driver shell script can SIGHUP
us. The signal handler installed by ``process_shim.c`` should fire,
SIGTERM the sleep child, and re-raise SIGHUP to terminate us.

Run via ``tests/sighup_integration.sh`` — that script verifies the
sleep PID is gone after we exit.
"""

from std.collections.list import List

from turbokod.lsp import LspProcess


fn main() raises:
    var argv = List[String]()
    argv.append(String("sleep"))
    argv.append(String("60"))
    var proc = LspProcess.spawn(argv)
    if proc.pid <= 0:
        raise Error("spawn failed")
    print(proc.pid)
    # Flush stdout so the driver sees the PID before SIGHUP arrives.
    # ``print`` already line-buffers via Mojo's File path — the
    # newline above is the flush trigger.

    # Sleep long enough for the driver to send SIGHUP. We call ``sleep``
    # from the C library via external_call to avoid pulling in a Mojo
    # time module just for this — and ``sleep(N)`` may return early on
    # signal delivery, which is exactly what we want.
    from std.ffi import external_call
    _ = external_call["sleep", Int32](Int32(10))
    print("driver did not SIGHUP us in time")
