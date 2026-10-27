"""Per-project stores must not be written before they've been restored:
the on-disk copy is the only one there is until then."""

from std.ffi import external_call
from std.testing import TestSuite, assert_equal
from turbokod.desktop import Desktop
from turbokod.drafts_store import StoredDraft, load_drafts, save_drafts
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


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
