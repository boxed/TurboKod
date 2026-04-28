"""Standalone DAP smoke test — drives debugpy from start to a stopped
breakpoint without any UI in the way.

Run with::

    ./run.sh tests/dap_smoke.mojo

The script writes a small ``foo()`` program to ``/tmp/dap_smoke_test.py``,
sets a breakpoint at line 2, fires up debugpy via the same registry the
editor uses, and ticks the manager until either:

* the program reaches the breakpoint and we successfully fetch its
  locals via the stopped → stack → scopes → variables chain, or
* a 30-second deadline elapses with no progress, or
* the manager latches FAILED.

Output is plain ``print()``s plus the streaming trace at
``/tmp/mojovision-dap.log`` (DapManager's existing instrument). With
the UI removed there's no rendering or input loop to mask issues —
anything we observe is purely the protocol layer's behavior.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.sys import argv

from mojovision.canvas import Canvas
from mojovision.dap_dispatch import (
    DapManager, DapStackFrame, DapVariable,
)
from mojovision.debug_pane import DebugPane
from mojovision.debugger_config import (
    DebuggerSpec, built_in_debuggers, find_debugger_for_language,
)
from mojovision.desktop import Desktop, DEBUG_START_OR_CONTINUE
from mojovision.file_io import write_file
from mojovision.geometry import Rect
from mojovision.posix import monotonic_ms


fn _sleep_ms(ms: Int):
    """Sleep ``ms`` milliseconds via ``usleep``. Cheap to call from a
    polling loop and avoids dragging in Python interop just for a
    sleep call."""
    _ = external_call["usleep", Int32](Int32(ms * 1000))


fn main() raises:
    # 1. Pick the test program. If the user passed one on the
    # command line (``./run.sh tests/dap_smoke.mojo path/to/file.py``)
    # we use that; otherwise we synthesize ``/tmp/dap_smoke_test.py``.
    # The synthesized program has its breakpoint on line 2 — when
    # the user supplies their own file we still set the breakpoint
    # at line 2, so make sure that's a valid statement in their code.
    var args = argv()
    var test_path = String("/tmp/dap_smoke_test.py")
    if len(args) > 1:
        test_path = String(args[1])
        print("using user-supplied", test_path)
    else:
        var src = String("def foo(x):\n")
        src = src + String("    return x + 1\n")
        src = src + String("\n")
        src = src + String("foo(41)\n")
        src = src + String("print('done')\n")
        if not write_file(test_path, src):
            print("could not write", test_path)
            return
        print("wrote", test_path)

    # 2. Pick the python debugger spec from the built-in registry.
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    if idx < 0:
        print("no python debugger registered")
        return
    print("debugger:", debs[idx].name)

    # 3. Set a breakpoint at line 2 (0-based: 1) BEFORE start so the
    # configure step pushes it to debugpy on the initial handshake.
    var mgr = DapManager()
    mgr.toggle_breakpoint(test_path, 1)

    # 4. Spawn the adapter.
    mgr.start(
        debs[idx], test_path, String("/tmp"), List[String](),
    )
    if mgr.is_failed():
        print("start failed:", mgr.failure_reason)
        return
    print("session started, argv:")
    for k in range(len(mgr.spawn_argv)):
        print(" ", mgr.spawn_argv[k])

    # 5. Tick loop. Drain events / responses, advance the chain, log
    # everything. Bails on a 30 s deadline OR on terminal states.
    var deadline = monotonic_ms() + 30000
    var seen_stack = False
    var seen_locals = False
    while monotonic_ms() < deadline:
        _sleep_ms(50)
        mgr.tick()

        # Surface stderr at every tick so a debugpy crash becomes
        # immediately visible.
        var err = mgr.drain_stderr()
        if len(err.as_bytes()) > 0:
            print("STDERR:", err)

        # Output events from the debuggee.
        var outs = mgr.take_outputs()
        for k in range(len(outs)):
            print("OUTPUT[", outs[k].category, "]:", outs[k].text)

        # Stopped — first time, request stack and scopes.
        var stopped = mgr.take_stopped()
        if stopped:
            print(
                "STOPPED reason=", stopped.value().reason,
                "thread=", stopped.value().thread_id,
            )
            _ = mgr.request_stack_trace(stopped.value().thread_id, 64)

        if mgr.has_stack():
            var frames = mgr.take_stack()
            print("STACK", len(frames), "frames:")
            for k in range(len(frames)):
                print(
                    " ", frames[k].name, frames[k].path,
                    "line=", frames[k].line,
                )
            seen_stack = True
            if len(frames) > 0:
                _ = mgr.request_scopes(frames[0].id)

        if mgr.has_scopes():
            var scopes = mgr.take_scopes()
            print("SCOPES", len(scopes), "scopes:")
            for k in range(len(scopes)):
                print(
                    " ", scopes[k].name,
                    "ref=", scopes[k].variables_reference,
                    "expensive=", scopes[k].expensive,
                )
            # Pick the first non-expensive scope, request variables.
            var pick = -1
            for k in range(len(scopes)):
                if not scopes[k].expensive:
                    pick = k
                    break
            if pick >= 0:
                _ = mgr.request_variables(
                    scopes[pick].variables_reference,
                )

        if mgr.has_variables():
            var vars = mgr.take_variables()
            print("VARIABLES", len(vars), "vars:")
            for k in range(len(vars)):
                print(
                    " ", vars[k].name, "=", vars[k].value,
                    "(", vars[k].type_name, ")",
                )
            seen_locals = True
            # Now exercise the same UI calls Desktop.dap_tick would
            # make. The example app's "saw stack briefly then quit"
            # symptom points at a crash in one of these — hit them
            # here, with no UI loop, to isolate.
            print("[ui-test] rebuild_inspect with stack + locals…")
            var pane = DebugPane()
            var stack_copy = List[DapStackFrame]()
            # We don't have the cached stack in this scope — request
            # again synchronously. (Desktop normally caches it.)
            _ = mgr.request_stack_trace(1, 64)
            _sleep_ms(120)
            mgr.tick()
            if mgr.has_stack():
                stack_copy = mgr.take_stack()
            pane.rebuild_inspect(
                stack_copy^,
                String("Locals"),
                vars.copy(),
                String("Watches"),
                List[String](),
                0,
            )
            print("[ui-test] rebuild_inspect OK, rows=", len(pane.rows))
            print("[ui-test] paint into a 80x14 canvas…")
            var canvas = Canvas(80, 14)
            pane.visible = True
            pane.paint(canvas, Rect(0, 0, 80, 14))
            print("[ui-test] paint OK")
            # Try expanding the first non-leaf variable.
            var expand_target_ref = -1
            var expand_target_row = -1
            for k in range(len(pane.rows)):
                if pane.rows[k].kind == UInt8(2) \
                        and pane.rows[k].ref_id != 0:
                    expand_target_ref = pane.rows[k].ref_id
                    expand_target_row = k
                    break
            if expand_target_ref > 0:
                print(
                    "[ui-test] expanding row", expand_target_row,
                    "ref=", expand_target_ref,
                )
                _ = mgr.request_variables(expand_target_ref)
                _sleep_ms(120)
                mgr.tick()
                if mgr.has_variables():
                    var children = mgr.take_variables()
                    pane.splice_children_at(
                        expand_target_row, 1, children^,
                    )
                    print(
                        "[ui-test] splice OK, rows=", len(pane.rows),
                    )
                    pane.paint(canvas, Rect(0, 0, 80, 14))
                    print("[ui-test] paint after splice OK")
            else:
                print("[ui-test] no expandable variable in locals")
            print("SUCCESS — full chain + UI calls completed")
            break

        if mgr.is_failed():
            print("FAILED:", mgr.failure_reason)
            break
        if mgr.is_terminated():
            print("TERMINATED")
            break

    if not seen_locals:
        print(
            "TIMEOUT — seen_stack=", seen_stack,
            "is_failed=", mgr.is_failed(),
            "is_terminated=", mgr.is_terminated(),
        )

    mgr.shutdown()
    print("done — see /tmp/mojovision-dap.log for the wire trace")
    print("")
    print("=" * 60)
    print("Phase 2: drive Desktop.dap_tick end-to-end (UI path)")
    print("=" * 60)
    _smoke_via_desktop(test_path)


fn _smoke_via_desktop(test_path: String) raises:
    """Reproduce what the example app's main loop does — open the
    file in a Desktop, fire the F5 action to start debugpy, then tick
    until the stopped event has been fully processed (or we time
    out). No terminal / no Application; we just call paint into a
    throwaway canvas so any rendering crash bubbles up here.
    """
    var desktop = Desktop()
    var screen = Rect(0, 0, 100, 30)
    var canvas = Canvas(100, 30)
    desktop.open_file(test_path, screen)
    print("[desktop] opened", test_path)
    # Set the breakpoint via the manager directly — avoids needing
    # a full key-event simulation for F9.
    desktop.dap.toggle_breakpoint(test_path, 1)
    print("[desktop] breakpoint set at line 2 (0-based 1)")
    # Kick off the F5 action.
    var action = desktop.dispatch_action(DEBUG_START_OR_CONTINUE, screen)
    if action:
        print("[desktop] F5 returned action:", action.value())
    print("[desktop] starting tick loop")
    var deadline = monotonic_ms() + 30000
    var iters = 0
    while monotonic_ms() < deadline:
        _sleep_ms(50)
        iters += 1
        # Mimic what the host's main loop does each frame.
        desktop.dap_tick(screen)
        # Paint everything — if rebuild_inspect / pane.paint crashes
        # in the live app, it'll crash here too.
        desktop.paint(canvas, screen)
        # Surface state every 10 ticks.
        if iters % 10 == 0:
            print(
                "[desktop] iter=", iters,
                "state=", desktop.dap.status_summary(),
                "rows=", len(desktop.debug_pane.rows),
            )
        if desktop.dap.is_stopped():
            # Wait a couple more ticks so the stack/scopes/vars
            # cascade can complete, then bail.
            _sleep_ms(300)
            for _ in range(6):
                desktop.dap_tick(screen)
                desktop.paint(canvas, screen)
                _sleep_ms(50)
            print(
                "[desktop] stopped — final pane row count:",
                len(desktop.debug_pane.rows),
            )
            for k in range(len(desktop.debug_pane.rows)):
                var r = desktop.debug_pane.rows[k]
                print("  row", k, "kind=", r.kind, "text=", r.text)
            break
        if desktop.dap.is_failed():
            print("[desktop] FAILED:", desktop.dap.failure_reason)
            break
        if desktop.dap.is_terminated():
            print("[desktop] TERMINATED")
            break
    desktop.dap.shutdown()
    print("[desktop] done")
