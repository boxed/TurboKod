"""Editor file I/O: load, save, external change, gutters.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.diff import REGION_CONFLICT
from turbokod.editor import (
    EXT_CHANGE_CONFLICT, EXT_CHANGE_MERGED, EXT_CHANGE_NONE,
    EXT_CHANGE_RELOADED, Editor
)
from turbokod.file_io import read_file, write_file
from turbokod.git_blame import BlameLine
from turbokod.git_changes import (
    GIT_CHANGE_ADDED, GIT_CHANGE_MODIFIED, GIT_CHANGE_NONE
)
from turbokod.highlight import GrammarRegistry, highlight_for_extension
from turbokod.posix import which
from turbokod.spell import Speller
from turbokod.settings import Settings
from turbokod.events import Event, KEY_END, KEY_RIGHT, MOUSE_BUTTON_LEFT
from turbokod.geometry import Point, Rect
from turbokod.merge_view import CHOICE_BOTH, MergeView

from support import _VIEW, _key, _temp_path, setup_test_env


def test_editor_dirty_flag() raises:
    var ed = Editor(String("hello"))
    assert_false(ed.dirty)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)        # navigation, not dirty
    assert_false(ed.dirty)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)  # insert, dirty
    assert_true(ed.dirty)


def test_editor_from_file() raises:
    var ed = Editor.from_file(String("examples/hello.mojo"))
    assert_true(ed.buffer.line_count() > 5)
    assert_false(ed.dirty)
    assert_true(Int(ed.file_size) > 0)
    # Initial check: nothing changed since open, so the status code is
    # EXT_CHANGE_NONE.
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_NONE)


def test_editor_save_clears_dirty() raises:
    var path = _temp_path(String("_save.txt"))
    assert_true(write_file(path, String("hello\nworld\n")))
    var ed = Editor.from_file(path)
    assert_false(ed.dirty)
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("!"))), _VIEW)
    assert_true(ed.dirty)
    assert_true(ed.save())
    assert_false(ed.dirty)
    var contents = read_file(path)
    # First line was "hello"; cursor moved to its end before typing '!'.
    var first_line = String(StringSlice(
        unsafe_from_utf8=contents.as_bytes()[:6],
    ))
    assert_equal(first_line, String("hello!"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_save_as_adopts_path() raises:
    var path = _temp_path(String("_saveas.txt"))
    var ed = Editor(String("alpha\nbeta\n"))
    assert_equal(ed.file_path, String(""))
    assert_true(ed.save_as(path))
    assert_equal(ed.file_path, path)
    assert_false(ed.dirty)
    assert_equal(read_file(path), String("alpha\nbeta\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_clean_reload_when_buffer_clean() raises:
    """Buffer is clean: an external write triggers a verbatim reload."""
    var path = _temp_path(String("_ext_clean.txt"))
    assert_true(write_file(path, String("alpha\nbeta\n")))
    var ed = Editor.from_file(path)
    assert_false(ed.dirty)
    # Rewrite with different size so the stat-compare detects it even
    # within the same wall-clock second.
    assert_true(write_file(path, String("alpha\nbeta\nGAMMA\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_RELOADED)
    assert_false(ed.dirty)
    assert_equal(ed.buffer.line_count(), 4)
    assert_equal(ed.buffer.line(2), String("GAMMA"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_skipped_in_review_mode() raises:
    """A review-hosted editor shows a pinned snapshot (commit / index
    blob), with ``file_path`` set only for identity. Its on-disk file
    can legitimately differ from the snapshot — e.g. reviewing a commit
    whose change was later reverted on disk. The external-change sweep
    must NOT reload the on-disk bytes over the snapshot, or the changes
    the review is meant to show vanish."""
    var path = _temp_path(String("_ext_review.txt"))
    # On disk: the "reverted" content. The review buffer below holds the
    # historical snapshot, which differs from this.
    assert_true(write_file(path, String("reverted\n")))
    var ed = Editor(String("snapshot line 1\nsnapshot line 2"))
    ed.file_path = path
    ed.review_mode = True
    ed.read_only = True
    # Even though disk differs (and stat info is unset, as for a transient
    # blob window), the review buffer is left untouched.
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_NONE)
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(0), String("snapshot line 1"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_refreshes_highlights() raises:
    """Reload from disk must produce highlights matching the new
    content — not stale entries pointing into the previous buffer.
    Exercises a scope-changing case (block comment over multiple
    lines, then erased) so the cache's per-line post-stack actually
    matters.
    """
    var path = _temp_path(String("_ext_hl.rs"))
    assert_true(write_file(
        path,
        String("/* block start\nstill in block\nstill in block 2\n*/ end\n"),
    ))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    assert_true(len(ed.highlights) > 0)
    # Same path, but the block comment is gone — the new buffer's
    # post-stacks differ from the cached ones at every row.
    assert_true(write_file(
        path,
        String("fn two() {}\nfn three() {}\n"),
    ))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_RELOADED)
    ed.flush_highlights(registry, speller)
    var post = ed.highlights.copy()
    var expected = highlight_for_extension(String("rs"), ed.buffer.lines)
    # Same shape as a full retokenize against the new buffer.
    assert_equal(len(post), len(expected))
    for i in range(len(post)):
        assert_equal(post[i].row, expected[i].row)
        assert_equal(post[i].col_start, expected[i].col_start)
        assert_equal(post[i].col_end, expected[i].col_end)
    # No highlight may point at a row past the new buffer's end.
    var max_row = ed.buffer.line_count() - 1
    for i in range(len(post)):
        assert_true(post[i].row <= max_row)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_auto_merges_disjoint_edits() raises:
    """Buffer edits and disk edits in different regions → silent merge."""
    var path = _temp_path(String("_ext_merge.txt"))
    assert_true(write_file(path, String("a\nb\nc\nd\ne\n")))
    var ed = Editor.from_file(path)
    # Local edit on the first line: type before the 'a'.
    _ = ed.handle_key(Event.key_event(UInt32(ord("X"))), _VIEW)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("Xa"))
    # External edit on the last non-empty line.
    assert_true(write_file(path, String("a\nb\nc\nd\nEEE\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_MERGED)
    # Both edits present, no conflict markers.
    assert_equal(ed.buffer.line(0), String("Xa"))
    assert_equal(ed.buffer.line(4), String("EEE"))
    # Buffer differs from disk now (disk lacks our 'X'), so still dirty.
    assert_true(ed.dirty)
    # No merge pending — the auto-merge resolved cleanly.
    assert_false(ed.merge_pending)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_clears_dirty_when_disk_already_has_our_edits() raises:
    """If disk happens to already match our buffer (someone applied
    the same edit externally), the merge resolves to clean and the
    buffer goes back to non-dirty."""
    var path = _temp_path(String("_ext_match.txt"))
    assert_true(write_file(path, String("alpha\n")))
    var ed = Editor.from_file(path)
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("!"))), _VIEW)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("alpha!"))
    # External writer produced the exact same content (different size
    # from baseline so stat fires).
    assert_true(write_file(path, String("alpha!\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_MERGED)
    assert_false(ed.dirty)
    assert_equal(ed.buffer.line(0), String("alpha!"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_conflict_stashes_regions() raises:
    """Both buffer and disk modified the same line → the buffer is left
    untouched (no markers jammed in), and the structured merge regions
    are stashed for the host to resolve via a MergeView."""
    var path = _temp_path(String("_ext_conflict.txt"))
    assert_true(write_file(path, String("a\nb\nc\n")))
    var ed = Editor.from_file(path)
    # Local: cursor at start of "b", select line, replace with "OURS".
    ed.move_to(1, 0, False)
    ed.move_to(1, 1, True)
    _ = ed.handle_key(Event.key_event(UInt32(ord("O"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("U"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("R"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("S"))), _VIEW)
    assert_equal(ed.buffer.line(1), String("OURS"))
    assert_true(ed.dirty)
    # External: same line replaced with different content; size differs
    # so stat-compare fires.
    assert_true(write_file(path, String("a\nTHEIRS\nc\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_CONFLICT)
    assert_true(ed.dirty)
    assert_true(ed.merge_pending)
    # Buffer is untouched: still our local edits, no conflict markers.
    assert_equal(ed.buffer.line(1), String("OURS"))
    for i in range(ed.buffer.line_count()):
        assert_true(ed.buffer.line(i).find(String("<<<<<<<")) < 0)
    # The stashed regions carry exactly one conflict with both sides.
    var regions = ed.consume_merge_regions()
    assert_false(ed.merge_pending)
    var nconf = 0
    var saw_ours = False
    var saw_theirs = False
    for i in range(len(regions)):
        if regions[i].kind == REGION_CONFLICT:
            nconf += 1
            for j in range(len(regions[i].ours_lines)):
                if regions[i].ours_lines[j] == String("OURS"):
                    saw_ours = True
            for j in range(len(regions[i].theirs_lines)):
                if regions[i].theirs_lines[j] == String("THEIRS"):
                    saw_theirs = True
    assert_equal(nconf, 1)
    assert_true(saw_ours)
    assert_true(saw_theirs)
    # consume_merge_regions is one-shot.
    var again = ed.consume_merge_regions()
    assert_equal(len(again), 0)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_merge_resolve_writes_disk() raises:
    """End-to-end (no UI loop): a conflict is detected, the regions are
    fed to a MergeView, the user resolves them, and apply_resolved_merge
    lands the result in both the buffer and on disk."""
    var path = _temp_path(String("_ext_merge_resolve.txt"))
    assert_true(write_file(path, String("a\nb\nc\n")))
    var ed = Editor.from_file(path)
    # Local: replace "b" with "OURS".
    ed.move_to(1, 0, False)
    ed.move_to(1, 1, True)
    _ = ed.handle_key(Event.key_event(UInt32(ord("O"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("U"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("R"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("S"))), _VIEW)
    # External: same line replaced differently → conflict.
    assert_true(write_file(path, String("a\nTHEIRS\nc\n")))
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_CONFLICT)
    # Resolve the conflict by keeping both sides.
    var regions = ed.consume_merge_regions()
    var mv = MergeView()
    mv.open(regions^, 0, path)
    for i in range(len(mv.states)):
        mv.states[i].choice = CHOICE_BOTH
    var text = mv.resolved_text()
    assert_true(ed.apply_resolved_merge(text^))
    assert_false(ed.dirty)
    assert_false(ed.merge_pending)
    # Buffer holds the merged result...
    assert_equal(ed.buffer.line(0), String("a"))
    assert_equal(ed.buffer.line(1), String("OURS"))
    assert_equal(ed.buffer.line(2), String("THEIRS"))
    assert_equal(ed.buffer.line(3), String("c"))
    # ...and so does the on-disk file.
    assert_equal(read_file(path), String("a\nOURS\nTHEIRS\nc\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_save_applies_editorconfig_transforms() raises:
    """``save`` should trim trailing whitespace and ensure a final newline
    when the editorconfig says to. The fixture's top-level ``[*]`` sets
    both, so saving a .txt file inside the fixture tree exercises both."""
    var path = String("tests/fixtures/editorconfig/test_save.txt")
    # Bootstrap with a payload that ``trim`` + ``final newline`` will rewrite.
    assert_true(write_file(path, String("alpha   \nbeta")))
    var ed = Editor.from_file(path)
    assert_equal(ed.editorconfig.trim_trailing_whitespace, 1)
    assert_equal(ed.editorconfig.insert_final_newline, 1)
    assert_true(ed.save())
    var got = read_file(path)
    # ``alpha   `` → ``alpha`` (trailing spaces trimmed) and a final ``\n``
    # is appended even though the original file lacked one.
    assert_equal(got, String("alpha\nbeta\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_save_uses_editorconfig_line_endings() raises:
    """When ``end_of_line`` is ``crlf``, ``save`` should join lines with
    ``\\r\\n`` even though the buffer uses ``\\n`` internally."""
    var dir = String("/tmp/turbokod_ec_eol_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var ec_path = dir + String("/.editorconfig")
    assert_true(write_file(ec_path, String(
        "root = true\n[*]\nend_of_line = crlf\n"
    )))
    var f_path = dir + String("/x.txt")
    assert_true(write_file(f_path, String("a\nb")))
    var ed = Editor.from_file(f_path)
    assert_equal(ed.editorconfig.end_of_line, String("crlf"))
    assert_true(ed.save())
    var got = read_file(f_path)
    assert_equal(got, String("a\r\nb"))
    _ = external_call["unlink", Int32]((f_path + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((ec_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_editor_save_applies_global_transform_defaults() raises:
    """With no editorconfig opinion on trim / final-newline, ``save``
    must fall back to the per-editor global defaults (Settings ▸ Editor).
    The fixture's ``root = true`` editorconfig sets only ``end_of_line``,
    so both transform properties stay unset and the defaults drive."""
    var dir = String("/tmp/turbokod_global_defaults_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var ec_path = dir + String("/.editorconfig")
    # ``root = true`` with no trim/final-newline keys → both stay unset.
    assert_true(write_file(ec_path, String("root = true\n[*]\ncharset = utf-8\n")))
    var f_path = dir + String("/x.txt")
    assert_true(write_file(f_path, String("alpha   \nbeta")))
    var ed = Editor.from_file(f_path)
    assert_equal(ed.editorconfig.trim_trailing_whitespace, -1)
    assert_equal(ed.editorconfig.insert_final_newline, -1)
    # Globals on (the app default): trim trailing whitespace + add the
    # missing final newline.
    ed.default_trim_trailing_whitespace = 1
    ed.default_insert_final_newline = 1
    assert_true(ed.save())
    assert_equal(read_file(f_path), String("alpha\nbeta\n"))
    # Globals off → leave the file untouched (no trim, no forced newline).
    assert_true(write_file(f_path, String("alpha   \nbeta")))
    var ed2 = Editor.from_file(f_path)
    ed2.default_trim_trailing_whitespace = 0
    ed2.default_insert_final_newline = -1
    assert_true(ed2.save())
    assert_equal(read_file(f_path), String("alpha   \nbeta"))
    _ = external_call["unlink", Int32]((f_path + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((ec_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_editor_editorconfig_overrides_global_transform_default() raises:
    """An explicit ``.editorconfig`` value wins over the global default:
    ``trim_trailing_whitespace = false`` keeps trailing spaces even when
    the global trim default is on."""
    var dir = String("/tmp/turbokod_ec_wins_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var ec_path = dir + String("/.editorconfig")
    assert_true(write_file(ec_path, String(
        "root = true\n[*]\ntrim_trailing_whitespace = false\n"
    )))
    var f_path = dir + String("/x.txt")
    assert_true(write_file(f_path, String("alpha   \nbeta")))
    var ed = Editor.from_file(f_path)
    assert_equal(ed.editorconfig.trim_trailing_whitespace, 0)
    ed.default_trim_trailing_whitespace = 1  # global says trim…
    ed.default_insert_final_newline = -1
    assert_true(ed.save())
    # …but the editorconfig's explicit false wins: spaces survive.
    assert_equal(read_file(f_path), String("alpha   \nbeta"))
    _ = external_call["unlink", Int32]((f_path + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((ec_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_editor_gutter_click_emits_breakpoint_toggle() raises:
    # Line-number gutter on → 2 cells of gutter at the left edge. A
    # left-click there must surface as a pending breakpoint toggle for
    # the corresponding buffer row, without moving the cursor.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_breakpoint_toggle()
    assert_true(Bool(req))
    assert_equal(req.value(), 1)
    assert_equal(ed.selections[0].row, 0)
    assert_equal(ed.selections[0].col, 0)
    # Slot is one-shot.
    assert_false(Bool(ed.consume_breakpoint_toggle()))


def test_editor_gutter_click_below_eof_is_ignored() raises:
    # Click in the gutter on a screen row past the last buffer line —
    # no breakpoint should be toggled (matches "click on empty space"
    # being a no-op for cursor placement, just without the cursor side
    # effect).
    var ed = Editor(String("alpha\nbeta"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 4), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 6))
    assert_false(Bool(ed.consume_breakpoint_toggle()))


def test_editor_gutter_drag_motion_does_not_toggle() raises:
    # Drag motion through the gutter must not flood pending toggles.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=True, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    assert_false(Bool(ed.consume_breakpoint_toggle()))


def test_editor_blame_gutter_widens_total_gutter() raises:
    """``set_blame`` enables the gutter; the editor's overall left
    margin grows to make room for ``<sha> <author>`` (8+1+14+1 = 24
    cells). Toggling off shrinks the margin back."""
    var ed = Editor(String("alpha\nbeta\n"))
    var bl = List[BlameLine]()
    bl.append(BlameLine(String("12345678"), String("Anders")))
    bl.append(BlameLine(String("12345678"), String("Anders")))
    ed.set_blame(bl^)
    assert_true(ed.blame_visible)
    assert_equal(ed._blame_gutter(), 24)
    ed.toggle_blame()
    assert_false(ed.blame_visible)
    assert_equal(ed._blame_gutter(), 0)


def test_editor_git_changes_gutter_widens_total_gutter() raises:
    """``set_git_changes`` flips the column on; the editor's overall
    left margin grows by exactly one cell. ``invalidate_git_changes``
    drops the cache so the gutter goes away again."""
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.git_changes_visible = True
    var marks = List[Int]()
    marks.append(GIT_CHANGE_ADDED)
    marks.append(GIT_CHANGE_MODIFIED)
    marks.append(GIT_CHANGE_NONE)
    ed.set_git_changes(marks^)
    assert_equal(ed._git_changes_gutter(), 1)
    ed.invalidate_git_changes()
    # Visible flag still on, but no data → no column.
    assert_equal(ed._git_changes_gutter(), 0)


def main() raises:
    setup_test_env()
    test_editor_dirty_flag()
    test_editor_from_file()
    test_editor_save_clears_dirty()
    test_editor_save_as_adopts_path()
    test_editor_external_change_clean_reload_when_buffer_clean()
    test_editor_external_change_skipped_in_review_mode()
    test_editor_external_change_refreshes_highlights()
    test_editor_external_change_auto_merges_disjoint_edits()
    test_editor_external_change_clears_dirty_when_disk_already_has_our_edits()
    test_editor_external_change_conflict_stashes_regions()
    test_editor_merge_resolve_writes_disk()
    test_editor_save_applies_editorconfig_transforms()
    test_editor_save_uses_editorconfig_line_endings()
    test_editor_save_applies_global_transform_defaults()
    test_editor_editorconfig_overrides_global_transform_default()
    test_editor_gutter_click_emits_breakpoint_toggle()
    test_editor_gutter_click_below_eof_is_ignored()
    test_editor_gutter_drag_motion_does_not_toggle()
    test_editor_blame_gutter_widens_total_gutter()
    test_editor_git_changes_gutter_widens_total_gutter()
    print("editor_io: 20 tests passed")
