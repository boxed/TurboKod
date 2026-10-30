"""Per-project stores must not be written before they've been restored:
the on-disk copy is the only one there is until then."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal
from turbokod.canvas import Canvas
from turbokod.desktop import Desktop, HELP_HOTKEYS
from turbokod.drafts_store import StoredDraft, load_drafts, save_drafts
from turbokod.file_io import read_file, stat_file, write_file
from turbokod.lsp import capture_command
from turbokod.string_utils import string_list
from turbokod.events import Event, KEY_BACKSPACE
from turbokod.geometry import Rect
from support import _temp_path, setup_test_env


def test_a_focus_out_before_the_first_paint_keeps_the_drafts() raises:
    # opening a project restores its drafts on the next paint; switching
    # away before that used to save the (still empty) set over them
    var root = _temp_path(String("_drafts_focus_out"))
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32]((root + String("\0")).unsafe_ptr(), Int32(0o755))
    var drafts = List[StoredDraft]()
    var draft = StoredDraft()
    draft.seq = 1
    draft.content = String("unsaved work")
    drafts.append(draft^)
    assert_equal(save_drafts(root, drafts), True)
    var d = Desktop()
    d.open_project(root)
    _ = d.handle_event(Event.focus_event(False), Rect(0, 0, 80, 30))
    var kept = load_drafts(root)
    assert_equal(len(kept), 1)
    assert_equal(kept[0].content, String("unsaved work"))
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_a_draft_comes_back_as_it_was_saved() raises:
    var root = _temp_path(String("_drafts_round_trip"))
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32]((root + String("\0")).unsafe_ptr(), Int32(0o755))
    var d = StoredDraft()
    d.seq = 3
    d.content = String("line \"one\"\n\ttwo\r\n😀")
    d.rect_a_x = 1
    d.rect_a_y = 2
    d.rect_b_x = 3
    d.rect_b_y = 4
    d.is_maximized = True
    d.restore_a_x = 5
    d.restore_a_y = 6
    d.restore_b_x = 7
    d.restore_b_y = 8
    d.cursor_row = 9
    d.cursor_col = 10
    d.scroll_x = 11
    d.scroll_y = 12
    d.last_focus_ms = 13
    var drafts = List[StoredDraft]()
    drafts.append(d)
    assert_equal(save_drafts(root, drafts), True)
    var back = load_drafts(root)
    assert_equal(len(back), 1)
    ref b = back[0]
    assert_equal(b.seq, 3)
    assert_equal(b.content, d.content)
    assert_equal(
        [b.rect_a_x, b.rect_a_y, b.rect_b_x, b.rect_b_y, b.restore_a_x, b.restore_a_y, b.restore_b_x,
         b.restore_b_y, b.cursor_row, b.cursor_col, b.scroll_x, b.scroll_y, b.last_focus_ms],
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
    )
    assert_equal(b.is_maximized, True)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_only_typed_untitled_buffers_are_kept_as_drafts() raises:
    # help, docs and info windows have no file either; kept as drafts, they
    # came back after a restart as unsaved "Untitled" buffers
    var screen = Rect(0, 0, 80, 30)
    var d = Desktop()
    _ = d.dispatch_action(HELP_HOTKEYS, screen)
    _ = d._add_text_window(String("Language servers"), String("pyright: ready"), screen)
    d.new_file(screen)
    _ = d.handle_event(Event.key_event(UInt32(ord("x"))), screen)
    var drafts = d._snapshot_drafts()
    assert_equal(len(drafts), 1)
    assert_equal(drafts[0].content, String("x"))
    assert_equal(drafts[0].seq, 1)


def test_drafts_are_written_when_a_buffer_changes_and_only_then() raises:
    # Encoding every untitled buffer each paint cost 22 ms with an 8 MB one
    var root = _temp_path(String("_drafts_key"))
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32]((root + String("\0")).unsafe_ptr(), Int32(0o755))
    var screen = Rect(0, 0, 80, 30)
    var d = Desktop()
    d.open_project(root)
    var canvas = Canvas(80, 30)
    d.paint(canvas, screen)   # restores the project's drafts, if any
    d.new_file(screen)
    _ = d.handle_event(Event.key_event(UInt32(ord("a"))), screen)
    _ = d.handle_event(Event.key_event(UInt32(ord("b"))), screen)
    d._save_drafts_if_changed()
    assert_equal(load_drafts(root)[0].content, String("ab"))
    # nothing changed: not encoded or written again
    var path = root + String("/.turbokod/per_user")
    _ = external_call["system", Int32]((String("rm -f '") + path + String("'/*/drafts.json\0")).unsafe_ptr())
    d._save_drafts_if_changed()
    assert_equal(len(load_drafts(root)), 0)
    # the same length, other text
    _ = d.handle_event(Event.key_event(KEY_BACKSPACE), screen)
    _ = d.handle_event(Event.key_event(UInt32(ord("c"))), screen)
    d._save_drafts_if_changed()
    assert_equal(load_drafts(root)[0].content, String("ac"))
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def _quit_with_unsaved(root: String, path: String) raises:
    var screen = Rect(0, 0, 80, 30)
    var d = Desktop()
    d.config.auto_save = False
    d.open_project(root)
    var canvas = Canvas(80, 30)
    d.paint(canvas, screen)
    d.open_file(path, screen)
    _ = d.handle_event(Event.key_event(UInt32(ord("X"))), screen)
    d.begin_shutdown()


def _reopen(root: String) raises -> Desktop:
    var screen = Rect(0, 0, 80, 30)
    var d = Desktop()
    d.open_project(root)
    var canvas = Canvas(80, 30)
    d.paint(canvas, screen)
    return d^


def _fresh(name: String) -> String:
    var root = _temp_path(name)
    _ = external_call["system", Int32]((String("rm -rf '") + root + String("'; mkdir -p '") + root + String("'\0")).unsafe_ptr())
    return root^


def test_edits_that_couldnt_be_saved_come_back_after_a_quit() raises:
    # Quitting with auto-save off (or a save failing) can't ask: the
    # edits were gone
    var root = _fresh(String("_file_draft"))
    var path = root + String("/a.txt")
    assert_equal(write_file(path, String("one\n")), True)
    _quit_with_unsaved(root, path)
    assert_equal(read_file(path), String("one\n"))
    var d = _reopen(root)
    var idx = d._find_window_for_path(path)
    assert_equal(idx >= 0, True)
    assert_equal(d.windows.windows[idx].editor.text_snapshot(), String("Xone\n"))
    assert_equal(d.windows.windows[idx].editor.dirty, True)
    _ = external_call["system", Int32]((String("rm -rf '") + root + String("'\0")).unsafe_ptr())


def test_a_change_on_disk_since_merges_with_the_kept_edits() raises:
    var root = _fresh(String("_file_draft_merge"))
    var path = root + String("/a.txt")
    assert_equal(write_file(path, String("one\ntwo\nthree\n")), True)
    _quit_with_unsaved(root, path)
    assert_equal(write_file(path, String("one\ntwo\nthree\nfour\n")), True)
    var d = _reopen(root)
    var idx = d._find_window_for_path(path)
    assert_equal(
        d.windows.windows[idx].editor.text_snapshot(),
        String("Xone\ntwo\nthree\nfour\n"),
    )
    _ = external_call["system", Int32]((String("rm -rf '") + root + String("'\0")).unsafe_ptr())


def test_kept_edits_of_a_file_since_deleted_come_back_untitled() raises:
    var root = _fresh(String("_file_draft_gone"))
    var path = root + String("/a.txt")
    assert_equal(write_file(path, String("one\n")), True)
    _quit_with_unsaved(root, path)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    var d = _reopen(root)
    var found = False
    for w in d.windows.windows:
        if w.is_editor and w.editor.text_snapshot() == String("Xone\n"):
            found = True
            assert_equal(len(w.editor.file_path.as_bytes()), 0)
    assert_equal(found, True)
    _ = external_call["system", Int32]((String("rm -rf '") + root + String("'\0")).unsafe_ptr())


def test_per_user_state_stays_out_of_git() raises:
    var root = _temp_path(String("_per_user_git"))
    _ = capture_command(string_list("rm", "-rf", root))
    _ = capture_command(string_list("git", "init", "-q", root))
    var drafts = List[StoredDraft]()
    var draft = StoredDraft()
    draft.content = String("x")
    drafts.append(draft^)
    assert_equal(save_drafts(root, drafts), True)
    var status = capture_command(string_list("git", "-C", root, "status", "--porcelain", "-uall"))
    assert_equal(status.stdout, String(""))
    # an edited one is left alone
    assert_equal(write_file(root + "/.turbokod/per_user/.gitignore", String("drafts.json\n")), True)
    assert_equal(save_drafts(root, drafts), True)
    assert_equal(read_file(root + "/.turbokod/per_user/.gitignore"), String("drafts.json\n"))
    _ = capture_command(string_list("rm", "-rf", root))


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
