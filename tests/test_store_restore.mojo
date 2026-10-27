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


def main() raises:
    setup_test_env()
    TestSuite.discover_tests[__functions_in_module()]().run()
