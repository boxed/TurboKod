"""Per-project stores must not be written before they've been restored:
the on-disk copy is the only one there is until then."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal
from turbokod.desktop import Desktop, HELP_HOTKEYS
from turbokod.drafts_store import StoredDraft, load_drafts, save_drafts
from turbokod.file_io import read_file, write_file
from turbokod.lsp import capture_command
from turbokod.string_utils import string_list
from turbokod.events import Event
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
