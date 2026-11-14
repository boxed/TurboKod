"""One language server shared by several windows (``lsp_shared.mojo``).

Each test plays two project windows: two ``LspManager``s with the same
``LspPool``, each rooted in its own scratch directory, against
``tests/fixtures/mock_lsp.py``. The mock's request log is what shows the
*server's* side — how many processes were initialized, which folders it was
told about, who answered what.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from turbokod.file_io import delete_path, read_file, stat_file, write_file
from turbokod.json import JsonValue, parse_json
from turbokod.lsp_dispatch import LspManager
from turbokod.lsp_shared import free_pool, new_pool, pool_at
from turbokod.posix import getcwd_path, which
from turbokod.string_utils import split_lines_no_trailing

from support import _process_dir_name, _sweep_process_dirs, setup_test_env


def _scratch_dir(name: String) -> String:
    """Per-process scratch dir under ``.build`` (see test_lsp_conformance)."""
    var build = getcwd_path() + String("/.build")
    var base = build + String("/lsp_shared")
    var own = base + String("/") + _process_dir_name()
    var dir = own + String("/") + name
    for d in [build, base, own, dir]:
        _ = external_call["mkdir", Int32](
            (d + String("\0")).unsafe_ptr(), UInt32(0o755),
        )
    _sweep_process_dirs(base)
    return dir^


def _mock_argv(scenario: String, log_path: String) -> List[String]:
    """The mock's command line. Identical for both windows of a test — that
    is what makes them the same server to the pool."""
    var argv = List[String]()
    argv.append(which(String("python3")))
    argv.append(getcwd_path() + String("/tests/fixtures/mock_lsp.py"))
    argv.append(getcwd_path() + String("/tests/fixtures/lsp/") + scenario)
    argv.append(log_path)
    return argv^


def _pump(mut a: LspManager, mut b: LspManager, rounds: Int = 60):
    for _ in range(rounds):
        _ = a.tick()
        _ = b.tick()
        _ = external_call["usleep", Int32](UInt32(5_000))


def _until_ready(mut a: LspManager, mut b: LspManager) raises:
    for _ in range(400):
        _ = a.tick()
        _ = b.tick()
        if a.is_ready() and b.is_ready():
            return
        if a.is_failed() or b.is_failed():
            raise Error(
                String("failed: ") + a.failure_reason + String(" / ")
                + b.failure_reason,
            )
        _ = external_call["usleep", Int32](UInt32(10_000))
    raise Error(String("never ready; stderr=") + a.captured_stderr())


def _sent(log_path: String) raises -> List[JsonValue]:
    """Every message the mock received, parsed."""
    var out = List[JsonValue]()
    if not stat_file(log_path).ok:
        return out^
    var lines = split_lines_no_trailing(read_file(log_path))
    for i in range(len(lines)):
        if len(lines[i].as_bytes()) == 0:
            continue
        try:
            out.append(parse_json(lines[i]))
        except:
            continue
    return out^


def _await_count(
    mut a: LspManager, mut b: LspManager, log_path: String, method: String,
    want: Int,
) raises -> Int:
    """How many ``method`` messages the mock has logged, pumping (up to ~3 s)
    until it reaches ``want``. The mock writes its log as it reads, so a
    message the client just sent may not be in it yet."""
    var n = 0
    for _ in range(300):
        n = _count(_sent(log_path), method)
        if n >= want:
            return n
        _ = a.tick()
        _ = b.tick()
        _ = external_call["usleep", Int32](UInt32(10_000))
    return n


def _count(msgs: List[JsonValue], method: String) -> Int:
    var n = 0
    for i in range(len(msgs)):
        var m = msgs[i].object_get(String("method"))
        if m and m.value().is_string() and m.value().as_str() == method:
            n += 1
    return n


def _folder_changes(msgs: List[JsonValue], key: String) -> List[String]:
    """URIs listed under ``event.<key>`` ("added" / "removed") across every
    didChangeWorkspaceFolders the server got."""
    var out = List[String]()
    for i in range(len(msgs)):
        var m = msgs[i].object_get(String("method"))
        if not m or m.value().as_str() != String(
            "workspace/didChangeWorkspaceFolders",
        ):
            continue
        var ev = msgs[i].object_get(String("params")).value().object_get(
            String("event"),
        ).value().copy()
        var lst = ev.object_get(key).value().copy()
        for k in range(lst.array_len()):
            out.append(
                lst.array_at(k).object_get(String("uri")).value().as_str(),
            )
    return out^


def _responses_to(msgs: List[JsonValue], id: Int) -> Int:
    """How many replies the client sent to server request ``id``."""
    var n = 0
    for i in range(len(msgs)):
        if msgs[i].object_has(String("method")):
            continue
        var v = msgs[i].object_get(String("id"))
        if v and v.value().is_int() and v.value().as_int() == id:
            n += 1
    return n


struct _Fixture:
    var pool: Int
    var log: String
    var root_a: String
    var root_b: String
    var file_a: String
    var file_b: String

    def __init__(out self, name: String) raises:
        self.pool = new_pool()
        var dir = _scratch_dir(name)
        self.log = dir + String("/sent.jsonl")
        _ = delete_path(self.log)
        self.root_a = dir + String("/project_a")
        self.root_b = dir + String("/project_b")
        for d in [self.root_a, self.root_b]:
            _ = external_call["mkdir", Int32](
                (d + String("\0")).unsafe_ptr(), UInt32(0o755),
            )
        self.file_a = self.root_a + String("/a.py")
        self.file_b = self.root_b + String("/b.py")
        assert_true(write_file(self.file_a, String("x = 1\n")))
        assert_true(write_file(self.file_b, String("y = 2\n")))


def _have_python() -> Bool:
    return len(which(String("python3")).as_bytes()) > 0


def test_second_window_joins_the_running_server() raises:
    if not _have_python():
        return
    var f = _Fixture(String("join"))
    var argv = _mock_argv(String("shared_multiroot.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool)
    _until_ready(a, b)
    assert_true(a.is_shared() and b.is_shared())
    assert_equal(pool_at(f.pool)[].channel_count(), 1)
    # One process, initialized once; the second root arrived as a folder.
    _ = _await_count(
        a, b, f.log, String("workspace/didChangeWorkspaceFolders"), 1,
    )
    _ = _await_count(a, b, f.log, String("initialized"), 1)
    _pump(a, b, 10)
    var sent = _sent(f.log)
    assert_equal(_count(sent, String("initialize")), 1)
    assert_equal(_count(sent, String("initialized")), 1)
    var added = _folder_changes(sent, String("added"))
    assert_equal(len(added), 1)
    assert_equal(added[0], String("file://") + f.root_b)
    a.shutdown()
    b.shutdown()
    free_pool(f.pool)


def test_each_window_gets_the_diagnostics_and_replies_for_its_own_files() raises:
    if not _have_python():
        return
    var f = _Fixture(String("route"))
    var argv = _mock_argv(String("shared_multiroot.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool)
    _until_ready(a, b)
    a.notify_opened(f.file_a, String("x = 1\n"))
    b.notify_opened(f.file_b, String("y = 2\n"))
    _pump(a, b)
    assert_true(a.has_unconsumed_diagnostics_for(f.file_a))
    assert_false(a.has_unconsumed_diagnostics_for(f.file_b))
    assert_true(b.has_unconsumed_diagnostics_for(f.file_b))
    assert_false(b.has_unconsumed_diagnostics_for(f.file_a))
    # A reply goes to the window that asked, not whichever ticks first.
    assert_true(b.request_hover(f.file_b, 0, 0, String("y = 2\n")))
    _pump(a, b)
    assert_false(a.has_pending_hover())
    assert_true(b.has_pending_hover())
    assert_equal(b.take_hover_text(), String("shared hover"))
    a.shutdown()
    b.shutdown()
    free_pool(f.pool)


def test_capability_registrations_reach_every_window_and_are_answered_once() raises:
    if not _have_python():
        return
    var f = _Fixture(String("register"))
    var argv = _mock_argv(String("shared_multiroot.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool)
    _until_ready(a, b)
    # The mock registers rangeFormatting (request id 10000) on this open.
    a.notify_opened(f.file_a, String("x = 1\n"))
    _pump(a, b)
    var key = String("documentRangeFormattingProvider")
    assert_true(a.server_supports(key))
    assert_true(b.server_supports(key))
    _pump(a, b, 20)
    assert_equal(_responses_to(_sent(f.log), 10000), 1)
    # A window that joins afterwards learns it too.
    var c = LspManager()
    var root_c = f.root_a + String("/nested_c")
    _ = external_call["mkdir", Int32](
        (root_c + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    c.start_with(String("python"), argv, root_c, pool=f.pool)
    _until_ready(a, c)
    assert_true(c.is_shared())
    assert_true(c.server_supports(key))
    a.shutdown()
    b.shutdown()
    c.shutdown()
    free_pool(f.pool)


def test_closing_one_window_leaves_the_server_running_for_the_other() raises:
    if not _have_python():
        return
    var f = _Fixture(String("close"))
    var argv = _mock_argv(String("shared_multiroot.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool)
    _until_ready(a, b)
    a.notify_opened(f.file_a, String("x = 1\n"))
    _pump(a, b)
    # Window A (the one that spawned the server) goes away first.
    a.shutdown()
    _ = _await_count(
        a, b, f.log, String("workspace/didChangeWorkspaceFolders"), 2,
    )
    _pump(a, b, 10)
    var sent = _sent(f.log)
    assert_equal(_count(sent, String("shutdown")), 0)
    assert_equal(_count(sent, String("textDocument/didClose")), 1)
    var removed = _folder_changes(sent, String("removed"))
    assert_equal(len(removed), 1)
    assert_equal(removed[0], String("file://") + f.root_a)
    assert_true(b.is_ready())
    assert_true(b.request_hover(f.file_b, 0, 0, String("y = 2\n")))
    for _ in range(60):
        _ = b.tick()
        if b.has_pending_hover():
            break
        _ = external_call["usleep", Int32](UInt32(5_000))
    assert_true(b.has_pending_hover())
    # The last one out shuts it down for real, and the pool forgets it.
    b.shutdown()
    sent = _sent(f.log)
    assert_equal(_count(sent, String("shutdown")), 1)
    assert_equal(_count(sent, String("exit")), 1)
    assert_equal(pool_at(f.pool)[].channel_count(), 0)
    free_pool(f.pool)


def test_workspace_symbols_leave_out_other_windows_projects() raises:
    """A shared server searches every folder; each window sees its own
    project's symbols plus library ones, never another project's."""
    if not _have_python():
        return
    var f = _Fixture(String("wssym"))
    var argv = _mock_argv(String("shared_multiroot.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool)
    _until_ready(a, b)
    _ = _await_count(
        a, b, f.log, String("workspace/didChangeWorkspaceFolders"), 1,
    )
    for which_one in range(2):
        if which_one == 0:
            assert_true(a.request_workspace_symbols(String("In")))
        else:
            assert_true(b.request_workspace_symbols(String("In")))
        for _ in range(100):
            _ = a.tick()
            _ = b.tick()
            if a.has_pending_workspace_symbols() \
                    or b.has_pending_workspace_symbols():
                break
            _ = external_call["usleep", Int32](UInt32(5_000))
        var got = a.take_workspace_symbols() if which_one == 0 \
            else b.take_workspace_symbols()
        var names = List[String]()
        for k in range(len(got)):
            names.append(got[k].name)
        assert_equal(len(names), 2)
        assert_equal(
            names[0], String("InFolderA") if which_one == 0 else String("InFolderB"),
        )
        assert_equal(names[1], String("InLibrary"))
    a.shutdown()
    b.shutdown()
    free_pool(f.pool)


def test_pop_ups_reach_the_window_they_are_about() raises:
    """``showMessage`` naming a project goes to that project's window; one
    naming none goes to every window. ``showMessageRequest`` (one answer)
    goes to the window it names, else the one the user is working in."""
    if not _have_python():
        return
    var f = _Fixture(String("popups"))
    var argv = _mock_argv(String("shared_messages.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool)
    _until_ready(a, b)
    _ = _await_count(
        a, b, f.log, String("workspace/didChangeWorkspaceFolders"), 1,
    )
    # Window A is the one the user is working in: it opens a file.
    a.notify_opened(f.file_a, String("x = 1\n"))
    for _ in range(200):
        _ = a.tick()
        _ = b.tick()
        if a.has_message_request() and b.has_message_request():
            break
        _ = external_call["usleep", Int32](UInt32(5_000))
    # Messages park the latest one; A only ever got the unnamed one.
    assert_equal(a.take_server_message(), String("python: Indexing finished"))
    assert_equal(
        b.take_server_message(),
        String("python: Invalid config in ") + f.root_b
        + String("/pyproject.toml."),
    )
    assert_true(b.has_message_request())
    assert_true(b.message_request_text().startswith(String("Reload ")))
    assert_true(a.has_message_request())
    assert_equal(a.message_request_text(), String("Restart the server?"))
    a.shutdown()
    b.shutdown()
    free_pool(f.pool)


def test_a_server_without_multi_root_gets_one_process_per_window() raises:
    if not _have_python():
        return
    var f = _Fixture(String("fallback"))
    # Advertises no workspace-folder support.
    var argv = _mock_argv(String("shapes_hover_variants.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool)
    _until_ready(a, b)
    assert_false(b.is_shared())
    assert_equal(_await_count(a, b, f.log, String("initialize"), 2), 2)
    assert_equal(len(_folder_changes(_sent(f.log), String("added"))), 0)
    a.shutdown()
    b.shutdown()
    free_pool(f.pool)


def test_restart_spawns_a_fresh_server_instead_of_joining() raises:
    if not _have_python():
        return
    var f = _Fixture(String("fresh"))
    var argv = _mock_argv(String("shared_multiroot.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a, pool=f.pool)
    b.start_with(String("python"), argv, f.root_b, pool=f.pool, fresh=True)
    _until_ready(a, b)
    assert_equal(_await_count(a, b, f.log, String("initialize"), 2), 2)
    # The newest is the one offered to the next window.
    assert_equal(pool_at(f.pool)[].channel_count(), 1)
    a.shutdown()
    b.shutdown()
    free_pool(f.pool)


def test_without_a_pool_every_manager_keeps_a_private_server() raises:
    if not _have_python():
        return
    var f = _Fixture(String("nopool"))
    var argv = _mock_argv(String("shared_multiroot.json"), f.log)
    var a = LspManager()
    var b = LspManager()
    a.start_with(String("python"), argv, f.root_a)
    b.start_with(String("python"), argv, f.root_b)
    _until_ready(a, b)
    assert_false(a.is_shared() or b.is_shared())
    assert_equal(_await_count(a, b, f.log, String("initialize"), 2), 2)
    a.shutdown()
    b.shutdown()
    free_pool(f.pool)


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
