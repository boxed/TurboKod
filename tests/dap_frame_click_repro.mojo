"""Reproduce what happens when the user clicks a non-top stack frame
in mojovision's debug pane. Drives the DAP protocol directly, no UI.

Run::

    ./run.sh tests/dap_frame_click_repro.mojo

Sequence:

1. Start debugpy on a tiny test program with a breakpoint.
2. Wait for the stopped event.
3. Fetch the stack trace (multiple frames).
4. Fetch scopes + variables for the **TOP** frame. (This is what the
   editor does automatically on stop — should always work.)
5. Now simulate the click: fetch scopes + variables for a **NON-TOP**
   frame (the second frame, ``<module>``). This is what
   ``Desktop.dap_tick`` does in response to a pane click.
6. Request expansion of any compound variable (variablesReference > 0)
   in either frame. Mirrors clicking a ``▶ obj`` row.

If any of steps 4-6 crash, we have an isolated reproducer. If all
pass, the click crash is genuinely UI-side and not in the data path.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call

from mojovision.dap_dispatch import DapManager, DapStackFrame
from mojovision.debugger_config import (
    built_in_debuggers, find_debugger_for_language,
)
from mojovision.file_io import write_file
from mojovision.posix import monotonic_ms


fn _sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](Int32(ms * 1000))


fn _wait_for(
    mut mgr: DapManager, label: String, deadline_ms: Int,
) raises -> Bool:
    """Tick until either the manager reports has_X for ``label`` or
    we hit the deadline. Returns True on data, False on timeout."""
    while monotonic_ms() < deadline_ms:
        _sleep_ms(50)
        mgr.tick()
        if label == String("stack") and mgr.has_stack():
            return True
        if label == String("scopes") and mgr.has_scopes():
            return True
        if label == String("variables") and mgr.has_variables():
            return True
        if label == String("stopped"):
            var s = mgr.take_stopped()
            if s:
                # Re-stash by setting it back? We can't, so just signal
                # the caller via a different path — they'll use the
                # thread id of 1 directly. (Single-threaded debuggee.)
                return True
        if mgr.is_failed():
            print("manager FAILED:", mgr.failure_reason)
            return False
        if mgr.is_terminated():
            print("manager TERMINATED")
            return False
    print("timeout waiting for", label)
    return False


fn main() raises:
    var test_path = String("/tmp/dap_click_test.py")
    var src = String("def foo(a, b):\n")             # 1
    src = src + String("    x = a + b\n")             # 2 ← breakpoint here
    src = src + String("    return x\n")              # 3
    src = src + String("\n")                          # 4
    src = src + String("foo(40, 2)\n")                # 5
    src = src + String("print('done')\n")             # 6
    if not write_file(test_path, src):
        print("could not write test file"); return

    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    if idx < 0:
        print("no python debugger registered"); return

    var mgr = DapManager()
    mgr.toggle_breakpoint(test_path, 1)  # 0-based: line 2 in source
    mgr.start(debs[idx], test_path, String("/tmp"), List[String]())
    if mgr.is_failed():
        print("start failed:", mgr.failure_reason); return

    # Drive the manager until we hit the stopped event.
    var deadline = monotonic_ms() + 30000
    var thread_id = 0
    while monotonic_ms() < deadline:
        _sleep_ms(50)
        mgr.tick()
        var s = mgr.take_stopped()
        if s:
            thread_id = s.value().thread_id
            print("STOPPED at thread", thread_id)
            break
        if mgr.is_failed():
            print("FAILED before stop:", mgr.failure_reason); return
    if thread_id == 0:
        print("never stopped"); return

    # Step 1: full stack.
    _ = mgr.request_stack_trace(thread_id, 64)
    if not _wait_for(mgr, String("stack"), monotonic_ms() + 5000):
        return
    var frames = mgr.take_stack()
    print("STACK", len(frames), "frames:")
    for k in range(len(frames)):
        print(
            " ", k, frames[k].name, frames[k].path,
            "line=", frames[k].line, "id=", frames[k].id,
        )

    # Step 2: scopes + variables for TOP frame (frame 0).
    print("--- TOP-frame scopes/variables (sanity) ---")
    _ = mgr.request_scopes(frames[0].id)
    if not _wait_for(mgr, String("scopes"), monotonic_ms() + 5000):
        return
    var top_scopes = mgr.take_scopes()
    print("TOP scopes:", len(top_scopes))
    for k in range(len(top_scopes)):
        print(" ", top_scopes[k].name, "ref=",
              top_scopes[k].variables_reference)
    if len(top_scopes) > 0:
        _ = mgr.request_variables(top_scopes[0].variables_reference)
        if _wait_for(mgr, String("variables"), monotonic_ms() + 5000):
            var top_vars = mgr.take_variables()
            print("TOP locals:", len(top_vars))
            for k in range(len(top_vars)):
                print(" ", top_vars[k].name, "=", top_vars[k].value)

    # Step 3: scopes + variables for a NON-TOP frame.
    # This is what mojovision does in response to a pane click.
    if len(frames) < 2:
        print("only 1 frame; can't test non-top click")
        mgr.shutdown(); return
    var pick = 1  # ``<module>`` typically
    print("--- CLICK simulation: frame", pick, "(",
          frames[pick].name, ") ---")
    _ = mgr.request_scopes(frames[pick].id)
    if not _wait_for(mgr, String("scopes"), monotonic_ms() + 5000):
        return
    var click_scopes = mgr.take_scopes()
    print("CLICK scopes:", len(click_scopes))
    for k in range(len(click_scopes)):
        print(" ", click_scopes[k].name, "ref=",
              click_scopes[k].variables_reference)
    if len(click_scopes) > 0:
        _ = mgr.request_variables(click_scopes[0].variables_reference)
        if _wait_for(mgr, String("variables"), monotonic_ms() + 5000):
            var click_vars = mgr.take_variables()
            print("CLICK locals:", len(click_vars))
            for k in range(len(click_vars)):
                print(" ", click_vars[k].name, "=", click_vars[k].value,
                      " ref=", click_vars[k].variables_reference)
            # Step 4: expand any compound variable.
            for k in range(len(click_vars)):
                if click_vars[k].variables_reference != 0:
                    print("EXPANDING", click_vars[k].name)
                    _ = mgr.request_variables(
                        click_vars[k].variables_reference,
                    )
                    if _wait_for(
                        mgr, String("variables"),
                        monotonic_ms() + 5000,
                    ):
                        var children = mgr.take_variables()
                        print(" ", click_vars[k].name, "has",
                              len(children), "children")
                    break

    print("ALL STEPS COMPLETED — no crash in data path")
    mgr.shutdown()
