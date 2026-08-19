"""Git: diffs, three-way merge, local changes, review mode.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.review_mode import ReviewMode
from turbokod.colors import (
    Attr, LIGHT_BLUE, LIGHT_RED, STYLE_UNDERLINE, EDITOR_BG, SYN_IDENT,
    SYN_KEYWORD, DIFF_ADD_BG, DIFF_REM_BG, DIFF_ADD_EMPH, DIFF_REM_EMPH,
    FG_TRUECOLOR, BG_TRUECOLOR
)
from turbokod.theme import built_in_themes
from turbokod.diff import (
    DIFF_ROW_ADDED, DIFF_ROW_CONTEXT, DIFF_ROW_REMOVED, DiffRow, MergeRegion,
    REGION_CONFLICT, REGION_STABLE, build_diff_rows, diff3_merge,
    diff3_regions, diff_lines, diff_row_emphasis, diff_row_line_label,
    diff_row_partner, intraline_ranges, unified_diff
)
from turbokod.editor import Editor, TextBuffer
from turbokod.view_state_store import StoredViewState
from turbokod.desktop import Desktop
from turbokod.file_io import join_path, read_file, write_file
from turbokod.git_blame import (
    BlameLine, format_commit_time, parse_blame_porcelain, tz_offset_seconds,
)
from turbokod.git_changes import (
    GIT_CHANGE_ADDED, GIT_CHANGE_MODIFIED, GIT_CHANGE_NONE,
    diff_buffer_against_head, diff_buffer_marks, parse_unified_diff_files
)
from turbokod.local_changes import (
    LocalChanges, build_minimal_patch, _GITOP_BRANCH_DELETE, _GITOP_CHECKOUT,
    _GITOP_MERGE, _GITOP_NONE, _GITOP_PUSH, _GITOP_REBASE,
    _OVERLAY_DELETE_BRANCH_CONFIRM,
    _GITOP_REWORD, _OVERLAY_EDIT_MSG,
    _OVERLAY_MERGE_CHOICE, _OVERLAY_NONE,
    _OVERLAY_OUTPUT, _OVERLAY_STATUS,
    _PANE_BRANCHES, _PANE_COMMITS, _LINE_ADD
)
from turbokod.git_output import (
    GIT_OUT_BRANCH_DELETE, GIT_OUT_CHECKOUT, GIT_OUT_COMMIT, GIT_OUT_MERGE,
    GIT_OUT_OTHER, GIT_OUT_PULL, GIT_OUT_PUSH, GIT_OUT_REBASE,
    GitOutputMatcher, GitOutputMatchers, complete_lines,
)
from turbokod.project import GitignoreMatcher
from turbokod.string_utils import display_columns, split_lines_no_trailing
from turbokod.lsp import capture_command
from turbokod.git_changes import (
    GitBranch, GitCommit, GitStateMtimes, apply_patch_to_index,
    branch_is_merged, compute_staged_diff, compute_unstaged_diff,
    create_reworded_commit, fetch_commit_message, fetch_commit_show,
    fetch_git_branches, fetch_git_commits,
    fetch_git_status, fetch_merged_commits, format_age, git_state_mtimes,
    has_merge_between, head_short_sha, main_line_branch, stage_file,
    unstage_file
)
from turbokod.highlight import (
    GrammarRegistry, Highlight, highlight_for_extension,
    highlight_decorator_attr, highlight_ident_attr, highlight_string_attr
)
from turbokod.onig import onig_global_init, onig_tracked_count
from turbokod.posix import kill_pid, wall_clock_ms, which
from turbokod.config import WRAP_NONE
from turbokod.events import (
    Event, KEY_BACKSPACE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_SPACE, MOD_CTRL,
    MOD_META, MOD_SHIFT, MOUSE_BUTTON_LEFT
)
from turbokod.geometry import Point, Rect
from turbokod.merge_view import (
    CHOICE_BOTH, CHOICE_DISK, CHOICE_LOCAL, MergeView
)
from turbokod.window import Window

from support import (
    _VIEW, _contains, _ensure_dir, _hl_lines, _key, _rm_rf, _run_git,
    _starts_with, _temp_path, setup_test_env
)


def _lines_from(text: String) -> List[String]:
    """Mirror ``TextBuffer.__init__`` for tests that need a plain
    ``List[String]`` line view of a string (used by ``diff3_merge``
    cases below)."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x0A:
            out.append(String(StringSpan(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    out.append(String(StringSpan(unsafe_from_utf8=b[start:len(b)])))
    return out^


def _conflict_count(regions: List[MergeRegion]) -> Int:
    var n = 0
    for i in range(len(regions)):
        if regions[i].kind == REGION_CONFLICT:
            n += 1
    return n


def _single_conflict_view() raises -> MergeView:
    """A MergeView seeded from one conflict: base a/b/c, ours edits b to
    OURS, theirs edits b to THEIRS."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nOURS\nc\n"))
    var theirs = _lines_from(String("a\nTHEIRS\nc\n"))
    var regions = diff3_regions(base, ours, theirs)
    var mv = MergeView()
    mv.open(regions^, 0, String("f.txt"))
    return mv^


def _slist(*items: String) -> List[String]:
    var out = List[String]()
    for it in items:
        out.append(it)
    return out^


def _screen_text(c: Canvas, screen: Rect) -> String:
    """Every glyph on the canvas, one newline-terminated row per line —
    for tests that only care that some string reached the screen."""
    var out = String("")
    for y in range(screen.height()):
        for x in range(screen.width()):
            out += c.get(x, y).glyph
        out += String("\n")
    return out


def _diff_row_text(c: Canvas, y: Int, x0: Int, w: Int) -> String:
    """Glyphs of canvas row ``y`` from column ``x0``, trailing spaces stripped."""
    var glyphs = List[String]()
    for x in range(x0, w):
        var cell = c.get(x, y)
        if cell.width > 0:
            glyphs.append(cell.glyph)
    var end = len(glyphs)
    while end > 0 and glyphs[end - 1] == String(" "):
        end -= 1
    var out = String("")
    for i in range(end):
        out = out + glyphs[i]
    return out


def _diff_gutter_has_digit(c: Canvas, y: Int, gutter_w: Int) -> Bool:
    """True if any gutter column [0, gutter_w) on row ``y`` holds a digit."""
    for x in range(gutter_w):
        var b = c.get(x, y).glyph.as_bytes()
        if len(b) == 1 and b[0] >= UInt8(0x30) and b[0] <= UInt8(0x39):
            return True
    return False


def _diff_row_has_red_bar(c: Canvas, y: Int, gutter_w: Int) -> Bool:
    """True if a red change bar (▌, LIGHT_RED) sits in the gutter of row ``y``."""
    for x in range(gutter_w):
        var cell = c.get(x, y)
        if cell.glyph == String("▌") and cell.attr.fg == LIGHT_RED:
            return True
    return False


def _join_lines(lines: List[String]) -> String:
    var out = String("")
    for i in range(len(lines)):
        if i > 0:
            out = out + String("\n")
        out = out + lines[i]
    return out


def _diff_editor(before: List[String], after: List[String]) -> Editor:
    """Build a review editor: buffer = after-file, baseline pinned to before
    (so git_change_lines marks added/modified), and the removed lines woven in
    as phantom rows — exactly how ``_review_arm_editor`` sets it up. Phantom
    syntax is left empty (real rows fall through to the SYN_IDENT baseline)."""
    var before_text = _join_lines(before)
    var ed = Editor(_join_lines(after))
    ed.review_mode = True
    ed.read_only = True
    ed.line_numbers = True
    ed.wrap_mode = WRAP_NONE
    ed.git_changes_visible = True
    ed.minimap_visible = False   # keep the right edge clean for assertions
    ed.set_git_head_text(before_text, True)
    ed.set_git_changes(diff_buffer_against_head(before_text, after))
    var n_after = len(after)
    var drows = build_diff_rows(before, after)
    var buckets = List[List[Int]]()
    for _ in range(n_after + 1):
        buckets.append(List[Int]())
    var ph_text = List[String]()
    var ph_hl = List[List[Highlight]]()
    var ph_emph = List[List[Tuple[Int, Int]]]()
    var emph_by_row = List[List[Tuple[Int, Int]]]()
    for _ in range(n_after):
        emph_by_row.append(List[Tuple[Int, Int]]())
    var emph = diff_row_emphasis(drows)
    var partner = diff_row_partner(drows)
    var anchor = List[Int]()
    for _ in range(len(drows)):
        anchor.append(0)
    var nxt = n_after
    for j in range(len(drows) - 1, -1, -1):
        if drows[j].kind == DIFF_ROW_REMOVED:
            if partner[j] >= 0:
                anchor[j] = drows[partner[j]].after_row
            else:
                anchor[j] = nxt
        else:
            nxt = drows[j].after_row
            anchor[j] = drows[j].after_row
    for j in range(len(drows)):
        if drows[j].kind == DIFF_ROW_REMOVED:
            var pi = len(ph_text)
            ph_text.append(drows[j].text)
            ph_hl.append(List[Highlight]())
            ph_emph.append(emph[j].copy())
            var a = anchor[j]
            if a < 0:
                a = 0
            if a > n_after:
                a = n_after
            buckets[a].append(pi)
        elif drows[j].after_row >= 0 and drows[j].after_row < n_after:
            emph_by_row[drows[j].after_row] = emph[j].copy()
    ed.diff_active = True
    ed.diff_phantom_text = ph_text^
    ed.diff_phantom_hl = ph_hl^
    ed.diff_phantom_buckets = buckets^
    ed.diff_phantom_emph = ph_emph^
    ed.diff_emph_by_row = emph_by_row^
    return ed^


def _local_changes_with_branches() -> LocalChanges:
    """A LocalChanges pointed at a non-repo directory with a synthetic
    two-branch list (``main`` current, ``feature-x`` not). Keeps the
    branch-pane key tests off any real repository."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    lc.branches.append(
        GitBranch(String("main"), String("aaa1111"), String("tip"), True, 0),
    )
    lc.branches.append(
        GitBranch(
            String("feature-x"), String("bbb2222"), String("wip"), False, 0,
        ),
    )
    lc.focus = _PANE_BRANCHES
    return lc^


def _local_changes_with_commit_url() -> LocalChanges:
    """A LocalChanges showing a synthetic ``git show`` whose message body
    carries a URL. ``_right_key`` is pinned to the commit-pane key so the
    paint / mouse paths' ``_ensure_right_panels`` treats the panel as
    already current instead of re-fetching from ``/tmp`` (not a repo) and
    wiping it."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    var registry = GrammarRegistry()
    lc._populate_commit_info(
        String(
            "commit abc1234\nAuthor: A <a@b.c>\n\n"
            "    Fix per https://example.com/issues/7\n"
        ),
        String(""),
        registry,
    )
    lc.focus = _PANE_COMMITS
    lc.last_sidebar_focus = _PANE_COMMITS
    lc._right_key = lc._focus_key()
    return lc^


def test_diff3_merge_clean_when_only_ours_changed() raises:
    """If theirs equals base, the merge takes ours unmodified."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nB\nc\n"))
    var theirs = _lines_from(String("a\nb\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    assert_equal(m.first_conflict_row, -1)
    assert_equal(len(m.lines), len(ours))
    for i in range(len(ours)):
        assert_equal(m.lines[i], ours[i])


def test_diff3_merge_clean_when_only_theirs_changed() raises:
    """Symmetric: if ours equals base, the merge takes theirs."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nb\nc\n"))
    var theirs = _lines_from(String("a\nB\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    for i in range(len(theirs)):
        assert_equal(m.lines[i], theirs[i])


def test_diff3_merge_clean_when_changes_disjoint() raises:
    """Both sides changed, but in different regions — auto-merges."""
    var base = _lines_from(String("a\nb\nc\nd\ne\n"))
    var ours = _lines_from(String("A\nb\nc\nd\ne\n"))
    var theirs = _lines_from(String("a\nb\nc\nd\nE\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    var want = _lines_from(String("A\nb\nc\nd\nE\n"))
    assert_equal(len(m.lines), len(want))
    for i in range(len(want)):
        assert_equal(m.lines[i], want[i])


def test_diff3_merge_identical_changes_dont_conflict() raises:
    """When both sides edit the same region to the same result, take it."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nB\nc\n"))
    var theirs = _lines_from(String("a\nB\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    var want = _lines_from(String("a\nB\nc\n"))
    for i in range(len(want)):
        assert_equal(m.lines[i], want[i])


def test_diff3_merge_conflict_when_both_edit_same_line() raises:
    """Same base line, two different changes → conflict markers."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nOURS\nc\n"))
    var theirs = _lines_from(String("a\nTHEIRS\nc\n"))
    var m = diff3_merge(base, ours, theirs,
        String("local"), String("disk"))
    assert_equal(m.conflicts, 1)
    assert_true(m.first_conflict_row >= 0)
    # The marker block must be present in order.
    var saw_open = False
    var saw_eq = False
    var saw_close = False
    var open_idx = -1
    var eq_idx = -1
    var close_idx = -1
    for i in range(len(m.lines)):
        if m.lines[i] == String("<<<<<<< local"):
            saw_open = True
            open_idx = i
        elif m.lines[i] == String("======="):
            saw_eq = True
            eq_idx = i
        elif m.lines[i] == String(">>>>>>> disk"):
            saw_close = True
            close_idx = i
    assert_true(saw_open)
    assert_true(saw_eq)
    assert_true(saw_close)
    assert_true(open_idx < eq_idx)
    assert_true(eq_idx < close_idx)
    assert_equal(m.first_conflict_row, open_idx)


def test_diff3_regions_all_stable_when_only_ours_changed() raises:
    """Only ours diverged from base → one STABLE region == ours, no
    conflicts."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nB\nc\n"))
    var theirs = _lines_from(String("a\nb\nc\n"))
    var regions = diff3_regions(base, ours, theirs)
    assert_equal(_conflict_count(regions), 0)
    # Reassemble the stable text and compare to ours.
    var got = List[String]()
    for i in range(len(regions)):
        assert_equal(regions[i].kind, REGION_STABLE)
        for j in range(len(regions[i].lines)):
            got.append(regions[i].lines[j])
    assert_equal(len(got), len(ours))
    for i in range(len(ours)):
        assert_equal(got[i], ours[i])


def test_diff3_regions_conflict_boundaries() raises:
    """Both sides edit the same middle line → STABLE [a], CONFLICT,
    STABLE [c, ''] (trailing empty line from the final newline)."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nOURS\nc\n"))
    var theirs = _lines_from(String("a\nTHEIRS\nc\n"))
    var regions = diff3_regions(base, ours, theirs)
    assert_equal(_conflict_count(regions), 1)
    assert_equal(len(regions), 3)
    # Leading stable run.
    assert_equal(regions[0].kind, REGION_STABLE)
    assert_equal(len(regions[0].lines), 1)
    assert_equal(regions[0].lines[0], String("a"))
    # Conflict carries both sides + base.
    assert_equal(regions[1].kind, REGION_CONFLICT)
    assert_equal(len(regions[1].ours_lines), 1)
    assert_equal(regions[1].ours_lines[0], String("OURS"))
    assert_equal(len(regions[1].theirs_lines), 1)
    assert_equal(regions[1].theirs_lines[0], String("THEIRS"))
    assert_equal(len(regions[1].base_lines), 1)
    assert_equal(regions[1].base_lines[0], String("b"))
    # Trailing stable run: "c" then the empty final line.
    assert_equal(regions[2].kind, REGION_STABLE)
    assert_equal(len(regions[2].lines), 2)
    assert_equal(regions[2].lines[0], String("c"))
    assert_equal(regions[2].lines[1], String(""))


def test_diff3_regions_multiple_conflicts() raises:
    """Two separated conflicts keep the stable text between them."""
    var base = _lines_from(String("a\nb\nc\nd\ne\n"))
    var ours = _lines_from(String("a\nB1\nc\nD1\ne\n"))
    var theirs = _lines_from(String("a\nB2\nc\nD2\ne\n"))
    var regions = diff3_regions(base, ours, theirs)
    assert_equal(_conflict_count(regions), 2)
    # Find the stable region sitting between the two conflicts and
    # confirm it preserved the shared "c" line.
    var saw_c_between = False
    var seen_first_conflict = False
    for i in range(len(regions)):
        if regions[i].kind == REGION_CONFLICT:
            if not seen_first_conflict:
                seen_first_conflict = True
            continue
        if seen_first_conflict:
            for j in range(len(regions[i].lines)):
                if regions[i].lines[j] == String("c"):
                    saw_c_between = True
    assert_true(saw_c_between)


def test_merge_view_resolved_text_all_local() raises:
    """Resolving every conflict to Local reproduces ours verbatim."""
    var mv = _single_conflict_view()
    assert_equal(mv.conflict_count, 1)
    for i in range(len(mv.states)):
        mv.states[i].choice = CHOICE_LOCAL
    assert_equal(mv.resolved_text(), String("a\nOURS\nc\n"))


def test_merge_view_resolved_text_all_disk() raises:
    """Resolving every conflict to Disk reproduces theirs verbatim."""
    var mv = _single_conflict_view()
    for i in range(len(mv.states)):
        mv.states[i].choice = CHOICE_DISK
    assert_equal(mv.resolved_text(), String("a\nTHEIRS\nc\n"))


def test_merge_view_resolved_text_both() raises:
    """Both keeps ours then theirs, surrounded by the stable lines."""
    var mv = _single_conflict_view()
    for i in range(len(mv.states)):
        mv.states[i].choice = CHOICE_BOTH
    assert_equal(mv.resolved_text(), String("a\nOURS\nTHEIRS\nc\n"))


def test_review_window_does_not_pollute_view_state() raises:
    """A review window is a transient buffer over a real path. It must not
    write its scroll/cursor into the saved view-state: doing so would make a
    later *normal* open of that file land at the review scroll instead of where
    the user actually left it. Normal windows still record; transient ones are
    skipped — pre-existing entries for their path stay untouched."""
    var d = Desktop()
    # A normal editor window for X at scroll 5.
    d.windows.add(Window.editor_window(
        String("x"), Rect(0, 1, 40, 12), String("x line\n"),
    ))
    d.windows.windows[0].editor.file_path = String("/tmp/tk_vs_x.txt")
    d.windows.windows[0].editor.scroll_y = 5
    # A transient (review) window for Y, scrolled far down, with a pre-existing
    # saved view-state at the top.
    d.windows.add(Window.editor_window(
        String("y"), Rect(0, 1, 40, 12), String("y line\n"),
    ))
    d.windows.windows[1].editor.file_path = String("/tmp/tk_vs_y.txt")
    d.windows.windows[1].editor.scroll_y = 99
    d.windows.windows[1]._transient = True
    d._view_states.append(StoredViewState(String("/tmp/tk_vs_y.txt"), 0, 0, 0, 0))
    # A second transient window for Z with no saved entry at all.
    d.windows.add(Window.editor_window(
        String("z"), Rect(0, 1, 40, 12), String("z line\n"),
    ))
    d.windows.windows[2].editor.file_path = String("/tmp/tk_vs_z.txt")
    d.windows.windows[2].editor.scroll_y = 42
    d.windows.windows[2]._transient = True

    d._refresh_view_states_from_windows()

    # Normal window recorded.
    var xi = d._find_view_state(String("/tmp/tk_vs_x.txt"))
    assert_true(xi >= 0)
    assert_equal(d._view_states[xi].scroll_y, 5)
    # Transient window's path: existing entry NOT overwritten by review's 99.
    var yi = d._find_view_state(String("/tmp/tk_vs_y.txt"))
    assert_true(yi >= 0)
    assert_equal(d._view_states[yi].scroll_y, 0)
    # Transient window with no prior entry: none is created.
    assert_equal(d._find_view_state(String("/tmp/tk_vs_z.txt")), -1)


def test_review_window_not_counted_as_document() raises:
    """The transient review window must not count toward the open-document cap
    (so hosting it can never evict one of the user's real windows) and must not
    itself be an eviction victim."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("normal"), Rect(0, 1, 40, 12), String("hi\n"),
    ))
    d.windows.windows[0].editor.file_path = String("/tmp/tk_doc_normal.txt")
    d.windows.add(Window.editor_window(
        String("review"), Rect(0, 1, 40, 12), String("hi\n"),
    ))
    d.windows.windows[1].editor.file_path = String("/tmp/tk_doc_review.txt")
    d.windows.windows[1]._transient = True
    assert_true(d._is_document_window(0))
    assert_false(d._is_document_window(1))


def test_review_teardown_saves_and_closes_editable_window() raises:
    """Exiting review must leave NO window behind and must not touch the
    scroll of the user's other windows. For an editable (unstaged) review the
    buffer is the live worktree file, so unsaved edits are flushed to disk on
    the way out — editing-in-review persists without a leftover window."""
    var path = _temp_path(String("_review_edit.txt"))
    assert_true(write_file(path, String("original\n")))
    var d = Desktop()
    # The user already had a normal window open at scroll 7.
    d.windows.add(Window.editor_window(
        String("keep"), Rect(0, 1, 40, 12), String("keep\n"),
    ))
    d.windows.windows[0].editor.file_path = String("/tmp/tk_keep.txt")
    d.windows.windows[0].editor.scroll_y = 7
    # Review hosts the worktree file in an editable transient window.
    d.windows.add(Window.from_file(String("edit"), Rect(0, 1, 40, 12), path))
    var ridx = len(d.windows.windows) - 1
    d.windows.windows[ridx]._transient = True
    d.windows.windows[ridx].editor.review_mode = True
    d.windows.windows[ridx].editor.read_only = False
    d._review_win_idx = ridx
    d._review_host_path = path
    # Edit in the review window.
    d.windows.focus_by_index(ridx)
    _ = d.windows.windows[ridx].editor.handle_key(_key(KEY_END), _VIEW)
    _ = d.windows.windows[ridx].editor.handle_key(
        _key(UInt32(ord("!"))), _VIEW,
    )
    assert_true(d.windows.windows[ridx].editor.dirty)

    var before_count = len(d.windows.windows)
    d._review_teardown()

    # No window left behind; review bookkeeping reset.
    assert_equal(len(d.windows.windows), before_count - 1)
    assert_equal(d._review_win_idx, -1)
    # The edit was flushed to disk.
    assert_equal(read_file(path), String("original!\n"))
    # The user's pre-existing window is untouched (scroll preserved).
    assert_equal(d.windows.windows[0].editor.scroll_y, 7)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_review_goto_change_saves_edits() raises:
    """Navigating to the next change in an editable (unstaged) review flushes
    the current file's edits to disk — editing in review behaves like an
    ordinary editor, persisting as the user moves on rather than only on exit."""
    var path = _temp_path(String("_review_nav_save.txt"))
    assert_true(write_file(path, String("original\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(String("edit"), Rect(0, 1, 40, 12), path))
    var ridx = len(d.windows.windows) - 1
    d.windows.windows[ridx]._transient = True
    d.windows.windows[ridx].editor.review_mode = True
    d.windows.windows[ridx].editor.read_only = False
    d._review_win_idx = ridx
    d._review_host_path = path
    d.windows.focus_by_index(ridx)
    _ = d.windows.windows[ridx].editor.handle_key(_key(KEY_END), _VIEW)
    _ = d.windows.windows[ridx].editor.handle_key(_key(UInt32(ord("!"))), _VIEW)
    assert_true(d.windows.windows[ridx].editor.dirty)

    # Navigate to the next change — edits must be written before moving on.
    d._review_goto_change(1)

    assert_false(d.windows.windows[ridx].editor.dirty)
    assert_equal(read_file(path), String("original!\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_review_progress_spans_whole_changeset() raises:
    """The review progress bar weights the *entire* changeset as one bar: each
    file's share is its added+removed line count and the within-file cumulative
    shares that exact basis, so the bar is monotonic and reaches 100% on the
    last change of the last file. Regression for two bugs: (1) numerator and
    denominator counted different things (added/modified-only vs added+removed),
    so the bar never hit 100% and lurched between files; (2) ``_reset_review``
    didn't clear ``file_changed_lines``, so a re-opened review accumulated stale
    per-file totals and the denominator ballooned."""
    var paths = List[String]()
    var befores = List[String]()
    var afters = List[String]()
    # File 0: one modified line + one added line (3 changed diff rows).
    paths.append(String("a.txt"))
    befores.append(String("a\nb\nc\n"))
    afters.append(String("a\nB\nc\nd\n"))
    # File 1: one pure deletion (1 changed diff row) — exercises the
    # deletions-counted path the gutter alone would miss.
    paths.append(String("b.txt"))
    befores.append(String("x\ny\nz\n"))
    afters.append(String("x\nz\n"))
    # File 2: two pure additions (2 changed diff rows).
    paths.append(String("c.txt"))
    befores.append(String(""))
    afters.append(String("1\n2\n"))

    var rv = ReviewMode()
    rv.build_from_pairs(paths, befores, afters)

    # Per-file totals: the denominator pieces.
    assert_equal(rv.file_changed_lines[0], 3)
    assert_equal(rv.file_changed_lines[1], 1)
    assert_equal(rv.file_changed_lines[2], 2)
    var den = rv.file_changed_lines[0] + rv.file_changed_lines[1] \
        + rv.file_changed_lines[2]
    assert_equal(den, 6)

    # For every file, the within-file cumulative is monotonic in the boundary
    # and "through end of file" (-1) equals that file's total exactly — the
    # property that makes numerator and denominator share one basis.
    var fi = 0
    while fi < 3:
        rv.cur_file = fi
        assert_equal(rv.changed_lines_through(-1), rv.file_changed_lines[fi])
        var prev = 0
        var b = 0
        while b <= 6:
            var cum = rv.changed_lines_through(b)
            assert_true(cum >= prev)               # never decreases
            assert_true(cum <= rv.file_changed_lines[fi])  # never overshoots
            prev = cum
            b += 1
        fi += 1

    # Walk the whole changeset forward (file 0 → 1 → 2, each finished at -1)
    # and assert the changeset-wide numerator never goes backward and tops out
    # at the denominator on the final change.
    var prior = 0
    var last_num = 0
    var f = 0
    while f < 3:
        rv.cur_file = f
        # Stepping through this file's boundaries, then finishing it (-1).
        var b2 = 0
        while b2 <= 6:
            var num = prior + rv.changed_lines_through(b2)
            assert_true(num >= last_num)
            assert_true(num <= den)
            last_num = num
            b2 += 1
        var done = prior + rv.changed_lines_through(-1)
        assert_true(done >= last_num)
        last_num = done
        prior += rv.file_changed_lines[f]
        f += 1
    assert_equal(last_num, den)  # 100% on the last change of the last file

    # Re-opening (rebuilding) the changeset must not accumulate stale per-file
    # totals — len(file_changed_lines) stays aligned with the file list.
    rv.build_from_pairs(paths, befores, afters)
    assert_equal(len(rv.file_changed_lines), len(rv.file_paths))
    assert_equal(len(rv.file_changed_lines), 3)


def test_git_gutter_no_diff_when_buffer_matches_crlf_head() raises:
    """Opening a CRLF file shouldn't make the git gutter flag every row
    as MODIFIED. The buffer strips trailing ``\\r``; the cached HEAD
    text must do the same on ingress so the diff aligns. Also covers
    the revert path: a revert of an unchanged row would otherwise
    splice raw ``\\r``-laden lines back into the buffer.
    """
    var ed = Editor(String(""))
    # Buffer matches HEAD modulo line endings (CRLF vs LF).
    ed.buffer = TextBuffer(String("alpha\nbeta\ngamma\n"))
    ed.set_git_head_text(String("alpha\r\nbeta\r\ngamma\r\n"), True)
    # The cached text must be normalized — no '\r' bytes left.
    var head_bytes = ed._git_head_text.as_bytes()
    for i in range(len(head_bytes)):
        assert_true(Int(head_bytes[i]) != 0x0D)
    # Every buffer row should diff as NONE.
    var diff = diff_buffer_against_head(
        ed._git_head_text, ed.buffer.lines.copy(),
    )
    for i in range(len(diff)):
        assert_equal(diff[i], GIT_CHANGE_NONE)


def test_gitignore_matches_directory_pattern() raises:
    var m = GitignoreMatcher.from_text(String("tvision/\n"))
    assert_true(m.ignored(String("tvision"), True))
    assert_false(m.ignored(String("tvision"), False))   # dir-only pattern
    assert_true(m.ignored(String("nested/tvision"), True))
    assert_false(m.ignored(String("examples"), True))


def test_gitignore_matches_glob_and_negate() raises:
    var m = GitignoreMatcher.from_text(
        String("# build artefacts\n*.o\n!keep.o\nbuild/\n")
    )
    assert_true(m.ignored(String("foo.o"), False))
    assert_true(m.ignored(String("a/b/c.o"), False))
    # The negation must override the earlier pattern.
    assert_false(m.ignored(String("keep.o"), False))
    assert_true(m.ignored(String("build"), True))
    assert_false(m.ignored(String("hello.mojo"), False))


def test_diff_grammar_paints_inserted_deleted_and_hunk_header() raises:
    """The bundled diff TextMate grammar maps ``-`` lines to the string
    color (red), ``+`` lines to the ident color (green), and the
    ``@@`` hunk header to the decorator color (cyan)."""
    var lines = _hl_lines(
        String("--- a/file.txt"),
        String("+++ b/file.txt"),
        String("@@ -1,3 +1,3 @@"),
        String(" context"),
        String("-removed"),
        String("+added"),
    )
    var hls = highlight_for_extension(String("diff"), lines)
    var saw_deleted = False
    var saw_inserted = False
    var saw_range = False
    for i in range(len(hls)):
        var a = hls[i].attr
        if hls[i].row == 4 and a == highlight_string_attr():
            saw_deleted = True
        if hls[i].row == 5 and a == highlight_ident_attr():
            saw_inserted = True
        if hls[i].row == 2 and a == highlight_decorator_attr():
            saw_range = True
    assert_true(saw_deleted)
    assert_true(saw_inserted)
    assert_true(saw_range)


def test_diff_identical_inputs_have_no_hunks() raises:
    """Two identical inputs produce only the file headers — no ``@@``."""
    var same = String("alpha\nbeta\ngamma\n")
    var out = unified_diff(same, same, String("a"), String("b"))
    var idx = out.find(String("@@"))
    assert_equal(idx, -1)


def test_diff_lines_pure_insert() raises:
    """Inserting one line in the middle: one delete-free, one insert op."""
    var a = List[String]()
    a.append(String("one"))
    a.append(String("three"))
    var b = List[String]()
    b.append(String("one"))
    b.append(String("two"))
    b.append(String("three"))
    var ops = diff_lines(a, b)
    var equals = 0
    var inserts = 0
    var deletes = 0
    for i in range(len(ops)):
        if ops[i].kind == 0:
            equals += 1
        elif ops[i].kind == 1:
            deletes += 1
        else:
            inserts += 1
    assert_equal(equals, 2)
    assert_equal(inserts, 1)
    assert_equal(deletes, 0)


def test_diff_lines_pure_delete() raises:
    """Removing one line: one delete op, no inserts."""
    var a = List[String]()
    a.append(String("one"))
    a.append(String("two"))
    a.append(String("three"))
    var b = List[String]()
    b.append(String("one"))
    b.append(String("three"))
    var ops = diff_lines(a, b)
    var equals = 0
    var inserts = 0
    var deletes = 0
    for i in range(len(ops)):
        if ops[i].kind == 0:
            equals += 1
        elif ops[i].kind == 1:
            deletes += 1
        else:
            inserts += 1
    assert_equal(equals, 2)
    assert_equal(inserts, 0)
    assert_equal(deletes, 1)


def test_diff_lines_replace_round_trips() raises:
    """Applying the edit script must turn ``a`` into ``b`` exactly."""
    var a = List[String]()
    a.append(String("the quick brown fox"))
    a.append(String("jumps over"))
    a.append(String("the lazy dog"))
    var b = List[String]()
    b.append(String("the quick red fox"))
    b.append(String("hops over"))
    b.append(String("the lazy dog"))
    b.append(String("end"))
    var ops = diff_lines(a, b)
    # Replay: equal/delete consume from a, insert produces from b. The
    # produced sequence (equal lines from a, plus inserts from b in order)
    # should match b exactly when the script is applied.
    var produced = List[String]()
    for i in range(len(ops)):
        if ops[i].kind == 0:
            produced.append(a[ops[i].a_index])
        elif ops[i].kind == 2:
            produced.append(b[ops[i].b_index])
    assert_equal(len(produced), len(b))
    for i in range(len(b)):
        assert_equal(produced[i], b[i])


def test_unified_diff_renders_hunk_header_and_marks() raises:
    """A simple replace: hunk header present, ``-old`` and ``+new`` lines
    emitted, surrounding equals appear with a leading space."""
    var a = String("alpha\nbeta\ngamma\n")
    var b = String("alpha\nBETA\ngamma\n")
    var out = unified_diff(a, b, String("old"), String("new"))
    assert_true(out.find(String("--- old")) >= 0)
    assert_true(out.find(String("+++ new")) >= 0)
    assert_true(out.find(String("@@")) >= 0)
    assert_true(out.find(String("-beta")) >= 0)
    assert_true(out.find(String("+BETA")) >= 0)
    assert_true(out.find(String(" alpha")) >= 0)
    assert_true(out.find(String(" gamma")) >= 0)


def test_git_blame_parses_two_line_porcelain() raises:
    """Two source lines, two distinct commits — parser must emit one
    ``BlameLine`` per line with the right short-SHA + author. Each
    record's first occurrence carries metadata; that author should
    propagate to ``BlameLine.author`` for that record.
    """
    var text = (
        String("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1\n")
        + String("author Alice\n")
        + String("author-mail <alice@example.com>\n")
        + String("summary first line\n")
        + String("\thello\n")
        + String("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2 2 1\n")
        + String("author Bob\n")
        + String("author-mail <bob@example.com>\n")
        + String("summary second line\n")
        + String("\tworld\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 2)
    assert_equal(lines[0].commit, String("aaaaaaaa"))
    assert_equal(lines[0].author, String("Alice"))
    assert_equal(lines[1].commit, String("bbbbbbbb"))
    assert_equal(lines[1].author, String("Bob"))


def test_git_blame_captures_commit_detail_metadata() raises:
    """The click-through popup needs more than sha + author: the full
    sha, the author mail, the authored timestamp + zone, and the subject
    line. ``author-mail`` must not be swallowed by the ``author`` key."""
    var sha = String("abcdef0123456789abcdef0123456789abcdef01")
    var text = (
        sha + String(" 1 1 1\n")
        + String("author Anders Hovmöller\n")
        + String("author-mail <anders@example.com>\n")
        + String("author-time 1755500000\n")
        + String("author-tz +0200\n")
        + String("committer Someone Else\n")
        + String("summary Release the reword editor's search cache\n")
        + String("filename foo.mojo\n")
        + String("\tvar x = 1\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 1)
    assert_equal(lines[0].sha, sha)
    assert_equal(lines[0].commit, String("abcdef01"))
    assert_equal(lines[0].author, String("Anders Hovmöller"))
    assert_equal(lines[0].author_mail, String("<anders@example.com>"))
    assert_equal(lines[0].author_time, 1755500000)
    assert_equal(lines[0].author_tz, String("+0200"))
    assert_equal(
        lines[0].summary,
        String("Release the reword editor's search cache"),
    )
    assert_false(lines[0].is_uncommitted())


def test_git_blame_propagates_full_metadata_across_a_group() raises:
    """A same-commit group emits metadata only on its first record; the
    timestamp and summary must reach the later lines too, or clicking the
    second line of a chunk would show a blank popup."""
    var sha = String("dddddddddddddddddddddddddddddddddddddddd")
    var text = (
        sha + String(" 1 1 2\n")
        + String("author Carol\n")
        + String("author-time 1700000000\n")
        + String("author-tz +0000\n")
        + String("summary one commit, two lines\n")
        + String("\tline one\n")
        + sha + String(" 2 2\n")
        + String("\tline two\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 2)
    assert_equal(lines[1].sha, sha)
    assert_equal(lines[1].author_time, 1700000000)
    assert_equal(lines[1].summary, String("one commit, two lines"))


def test_git_blame_time_formats_in_the_authors_zone() raises:
    """``format_commit_time`` renders the author's wall clock, not UTC —
    the same convention ``git log`` follows. 1700000000 is
    2023-11-14 22:13:20 UTC, so +0200 must read 00:13 the next day."""
    assert_equal(
        format_commit_time(1700000000, String("+0000")),
        String("2023-11-14 22:13 +0000"),
    )
    assert_equal(
        format_commit_time(1700000000, String("+0200")),
        String("2023-11-15 00:13 +0200"),
    )
    assert_equal(
        format_commit_time(1700000000, String("-0800")),
        String("2023-11-14 14:13 -0800"),
    )
    # Leap-year end-of-month, the classic off-by-one in civil-date math.
    assert_equal(
        format_commit_time(1709164800, String("+0000")),
        String("2024-02-29 00:00 +0000"),
    )
    # No timestamp (a record git gave us nothing for) renders as nothing
    # rather than as the epoch.
    assert_equal(format_commit_time(0, String("+0000")), String(""))
    assert_equal(tz_offset_seconds(String("-0930")), -34200)
    assert_equal(tz_offset_seconds(String("")), 0)


def test_git_blame_propagates_cached_author_for_repeated_sha() raises:
    """Lines 2..N of a same-commit group only carry ``<sha> <orig> <final>``
    + ``\\t<content>`` — no metadata. The parser must remember the
    author from the first occurrence so the repeated lines still get
    a real name (not "Not Committed Yet")."""
    var sha = String("cccccccccccccccccccccccccccccccccccccccc")
    var input = (
        sha + String(" 1 1 2\n")
        + String("author Carol\n")
        + String("summary same commit, two lines\n")
        + String("\tline one\n")
        + sha + String(" 2 2\n")
        + String("\tline two\n")
    )
    var lines = parse_blame_porcelain(input)
    assert_equal(len(lines), 2)
    assert_equal(lines[0].commit, String("cccccccc"))
    assert_equal(lines[0].author, String("Carol"))
    assert_equal(lines[1].commit, String("cccccccc"))
    assert_equal(lines[1].author, String("Carol"))


def test_git_blame_marks_uncommitted_with_zero_sha_and_placeholder() raises:
    """Git emits a 40-char zero SHA and ``Not Committed Yet`` author
    for lines that exist only in the worktree. The parser preserves
    that — tests downstream rendering doesn't crash on the all-zero
    short SHA."""
    var text = (
        String("0000000000000000000000000000000000000000 1 1 1\n")
        + String("author Not Committed Yet\n")
        + String("summary Version of foo from foo.txt\n")
        + String("\tfresh line\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 1)
    assert_equal(lines[0].commit, String("00000000"))
    assert_equal(lines[0].author, String("Not Committed Yet"))
    # ``is_uncommitted`` is what stops the popup spawning a ``git log`` for
    # an object that doesn't exist.
    assert_true(lines[0].is_uncommitted())


def test_diff_buffer_against_head_marks_added_and_modified() raises:
    """Diffing the editor's in-memory line list against the HEAD blob
    marks pure inserts as ADDED and inserts paired with deletes as
    MODIFIED. Lines untouched on either side land as NONE."""
    var head = (
        String("alpha\n")
        + String("beta\n")
        + String("gamma\n")
        + String("delta\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("BETA"))           # modified (replaces "beta")
    buffer.append(String("gamma"))
    buffer.append(String("inserted"))       # pure add
    buffer.append(String("delta"))
    buffer.append(String(""))               # trailing empty (was newline at EOF)
    var marks = diff_buffer_against_head(head, buffer)
    assert_equal(len(marks), len(buffer))
    assert_equal(marks[0], GIT_CHANGE_NONE)
    assert_equal(marks[1], GIT_CHANGE_MODIFIED)
    assert_equal(marks[2], GIT_CHANGE_NONE)
    assert_equal(marks[3], GIT_CHANGE_ADDED)
    assert_equal(marks[4], GIT_CHANGE_NONE)


def test_diff_modified_line_keeps_inserted_block_added() raises:
    """A comment block inserted just before a genuinely-modified line must
    mark the comment lines ADDED and the *changed* line MODIFIED — not the
    first inserted line. Regression: the delete pairs with the most similar
    insert (the changed call), not the top of the run."""
    var head = (
        String("    template = lookup()\n")
        + String("\n")
        + String("    chain = create(template, skip=True, **props)\n")
        + String("    return chain\n")
    )
    var buffer = List[String]()
    buffer.append(String("    template = lookup()"))
    buffer.append(String(""))
    buffer.append(String("    # explain why we force the flag"))      # inserted
    buffer.append(String("    # second comment line"))                # inserted
    buffer.append(String("    # third comment line"))                 # inserted
    buffer.append(String("    chain = create(template, skip=True, published=False, **props)"))  # modified
    buffer.append(String("    return chain"))                         # unchanged
    buffer.append(String(""))                                         # trailing
    var marks = diff_buffer_against_head(head, buffer)
    assert_equal(len(marks), len(buffer))
    assert_equal(marks[0], GIT_CHANGE_NONE)
    assert_equal(marks[1], GIT_CHANGE_NONE)
    # The inserted comment block stays green (ADDED), not red.
    assert_equal(marks[2], GIT_CHANGE_ADDED)
    assert_equal(marks[3], GIT_CHANGE_ADDED)
    assert_equal(marks[4], GIT_CHANGE_ADDED)
    # Only the line that actually changed is MODIFIED.
    assert_equal(marks[5], GIT_CHANGE_MODIFIED)
    assert_equal(marks[6], GIT_CHANGE_NONE)


def test_diff_buffer_marks_flags_pure_deletion_above() raises:
    """A pure deletion (HEAD lines removed with no replacement) leaves no
    buffer row to colour, so ``deleted_below`` flags the row immediately
    above the removed run — and that row's change status stays NONE."""
    var head = (
        String("alpha\n")
        + String("beta\n")
        + String("gamma\n")
        + String("delta\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("delta"))     # beta + gamma deleted between alpha and delta
    buffer.append(String(""))
    var marks = diff_buffer_marks(head, buffer)
    assert_equal(len(marks.statuses), len(buffer))
    assert_equal(len(marks.deleted_below), len(buffer))
    # No buffer row is added/modified — the change is a deletion only.
    assert_equal(marks.statuses[0], GIT_CHANGE_NONE)
    assert_equal(marks.statuses[1], GIT_CHANGE_NONE)
    # The underscore lands on row 0 (the line above the removed run).
    assert_true(marks.deleted_below[0])
    assert_true(not marks.deleted_below[1])


def test_diff_buffer_marks_modify_is_not_a_deletion() raises:
    """A delete paired with an insert is a MODIFIED line, not a deletion —
    no underscore marker for it."""
    var head = String("alpha\nbeta\ngamma\n")
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("BETA"))      # modified, not deleted
    buffer.append(String("gamma"))
    buffer.append(String(""))
    var marks = diff_buffer_marks(head, buffer)
    assert_equal(marks.statuses[1], GIT_CHANGE_MODIFIED)
    for i in range(len(marks.deleted_below)):
        assert_true(not marks.deleted_below[i])


def test_diff_row_line_label_basics() raises:
    """A row's gutter label is its 1-based after-file number, or empty for a
    removed row (which has no line number)."""
    assert_equal(diff_row_line_label(DiffRow(0, String("x"), DIFF_ROW_CONTEXT, 0)), String("1"))
    assert_equal(diff_row_line_label(DiffRow(41, String("x"), DIFF_ROW_ADDED, 41)), String("42"))
    assert_equal(diff_row_line_label(DiffRow(-1, String("x"), DIFF_ROW_REMOVED, 7)), String(""))


def test_diff_rows_removed_lines_have_no_line_number() raises:
    """A modified line → a removed row (old text, NO line number) then an
    added row (new text, with its after-file number)."""
    var before = _slist(String("a"), String("old line"), String("c"))
    var after = _slist(String("a"), String("new line"), String("c"))
    var rows = build_diff_rows(before, after)
    assert_equal(len(rows), 4)
    assert_equal(rows[0].kind, DIFF_ROW_CONTEXT)
    assert_equal(diff_row_line_label(rows[0]), String("1"))
    assert_equal(rows[1].kind, DIFF_ROW_REMOVED)
    assert_equal(rows[1].after_row, -1)
    assert_equal(rows[1].text, String("old line"))
    assert_equal(diff_row_line_label(rows[1]), String(""))
    assert_equal(rows[2].kind, DIFF_ROW_ADDED)
    assert_equal(rows[2].text, String("new line"))
    assert_equal(diff_row_line_label(rows[2]), String("2"))
    assert_equal(diff_row_line_label(rows[3]), String("3"))


def test_diff_rows_pure_insertion_all_numbered() raises:
    """Pure insertions are ADDED rows — they DO have after-file numbers; no
    removed rows, so the numbering is a clean 1..N."""
    var before = _slist(String("a"), String("b"))
    var after = _slist(String("a"), String("x"), String("y"), String("b"))
    var rows = build_diff_rows(before, after)
    assert_equal(len(rows), 4)
    for i in range(len(rows)):
        assert_true(rows[i].kind != DIFF_ROW_REMOVED)
    assert_equal(diff_row_line_label(rows[1]), String("2"))
    assert_equal(diff_row_line_label(rows[2]), String("3"))


def test_diff_rows_multiline_removal_numbers_skip_removed() raises:
    """Deletions become removed rows with no numbers; context numbers stay
    correct across the un-numbered gap."""
    var before = _slist(String("a"), String("gone1"), String("gone2"), String("b"))
    var after = _slist(String("a"), String("b"))
    var rows = build_diff_rows(before, after)
    assert_equal(len(rows), 4)
    assert_equal(diff_row_line_label(rows[0]), String("1"))
    assert_equal(rows[1].kind, DIFF_ROW_REMOVED)
    assert_equal(diff_row_line_label(rows[1]), String(""))
    assert_equal(rows[2].kind, DIFF_ROW_REMOVED)
    assert_equal(diff_row_line_label(rows[2]), String(""))
    assert_equal(diff_row_line_label(rows[3]), String("2"))


def test_diff_rows_inserted_block_before_modified_line() raises:
    """A comment block inserted before a modified line: comments are added
    (numbered), only the old modified line is un-numbered."""
    var before = _slist(
        String("    template = lookup()"),
        String(""),
        String("    chain = create(template, skip=True, **props)"),
        String("    return chain"),
    )
    var after = _slist(
        String("    template = lookup()"),
        String(""),
        String("    # explain"),
        String("    # second"),
        String("    # third"),
        String("    chain = create(template, skip=True, published=False, **props)"),
        String("    return chain"),
    )
    var rows = build_diff_rows(before, after)
    assert_equal(len(rows), 8)
    assert_equal(diff_row_line_label(rows[0]), String("1"))
    assert_equal(diff_row_line_label(rows[1]), String("2"))
    assert_equal(rows[2].kind, DIFF_ROW_REMOVED)
    assert_equal(diff_row_line_label(rows[2]), String(""))
    assert_equal(rows[3].kind, DIFF_ROW_ADDED)
    assert_equal(diff_row_line_label(rows[3]), String("3"))
    assert_equal(diff_row_line_label(rows[7]), String("7"))


def test_diff_view_renders_removed_rows_without_line_numbers() raises:
    """End-to-end through the NORMAL editor paint: a modified line shows the
    old version as a phantom removed row (present, NO line number, red bar)
    and the new version as a numbered added row. Context rows keep numbers."""
    var ed = _diff_editor(
        _slist(String("alpha"), String("old middle"), String("omega")),
        _slist(String("alpha"), String("new middle"), String("omega")),
    )
    var w = 60
    var h = 10
    var c = Canvas(w, h)
    ed.paint(c, Rect(0, 0, w, h), False)
    var gx = ed._total_gutter()
    # Rows: 0 alpha(ctx,#), 1 old(phantom,no#), 2 new(added,#), 3 omega(ctx,#).
    assert_equal(_diff_row_text(c, 0, gx, w), String("alpha"))
    assert_true(_diff_gutter_has_digit(c, 0, gx))
    assert_equal(_diff_row_text(c, 1, gx, w), String("old middle"))
    assert_true(not _diff_gutter_has_digit(c, 1, gx))
    assert_true(_diff_row_has_red_bar(c, 1, gx))
    assert_equal(_diff_row_text(c, 2, gx, w), String("new middle"))
    assert_true(_diff_gutter_has_digit(c, 2, gx))
    assert_equal(_diff_row_text(c, 3, gx, w), String("omega"))
    assert_true(_diff_gutter_has_digit(c, 3, gx))


def test_diff_view_modified_line_shows_old_removed_and_new_added() raises:
    """The porting.py shape: a comment inserted before a modified line. The
    old version of the changed line is matched to its new version (not the
    comment), so the phantom removed row renders directly above the new line —
    the comment floats above the pair, keeping old/new adjacent."""
    var ed = _diff_editor(
        _slist(
            String("    template = lookup()"),
            String("    chain = create(template, skip=True, **props)"),
            String("    return chain"),
        ),
        _slist(
            String("    template = lookup()"),
            String("    # force the flag"),
            String("    chain = create(template, skip=True, published=False, **props)"),
            String("    return chain"),
        ),
    )
    var w = 80
    var h = 12
    var c = Canvas(w, h)
    ed.paint(c, Rect(0, 0, w, h), False)
    var gx = ed._total_gutter()
    # Rows: 0 template(#), 1 comment(#), 2 old-chain(phantom,no#), 3 new-chain(#),
    #       4 return(#). The removed line sits right above its matched new line.
    assert_true(_diff_gutter_has_digit(c, 0, gx))
    assert_equal(_diff_row_text(c, 1, gx, w), String("    # force the flag"))
    assert_true(_diff_gutter_has_digit(c, 1, gx))
    assert_equal(
        _diff_row_text(c, 2, gx, w),
        String("    chain = create(template, skip=True, **props)"),
    )
    assert_true(not _diff_gutter_has_digit(c, 2, gx))
    assert_true(_diff_row_has_red_bar(c, 2, gx))
    assert_equal(
        _diff_row_text(c, 3, gx, w),
        String("    chain = create(template, skip=True, published=False, **props)"),
    )
    assert_true(_diff_gutter_has_digit(c, 3, gx))


def test_diff_view_phantom_syntax_overlay() raises:
    """A removed (phantom) row carries its own before-file syntax: setting a
    keyword span on the phantom recolours those cells while keeping the red
    wash background."""
    var ed = _diff_editor(
        _slist(String("keep"), String("keyword gone")),
        _slist(String("keep")),
    )
    # The single phantom is "keyword gone"; colour its first 7 bytes as keyword.
    var hl = List[Highlight]()
    hl.append(Highlight(0, 0, 7, Attr(SYN_KEYWORD, EDITOR_BG)))
    ed.diff_phantom_hl = List[List[Highlight]]()
    ed.diff_phantom_hl.append(hl^)
    var w = 60
    var h = 8
    var c = Canvas(w, h)
    ed.paint(c, Rect(0, 0, w, h), False)
    var gx = ed._total_gutter()
    # Rows: 0 keep(ctx), 1 "keyword gone"(phantom). Find the phantom row.
    assert_equal(_diff_row_text(c, 1, gx, w), String("keyword gone"))
    assert_equal(c.get(gx, 1).attr.fg, SYN_KEYWORD)        # 'k'
    assert_equal(c.get(gx + 6, 1).attr.fg, SYN_KEYWORD)    # 'd'
    assert_equal(c.get(gx, 1).attr.bg, DIFF_REM_BG)        # red wash kept


def test_diff_view_unhighlighted_text_uses_identifier_color() raises:
    """Real rows with no syntax spans render in the SYN_IDENT baseline (green),
    matching the normal editor — not white. Regression for the white-variable bug."""
    var ed = _diff_editor(
        _slist(String("keep")),
        _slist(String("keep"), String("foo bar baz")),
    )
    var w = 60
    var h = 8
    var c = Canvas(w, h)
    ed.paint(c, Rect(0, 0, w, h), False)
    var gx = ed._total_gutter()
    # Row 1 is the added "foo bar baz" (a real buffer row, no highlights).
    assert_equal(_diff_row_text(c, 1, gx, w), String("foo bar baz"))
    assert_equal(c.get(gx, 1).attr.fg, SYN_IDENT)
    assert_equal(c.get(gx + 4, 1).attr.fg, SYN_IDENT)


def test_diff_view_dims_unchanged_context_lines() raises:
    """Unchanged context rows are faded (fg+bg blended toward black) so the
    changed rows pop — turning their colours truecolor. Regression guard."""
    var ed = _diff_editor(
        _slist(String("ctx"), String("old")),
        _slist(String("ctx"), String("new")),
    )
    ed.review_palette = built_in_themes()[0].palette.copy()
    var w = 40
    var h = 8
    var c = Canvas(w, h)
    ed.paint(c, Rect(0, 0, w, h), False)
    var gx = ed._total_gutter()
    # Row 0 is context "ctx": dimmed → truecolor fg + bg.
    var cx = c.get(gx, 0).attr
    assert_true((cx.color_mode & FG_TRUECOLOR) != 0)
    assert_true((cx.color_mode & BG_TRUECOLOR) != 0)


def test_diff_row_emphasis_marks_changed_spans() raises:
    """The character-level diff of a modified line marks exactly the changed
    byte span on each side ('foo bar' → 'foo baz': just the last char)."""
    var rows = build_diff_rows(_slist(String("foo bar")), _slist(String("foo baz")))
    # rows: [removed "foo bar", added "foo baz"].
    var emph = diff_row_emphasis(rows)
    assert_equal(rows[0].kind, DIFF_ROW_REMOVED)
    assert_equal(len(emph[0]), 1)
    assert_equal(emph[0][0][0], 6)     # 'r' at byte 6
    assert_equal(emph[0][0][1], 7)
    assert_equal(rows[1].kind, DIFF_ROW_ADDED)
    assert_equal(len(emph[1]), 1)
    assert_equal(emph[1][0][0], 6)     # 'z' at byte 6
    assert_equal(emph[1][0][1], 7)
    # A pure direct check of the byte-range helper too.
    var oo = List[Tuple[Int, Int]]()
    var nn = List[Tuple[Int, Int]]()
    intraline_ranges(String("abcXef"), String("abcYef"), oo, nn)
    assert_equal(len(oo), 1)
    assert_equal(oo[0][0], 3)
    assert_equal(oo[0][1], 4)
    assert_equal(nn[0][0], 3)
    assert_equal(nn[0][1], 4)


def test_diff_row_emphasis_pairs_by_similarity() raises:
    """When a comment is inserted above a modified line, the change run is
    [removed code, added comment, added code]. Positional pairing would
    char-diff the code against the comment; similarity pairing matches the
    removed code with the *added code*, so emphasis lands on the real change
    and the comment stays unmarked."""
    var before = List[String]()
    before.append(String("x = foo(a, b)"))
    var after = List[String]()
    after.append(String("# explanatory comment"))
    after.append(String("x = foo(a, c)"))
    var rows = build_diff_rows(before, after)
    # rows: [removed "x = foo(a, b)", added "# ...", added "x = foo(a, c)"].
    assert_equal(rows[0].kind, DIFF_ROW_REMOVED)
    assert_equal(rows[1].kind, DIFF_ROW_ADDED)
    assert_equal(rows[2].kind, DIFF_ROW_ADDED)
    var emph = diff_row_emphasis(rows)
    # Removed code paired with added code: 'b'→'c' at byte 11 on each side.
    assert_equal(len(emph[0]), 1)
    assert_equal(emph[0][0][0], 11)
    assert_equal(emph[0][0][1], 12)
    # The comment is not char-diffed against anything.
    assert_equal(len(emph[1]), 0)
    assert_equal(len(emph[2]), 1)
    assert_equal(emph[2][0][0], 11)
    assert_equal(emph[2][0][1], 12)


def test_diff_row_partner_matches_across_inserted_comment() raises:
    """A comment inserted above a modified line: the removed code row matches
    the added code row (not the comment), and they point at each other; the
    comment is unmatched."""
    var before = List[String]()
    before.append(String("x = foo(a, b)"))
    var after = List[String]()
    after.append(String("# explanatory comment"))
    after.append(String("x = foo(a, c)"))
    var rows = build_diff_rows(before, after)
    # rows: [0 removed code, 1 added comment, 2 added code].
    var partner = diff_row_partner(rows)
    assert_equal(partner[0], 2)     # removed code → added code
    assert_equal(partner[2], 0)     # and back
    assert_equal(partner[1], -1)    # comment unmatched


def test_diff_row_partner_skips_dissimilar_in_restructure() raises:
    """A restructured block (a list literal rewritten as a dict) used to
    scatter: every removed line shares its deep indentation with every added
    line, so the similarity matcher paired unrelated lines and yanked the old
    rows above mismatched new ones. Now leading whitespace is ignored and weak
    pairs are refused, so only the genuine line modifications pair — the rest
    stays a clean removed-then-added block.

    Mirrors the ``auto__include=[...]`` → ``auto__include=dict(...)`` case."""
    var before = List[String]()
    before.append(String("    auto__include=["))
    before.append(String("        'project',"))
    before.append(String("        'rating',"))
    before.append(String("    ],"))
    before.append(String("        project_customer_journey=dict("))
    var after = List[String]()
    after.append(String("    auto__include=dict("))
    after.append(String("        project=dict(filter__include=True),"))
    after.append(String("        rating={},"))
    after.append(String("        project__customer_journey=dict("))
    var rows = build_diff_rows(before, after)
    # No line is unchanged, so it's one change run: 5 removed rows (before
    # order) then 4 added rows (after order).
    assert_equal(len(rows), 9)
    assert_equal(rows[0].kind, DIFF_ROW_REMOVED)
    assert_equal(rows[0].text, String("    auto__include=["))
    assert_equal(rows[4].text, String("        project_customer_journey=dict("))
    assert_equal(rows[5].kind, DIFF_ROW_ADDED)
    assert_equal(rows[5].text, String("    auto__include=dict("))
    assert_equal(rows[8].text, String("        project__customer_journey=dict("))
    var partner = diff_row_partner(rows)
    # Genuine modifications still pair (and point back at each other):
    # the ``project_customer_journey`` rename ...
    assert_equal(partner[4], 8)
    assert_equal(partner[8], 4)
    # ... and ``auto__include=`` changing its value type.
    assert_equal(partner[0], 5)
    assert_equal(partner[5], 0)
    # Unrelated rows must NOT be dragged onto dict-construction lines:
    # ``'project',`` (row 1) and the closing ``],`` (row 3) stay unmatched.
    assert_equal(partner[1], -1)
    assert_equal(partner[3], -1)


def test_diff_view_intraline_emphasis_render() raises:
    """The rendered diff emphasises the changed characters: a stronger green
    on the new line's changed bytes and a stronger red on the old (phantom)
    line's, while the unchanged parts keep the faint wash."""
    var ed = _diff_editor(_slist(String("foo bar")), _slist(String("foo baz")))
    var w = 40
    var h = 6
    var c = Canvas(w, h)
    ed.paint(c, Rect(0, 0, w, h), False)
    var gx = ed._total_gutter()
    # Row 0 = phantom "foo bar": 'r' (byte 6) gets the strong red, 'f' the wash.
    assert_equal(_diff_row_text(c, 0, gx, w), String("foo bar"))
    assert_equal(c.get(gx, 0).attr.bg, DIFF_REM_BG)
    assert_equal(c.get(gx + 6, 0).attr.bg, DIFF_REM_EMPH)
    # Row 1 = added "foo baz": 'z' (byte 6) strong green, 'f' the wash.
    assert_equal(_diff_row_text(c, 1, gx, w), String("foo baz"))
    assert_equal(c.get(gx, 1).attr.bg, DIFF_ADD_BG)
    assert_equal(c.get(gx + 6, 1).attr.bg, DIFF_ADD_EMPH)


def test_goto_change_chunk_navigates_and_builds_preview() raises:
    """Ctrl+Shift+Down/Up walks between change chunks, parking the caret
    at each chunk start and stamping a ``pending_git_revert`` carrying the
    old (HEAD) lines for the inline-diff preview."""
    var head = String("a\nb\nc\nd\ne\nf\n")
    var ed = Editor(String("a\nB\nc\nd\nE\nf\n"))
    ed.git_changes_visible = True
    ed.set_git_head_text(head, True)
    var marks = diff_buffer_against_head(head, ed.buffer.lines)
    ed.set_git_changes(marks^)
    var view = Rect(0, 0, 80, 24)
    # Two modified chunks: row 1 ("B") and row 4 ("E").
    assert_true(ed.goto_change_chunk(1, view))
    assert_equal(ed.selections[0].row, 1)
    var req1 = ed.consume_git_revert_request()
    assert_true(Bool(req1))
    var r1 = req1.value().copy()
    assert_equal(r1.row, 1)
    assert_equal(r1.new_count, 1)
    assert_equal(len(r1.head_lines), 1)
    assert_equal(r1.head_lines[0], String("b"))
    # Next chunk.
    assert_true(ed.goto_change_chunk(1, view))
    assert_equal(ed.selections[0].row, 4)
    var req2 = ed.consume_git_revert_request()
    assert_true(Bool(req2))
    assert_equal(req2.value().head_lines[0], String("e"))
    # No chunk past the last one.
    assert_true(not ed.goto_change_chunk(1, view))
    # Walk back up.
    assert_true(ed.goto_change_chunk(-1, view))
    assert_equal(ed.selections[0].row, 1)


def test_revert_chunk_at_cursor_restores_head() raises:
    """Cmd+Alt+Z reverts the chunk under the caret straight to HEAD."""
    var head = String("a\nb\nc\n")
    var ed = Editor(String("a\nBETA\nc\n"))
    ed.git_changes_visible = True
    ed.set_git_head_text(head, True)
    var marks = diff_buffer_against_head(head, ed.buffer.lines)
    ed.set_git_changes(marks^)
    ed.move_to(1, 0, False)
    assert_true(ed.revert_chunk_at_cursor())
    assert_equal(ed.buffer.line(1), String("b"))
    # A caret on an unchanged line has nothing to revert.
    var ed2 = Editor(String("a\nb\nc\n"))
    ed2.set_git_head_text(String("a\nb\nc\n"), True)
    var marks2 = diff_buffer_against_head(String("a\nb\nc\n"), ed2.buffer.lines)
    ed2.set_git_changes(marks2^)
    ed2.move_to(0, 0, False)
    assert_true(not ed2.revert_chunk_at_cursor())


def test_local_changes_open_records_status_when_clean() raises:
    """Pointing the widget at ``/tmp`` (not a git repo) makes
    ``compute_local_changes`` return empty; ``open`` should record a
    user-readable status string and end up with no files."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    assert_true(lc.active)
    assert_equal(len(lc.files), 0)
    assert_true(len(lc.status_message.as_bytes()) > 0)
    lc.close()
    assert_false(lc.active)


def test_local_changes_space_on_branch_checks_it_out() raises:
    """Space on a non-current branch row spawns ``git checkout <name>``
    through the async runner (recorded as ``_GITOP_CHECKOUT``) rather
    than falling through to the files-pane staging path."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 1                       # feature-x
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(Event.key_event(KEY_SPACE), screen, registry)
    assert_equal(lc._git_op, _GITOP_CHECKOUT)
    assert_true(lc.git_runner.is_active())
    # Drain the child so the test doesn't leave a zombie behind. The
    # checkout fails immediately (``/tmp`` isn't a repo); tick() is
    # non-blocking, so spin until it reaps.
    for _ in range(2000000):
        if lc._git_op == _GITOP_NONE:
            break
        lc.tick()
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_false(lc.git_runner.is_active())


def test_local_changes_space_on_current_branch_is_a_noop() raises:
    """Space on the already-checked-out row reports and spawns nothing —
    no point paying for a git invocation to land where we already are.
    "Already on X" is a success, so it goes to the non-modal sub-title
    flash rather than a box the user has to dismiss."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 0                       # main, is_current
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(Event.key_event(KEY_SPACE), screen, registry)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_false(lc.git_runner.is_active())
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_true(_contains(lc.flash_message, String("main")))


def test_local_changes_commit_message_url_is_underlined() raises:
    """A URL in a commit message paints as an underlined blue link so it
    reads as clickable. The rest of the message row keeps the plain info
    colour."""
    var lc = _local_changes_with_commit_url()
    var registry = GrammarRegistry()
    var screen = Rect(0, 0, 200, 40)
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    var bounds = lc._panel_rect(screen)
    # Message body is row 3 of the ``git show`` text; the info panel's
    # body starts one row below its header.
    var y = lc._list_top(bounds) + 1 + 3
    var x0 = lc._diff_left(bounds) + display_columns(String("    Fix per "))
    var link = canvas.get(x0, y)
    assert_equal(link.glyph, String("h"))
    assert_true((link.attr.style & STYLE_UNDERLINE) != 0)
    assert_equal(link.attr.fg, LIGHT_BLUE)
    # Last character of the URL is underlined; the space before it isn't.
    var last = canvas.get(
        x0 + display_columns(String("https://example.com/issues/7")) - 1, y,
    )
    assert_equal(last.glyph, String("7"))
    assert_true((last.attr.style & STYLE_UNDERLINE) != 0)
    assert_true((canvas.get(x0 - 1, y).attr.style & STYLE_UNDERLINE) == 0)


def test_local_changes_click_on_commit_message_url_opens_browser() raises:
    """Clicking the URL span queues it for ``open_url`` and leaves the
    line cursor alone; clicking one column short of it is an ordinary
    cursor move."""
    var lc = _local_changes_with_commit_url()
    var registry = GrammarRegistry()
    var screen = Rect(0, 0, 200, 40)
    var bounds = lc._panel_rect(screen)
    var y = lc._list_top(bounds) + 1 + 3
    var x0 = lc._diff_left(bounds) + display_columns(String("    Fix per "))
    _ = lc.handle_mouse(
        Event.mouse_event(Point(x0 + 4, y), MOUSE_BUTTON_LEFT, True, False),
        screen, registry,
    )
    assert_equal(
        lc.consume_open_url(), String("https://example.com/issues/7"),
    )
    # Drained by the consume — the desktop must not re-open it next frame.
    assert_equal(len(lc.consume_open_url().as_bytes()), 0)
    assert_equal(lc.info.cursor, 0)
    # Just left of the link: no URL, cursor moves onto the row.
    _ = lc.handle_mouse(
        Event.mouse_event(Point(x0 - 1, y), MOUSE_BUTTON_LEFT, True, False),
        screen, registry,
    )
    assert_equal(len(lc.consume_open_url().as_bytes()), 0)
    assert_equal(lc.info.cursor, 3)


def test_local_changes_sidebar_splitter_drag_resizes_right_pane() raises:
    """A press on the vertical ``│`` splitter followed by a drag-motion
    must update ``sidebar_width_user``, which is what shrinks the
    sidebar and grows the right-side window. Verifies the artificial
    16/56-cell caps are gone — the user can drag the splitter freely
    down to a 1-cell sidebar (so the right side fills nearly the whole
    window) or out to ``screen.width() - 2``."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    var screen = Rect(0, 0, 200, 40)
    var registry = GrammarRegistry()
    var default_w = 56
    # Drag from auto-default to a narrow sidebar.
    _ = lc.handle_mouse(
        Event.mouse_event(
            Point(default_w, 10), MOUSE_BUTTON_LEFT, True, False,
        ),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(30, 10), MOUSE_BUTTON_LEFT, True, True),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(30, 10), MOUSE_BUTTON_LEFT, False, False),
        screen, registry,
    )
    assert_equal(lc.sidebar_width_user, 30)
    # Drag past the old 16-cell minimum — the user is free to crush
    # the sidebar to 1 cell.
    _ = lc.handle_mouse(
        Event.mouse_event(Point(30, 10), MOUSE_BUTTON_LEFT, True, False),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(2, 10), MOUSE_BUTTON_LEFT, True, True),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(2, 10), MOUSE_BUTTON_LEFT, False, False),
        screen, registry,
    )
    assert_equal(lc.sidebar_width_user, 2)
    # And drag past the old 56-cell maximum — the user can also push
    # the sidebar out to almost the entire width.
    _ = lc.handle_mouse(
        Event.mouse_event(Point(2, 10), MOUSE_BUTTON_LEFT, True, False),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(180, 10), MOUSE_BUTTON_LEFT, True, True),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(180, 10), MOUSE_BUTTON_LEFT, False, False),
        screen, registry,
    )
    assert_equal(lc.sidebar_width_user, 180)
    lc.close()


def test_git_state_mtimes_zero_for_non_repo() raises:
    """``git_state_mtimes`` returns zeros for a directory that isn't a
    git repo, and for the empty-string root. The desktop's polling
    loop reads the zero baseline as "no comparison yet" and skips
    invalidation, so this is the contract that keeps non-git projects
    from getting spurious refreshes."""
    var dir = _temp_path(String("_git_mtime_nogit"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var mt = git_state_mtimes(dir)
    assert_true(mt.is_zero())
    var empty = git_state_mtimes(String(""))
    assert_true(empty.is_zero())
    _rm_rf(dir)


def test_git_state_mtimes_nonzero_after_init_commit() raises:
    """A fresh ``git init`` + commit produces a nonzero fingerprint (HEAD,
    index, and reflog) — the polling loop's "something changed" comparison
    only fires once a real baseline exists — and a second commit changes it."""
    var dir = _temp_path(String("_git_mtime_init"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    var rc = _run_git(dir, init_args^)
    if rc != 0:
        # No git on PATH — skip silently, matching the staging test.
        _rm_rf(dir)
        return
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    var f = join_path(dir, String("a.txt"))
    assert_true(write_file(f, String("hello\n")))
    var add = List[String]()
    add.append(String("add"))
    add.append(String("a.txt"))
    _ = _run_git(dir, add^)
    var commit = List[String]()
    commit.append(String("commit"))
    commit.append(String("-q"))
    commit.append(String("-m"))
    commit.append(String("init"))
    _ = _run_git(dir, commit^)
    var mt = git_state_mtimes(dir)
    assert_true(mt.head_mtime != Int64(0))
    assert_true(mt.index_mtime != Int64(0))
    # The HEAD reflog exists after the first commit — it's the field that
    # actually moves on a *subsequent* commit (the ``.git/HEAD`` symref does
    # not), so the poll relies on it to notice commits.
    assert_true(mt.reflog_mtime != Int64(0))
    assert_true(mt.reflog_size != Int64(0))
    # equals() returns True for itself, False for a zero baseline.
    assert_true(mt.equals(mt))
    var zero = GitStateMtimes.zero()
    assert_true(not mt.equals(zero))
    assert_true(zero.is_zero())
    # Regression: a second commit must change the fingerprint even though
    # ``.git/HEAD`` (the symref) never moves. The reflog grows by one entry,
    # so size alone flips ``equals`` — this is what makes the gutter notice a
    # commit made in the in-app terminal (no host focus-gain to force a
    # refresh).
    assert_true(write_file(f, String("hello\nworld\n")))
    var add2 = List[String]()
    add2.append(String("add"))
    add2.append(String("a.txt"))
    _ = _run_git(dir, add2^)
    var commit2 = List[String]()
    commit2.append(String("commit"))
    commit2.append(String("-q"))
    commit2.append(String("-m"))
    commit2.append(String("second"))
    _ = _run_git(dir, commit2^)
    var mt2 = git_state_mtimes(dir)
    assert_true(not mt2.equals(mt))
    assert_true(mt2.reflog_size != mt.reflog_size)
    _rm_rf(dir)


def test_stage_unstage_round_trip_against_real_git() raises:
    """End-to-end: spin up a throwaway git repo, modify a file, walk it
    through stage_file → fetch_git_status → unstage_file. Asserts the
    porcelain X/Y columns flip the way we expect, which is the contract
    the LocalChanges UI is built on. Skipped silently when ``git`` is
    missing or ``git init`` fails (e.g., a build environment without
    git on PATH)."""
    var dir = _temp_path(String("_stage_int"))
    _rm_rf(dir)
    _ensure_dir(dir)
    # ``git init -q`` so we don't pollute test output. Pass ``-b main``
    # to avoid the default-branch warning that newer git emits — we
    # don't care which branch, just that the call succeeds.
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    var rc = _run_git(dir, init_args^)
    if rc != 0:
        # No git available — skip silently.
        _rm_rf(dir)
        return
    # Configure user so commit doesn't fail; ``-c`` per-invocation would
    # be cleaner but we'd have to plumb it through every helper call.
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    # Initial commit of a known-content file.
    var f = join_path(dir, String("a.txt"))
    assert_true(write_file(f, String("alpha\nbeta\ngamma\n")))
    var add_initial = List[String]()
    add_initial.append(String("add"))
    add_initial.append(String("a.txt"))
    _ = _run_git(dir, add_initial^)
    var commit_args = List[String]()
    commit_args.append(String("commit"))
    commit_args.append(String("-q"))
    commit_args.append(String("-m"))
    commit_args.append(String("init"))
    _ = _run_git(dir, commit_args^)
    # Modify the file.
    assert_true(write_file(f, String("alpha\nbeta-modified\ngamma\n")))
    # Status should show ' M a.txt'.
    var statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x20)
    assert_equal(Int(statuses[0].worktree), 0x4D)    # 'M'
    assert_equal(statuses[0].path, String("a.txt"))
    # Stage the whole file.
    assert_true(stage_file(dir, String("a.txt")))
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x4D)      # 'M'
    assert_equal(Int(statuses[0].worktree), 0x20)
    # Unstage and verify it bounces back.
    assert_true(unstage_file(dir, String("a.txt")))
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x20)
    assert_equal(Int(statuses[0].worktree), 0x4D)
    # Build a minimal patch from the unstaged diff and apply it: that
    # exercises the line-staging path end-to-end. The hunk has one ``-``
    # / one ``+`` pair, so targeting the ``+`` line stages the change
    # while demoting the ``-`` to context (algorithm tested above).
    var unstaged = compute_unstaged_diff(dir)
    assert_true(len(unstaged.as_bytes()) > 0)
    var per_file = parse_unified_diff_files(unstaged)
    assert_equal(len(per_file), 1)
    var lines = List[String]()
    var b = per_file[0].diff.as_bytes()
    var s = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            lines.append(String(StringSpan(unsafe_from_utf8=b[s:i])))
            s = i + 1
    if s < len(b):
        lines.append(String(StringSpan(unsafe_from_utf8=b[s:len(b)])))
    # Find the ``+beta-modified`` line index.
    var plus_idx = -1
    for i in range(len(lines)):
        var lb = lines[i].as_bytes()
        if len(lb) > 0 and Int(lb[0]) == 0x2B \
                and lines[i] != String("+++ b/a.txt"):
            plus_idx = i
            break
    assert_true(plus_idx > 0)
    var patch = build_minimal_patch(per_file[0].diff, plus_idx, False)
    assert_true(len(patch.as_bytes()) > 0)
    assert_true(apply_patch_to_index(dir, patch, False))
    # After applying: the staged side should now have a modification.
    # Worktree column stays modified because we only staged the ``+`` half
    # of the replacement (``-beta`` was demoted to context, so removing
    # ``beta`` is still pending) — that's the correct line-staging
    # semantics, just an awkward end-state. The point of the assertion
    # is that staging didn't no-op.
    var staged_after = compute_staged_diff(dir)
    assert_true(len(staged_after.as_bytes()) > 0)
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x4D)
    assert_equal(Int(statuses[0].worktree), 0x4D)
    _rm_rf(dir)


def test_fetch_git_status_expands_untracked_directories() raises:
    """A brand-new folder must show up as one status row per file inside
    it, not as a single collapsed ``dir/`` row.

    Plain ``git status --porcelain`` collapses a wholly-untracked
    directory, and a directory row is useless to the Local-changes view:
    it has no diff, can't be opened, and hides how many files the folder
    brought in. ``fetch_git_status`` passes ``--untracked-files=all`` to
    prevent that; this pins the behavior. Skipped silently when git is
    unavailable."""
    var dir = _temp_path(String("_status_uall"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    if _run_git(dir, init_args^) != 0:
        _rm_rf(dir)
        return
    var sub = join_path(dir, String("newdir"))
    _ensure_dir(sub)
    var nested = join_path(sub, String("nested"))
    _ensure_dir(nested)
    assert_true(write_file(join_path(sub, String("one.txt")), String("1\n")))
    assert_true(write_file(join_path(sub, String("two.txt")), String("2\n")))
    assert_true(
        write_file(join_path(nested, String("three.txt")), String("3\n")),
    )
    var statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 3)
    var seen_one = False
    var seen_two = False
    var seen_three = False
    for i in range(len(statuses)):
        # Every row is untracked ('?' in both columns) and names a file
        # — no row may end in '/'.
        assert_equal(Int(statuses[i].staged), 0x3F)
        assert_equal(Int(statuses[i].worktree), 0x3F)
        var pb = statuses[i].path.as_bytes()
        assert_true(len(pb) > 0 and pb[len(pb) - 1] != 0x2F)
        if statuses[i].path == String("newdir/one.txt"):
            seen_one = True
        if statuses[i].path == String("newdir/two.txt"):
            seen_two = True
        if statuses[i].path == String("newdir/nested/three.txt"):
            seen_three = True
    assert_true(seen_one)
    assert_true(seen_two)
    assert_true(seen_three)
    _rm_rf(dir)


def test_local_changes_files_panel_is_a_tree() raises:
    """The Files panel shows changed paths as a tree: directory rows,
    then their contents indented with basenames only — not one full-path
    row per file. Pins three things: the tree ordering of ``files``
    (dirs first at every level, then case-insensitive, so flat file
    indices walk the painted tree top-to-bottom), the derived
    ``file_rows`` (labels / indents / file back-references), and that
    directory rows carry ``file_idx == -1``. Skipped silently when git
    is unavailable."""
    var dir = _temp_path(String("_files_tree"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    if _run_git(dir, init_args^) != 0:
        _rm_rf(dir)
        return
    var sub = join_path(dir, String("newdir"))
    _ensure_dir(sub)
    var nested = join_path(sub, String("nested"))
    _ensure_dir(nested)
    assert_true(write_file(join_path(dir, String("a.txt")), String("a\n")))
    assert_true(write_file(join_path(dir, String("zz.txt")), String("z\n")))
    assert_true(write_file(join_path(sub, String("one.txt")), String("1\n")))
    assert_true(write_file(join_path(sub, String("two.txt")), String("2\n")))
    assert_true(
        write_file(join_path(nested, String("three.txt")), String("3\n")),
    )
    var lc = LocalChanges()
    lc.open(dir)
    # Model order: newdir/ subtree first (dirs before files at the top
    # level), nested/ before newdir's own files, then the root files.
    assert_equal(len(lc.files), 5)
    assert_equal(lc.files[0].path, String("newdir/nested/three.txt"))
    assert_equal(lc.files[1].path, String("newdir/one.txt"))
    assert_equal(lc.files[2].path, String("newdir/two.txt"))
    assert_equal(lc.files[3].path, String("a.txt"))
    assert_equal(lc.files[4].path, String("zz.txt"))
    # Display rows: two directory headers, then basenames at their depth.
    assert_equal(len(lc.file_rows), 7)
    assert_equal(lc.file_rows[0].file_idx, -1)
    assert_equal(lc.file_rows[0].indent, 0)
    assert_equal(lc.file_rows[0].label, String("newdir/"))
    assert_equal(lc.file_rows[1].file_idx, -1)
    assert_equal(lc.file_rows[1].indent, 1)
    assert_equal(lc.file_rows[1].label, String("nested/"))
    assert_equal(lc.file_rows[2].file_idx, 0)
    assert_equal(lc.file_rows[2].indent, 2)
    assert_equal(lc.file_rows[2].label, String("three.txt"))
    assert_equal(lc.file_rows[3].file_idx, 1)
    assert_equal(lc.file_rows[3].indent, 1)
    assert_equal(lc.file_rows[3].label, String("one.txt"))
    assert_equal(lc.file_rows[4].file_idx, 2)
    assert_equal(lc.file_rows[4].indent, 1)
    assert_equal(lc.file_rows[4].label, String("two.txt"))
    assert_equal(lc.file_rows[5].file_idx, 3)
    assert_equal(lc.file_rows[5].indent, 0)
    assert_equal(lc.file_rows[5].label, String("a.txt"))
    assert_equal(lc.file_rows[6].file_idx, 4)
    assert_equal(lc.file_rows[6].indent, 0)
    assert_equal(lc.file_rows[6].label, String("zz.txt"))
    lc.release()
    _rm_rf(dir)


def test_local_changes_untracked_file_shows_its_whole_contents() raises:
    """Selecting an untracked file must fill the Unstaged panel with the
    whole file as ``+`` rows.

    Neither whole-tree fetch can see an untracked file — ``git diff``
    walks the index — so before ``compute_untracked_diff`` the panel held
    nothing but the "press Space to stage it" note. That note stays (the
    file really isn't tracked), followed by the synthesized
    ``/dev/null`` → worktree diff.

    Skipped silently when ``git`` isn't on PATH."""
    var dir = _temp_path(String("_untracked_diff"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    if _run_git(dir, init_args^) != 0:
        _rm_rf(dir)
        return
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    # A committed file so HEAD resolves; the untracked one is the subject.
    assert_true(
        write_file(join_path(dir, String("tracked.txt")), String("base\n")),
    )
    var add = List[String]()
    add.append(String("add"))
    add.append(String("tracked.txt"))
    _ = _run_git(dir, add^)
    var commit = List[String]()
    commit.append(String("commit"))
    commit.append(String("-q"))
    commit.append(String("-m"))
    commit.append(String("init"))
    _ = _run_git(dir, commit^)
    assert_true(
        write_file(
            join_path(dir, String("fresh.txt")),
            String("first line\nsecond line\nthird line\n"),
        ),
    )
    var lc = LocalChanges()
    lc.open(dir)
    # ``??`` in both columns — one row, the untracked file.
    assert_equal(len(lc.files), 1)
    assert_equal(lc.files[0].path, String("fresh.txt"))
    assert_equal(Int(lc.files[0].staged), 0x3F)
    assert_equal(Int(lc.files[0].worktree), 0x3F)
    var registry = GrammarRegistry()
    var screen = Rect(0, 0, 120, 40)
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    # Every content line shows up as an addition row.
    var want = List[String]()
    want.append(String("first line"))
    want.append(String("second line"))
    want.append(String("third line"))
    for w in range(len(want)):
        var found = False
        for i in range(len(lc.unstaged.lines)):
            if lc.unstaged.lines[i] == want[w] \
                    and lc.unstaged.kind[i] == _LINE_ADD:
                found = True
                break
        assert_true(found)
    # The hint survives above the diff, and nothing claims there are no
    # unstaged changes.
    var saw_hint = False
    for i in range(len(lc.unstaged.lines)):
        if _contains(lc.unstaged.lines[i], String("untracked")):
            saw_hint = True
        assert_false(
            _contains(lc.unstaged.lines[i], String("no unstaged changes")),
        )
    assert_true(saw_hint)
    # The diff is cached on the entry in git's own new-file shape, so the
    # line-level staging path can build a patch from it.
    var stored = lc.files[0].unstaged_diff
    assert_true(_contains(stored, String("new file mode")))
    assert_true(_contains(stored, String("@@ -0,0 +1,3 @@")))
    # And that patch really applies: staging just ``+second line`` puts
    # that one line in the index and leaves the other two unstaged
    # (status ``AM``). This is the payoff of caching a genuine unified
    # diff rather than only rendering the file's text.
    var diff_lines_of = _lines_from(stored)
    var target = -1
    for i in range(len(diff_lines_of)):
        if diff_lines_of[i] == String("+second line"):
            target = i
            break
    assert_true(target > 0)
    var patch = build_minimal_patch(stored, target, False)
    assert_true(len(patch.as_bytes()) > 0)
    assert_true(apply_patch_to_index(dir, patch, False))
    var after = fetch_git_status(dir)
    assert_equal(len(after), 1)
    assert_equal(Int(after[0].staged), 0x41)      # 'A'
    assert_equal(Int(after[0].worktree), 0x4D)    # 'M'
    lc.close()
    _rm_rf(dir)


def test_local_changes_untracked_empty_file_has_no_body_rows() raises:
    """A zero-byte untracked file has no content to differ, so git emits
    the ``new file mode`` header and stops — no ``---``/``+++`` pair, no
    hunk. The panel keeps the hint and paints no ``+`` rows rather than
    inventing a phantom line."""
    var dir = _temp_path(String("_untracked_empty"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    if _run_git(dir, init_args^) != 0:
        _rm_rf(dir)
        return
    assert_true(write_file(join_path(dir, String("empty.txt")), String("")))
    var lc = LocalChanges()
    lc.open(dir)
    assert_equal(len(lc.files), 1)
    var registry = GrammarRegistry()
    var screen = Rect(0, 0, 120, 40)
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    var stored = lc.files[0].unstaged_diff
    assert_true(_contains(stored, String("new file mode")))
    assert_false(_contains(stored, String("@@")))
    var saw_hint = False
    for i in range(len(lc.unstaged.lines)):
        if _contains(lc.unstaged.lines[i], String("untracked")):
            saw_hint = True
        assert_true(lc.unstaged.kind[i] != _LINE_ADD)
    assert_true(saw_hint)
    lc.close()
    _rm_rf(dir)


def _init_repo_with_a_merge() raises -> String:
    """Throwaway repo whose ``main`` ends in a real merge commit:

        base ── main work ──── M   (main)
             └ feat one ─ feat two (feature)

    Returns the path, or the empty string when git isn't available."""
    var dir = _temp_path(String("_merge_log"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    if _run_git(dir, init_args^) != 0:
        _rm_rf(dir)
        return String("")
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    _ = _commit_file(
        dir, String("base.txt"), String("base\n"), String("base"),
    )
    _ = _checkout_new(dir, String("feature"))
    _ = _commit_file(
        dir, String("one.txt"), String("one\n"), String("feat one"),
    )
    _ = _commit_file(
        dir, String("two.txt"), String("two\n"), String("feat two"),
    )
    _ = _checkout(dir, String("main"))
    _ = _commit_file(
        dir, String("main.txt"), String("main\n"), String("main work"),
    )
    var m = List[String]()
    m.append(String("merge"))
    m.append(String("-q"))
    m.append(String("--no-ff"))
    m.append(String("feature"))
    m.append(String("-m"))
    m.append(String("Merge feature"))
    if _run_git(dir, m^) != 0:
        _rm_rf(dir)
        return String("")
    return dir^


def test_merge_commit_log_lists_the_commits_it_brought_in() raises:
    """A merge row in the commit log used to be a dead end: ``git show``
    on a merge prints the header and no diff, so selecting the one commit
    you most want to inspect showed nothing but its own message.

    Three things have to hold: the log lists the merged-in commits (git
    does that for us, but ``%p`` parsing must not drop rows), the merge
    row identifies itself as a merge, and the two merge-only fetches
    return the side branch's commits and its diff."""
    var dir = _init_repo_with_a_merge()
    if len(dir.as_bytes()) == 0:
        return
    var commits = fetch_git_commits(dir, 50)
    # base, feat one, feat two, main work, M — all five, merge first.
    assert_equal(len(commits), 5)
    assert_equal(commits[0].subject, String("Merge feature"))
    assert_true(commits[0].is_merge())
    var subjects = String("")
    for i in range(len(commits)):
        subjects += commits[i].subject + String("\n")
        # Every non-merge row has exactly one parent (or none, for base).
        if i != 0:
            assert_false(commits[i].is_merge())
    assert_true(_contains(subjects, String("feat one")))
    assert_true(_contains(subjects, String("feat two")))
    # The merge's first parent is the mainline side, not the branch.
    var mainline = commits[0].first_parent()
    assert_true(len(mainline.as_bytes()) > 0)
    var main_work = String("")
    for i in range(len(commits)):
        if commits[i].subject == String("main work"):
            main_work = commits[i].short_sha
    assert_equal(mainline, main_work)
    # The merged-in list is the side branch only: its two commits, and
    # neither the merge itself nor the mainline commit it landed on.
    var merged = fetch_merged_commits(dir, commits[0].short_sha)
    assert_true(_contains(merged, String("feat one")))
    assert_true(_contains(merged, String("feat two")))
    assert_false(_contains(merged, String("Merge feature")))
    assert_false(_contains(merged, String("main work")))
    # And a non-merge commit has nothing behind it.
    assert_equal(len(fetch_merged_commits(dir, main_work).as_bytes()), 0)
    # ``git show --first-parent`` gives the merge a diff: what it brought
    # in. Bare ``git show`` on a merge stops after the header.
    var show = fetch_commit_show(dir, commits[0].short_sha)
    assert_true(_contains(show, String("Merge feature")))
    assert_true(_contains(show, String("one.txt")))
    assert_true(_contains(show, String("two.txt")))
    assert_false(_contains(show, String("main.txt")))
    _rm_rf(dir)


def test_merge_commit_info_panel_shows_merged_commits_section() raises:
    """The view side: the merged-in log lands in the info panel between
    the commit metadata and the diff, with a counted header."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    var registry = GrammarRegistry()
    lc._populate_commit_info(
        String(
            "commit abc1234\nMerge: 1111111 2222222\n\n"
            "    Merge feature\n"
            "diff --git a/one.txt b/one.txt\n"
            "--- /dev/null\n+++ b/one.txt\n@@ -0,0 +1 @@\n+one\n"
        ),
        String("2222222  2026-08-05  Test\n    feat two\n\n"
               "1111112  2026-08-05  Test\n    feat one\n"),
        registry,
    )
    var joined = String("")
    for i in range(len(lc.info.lines)):
        joined += lc.info.lines[i] + String("\n")
    assert_true(_contains(joined, String("Merged 2 commits:")))
    assert_true(_contains(joined, String("feat one")))
    assert_true(_contains(joined, String("feat two")))
    # Section order: metadata, then the merged list, then the diff.
    var hdr = -1
    var body = -1
    var dif = -1
    for i in range(len(lc.info.lines)):
        if _contains(lc.info.lines[i], String("Merge feature")) and hdr < 0:
            hdr = i
        if _contains(lc.info.lines[i], String("Merged 2 commits:")):
            body = i
        if _contains(lc.info.lines[i], String("one.txt")) and dif < 0:
            dif = i
    assert_true(hdr >= 0 and body > hdr and dif > body)


def test_review_mode_builds_changeset_model() raises:
    # Two files, given as explicit before/after texts (the git-free entry
    # point). ReviewMode is now just the changeset model + navigation — the
    # body is a real editor window the host opens per file — so the model
    # carries the per-file before/after text and file-to-file navigation.
    var paths = List[String]()
    var befores = List[String]()
    var afters = List[String]()
    paths.append(String("a.txt"))
    befores.append(String("context one\nold line\ncontext two\ntail\n"))
    afters.append(String("context one\nnew line\ncontext two\ntail\n"))
    paths.append(String("b.txt"))
    befores.append(String("keep\n"))
    afters.append(String("keep\nsecond file add\n"))
    var rv = ReviewMode()
    rv.build_from_pairs(paths, befores, afters)
    assert_equal(rv.file_count(), 2)
    assert_equal(rv.current_path(), String("a.txt"))
    assert_equal(
        rv.current_before(),
        String("context one\nold line\ncontext two\ntail\n"),
    )
    assert_equal(
        rv.current_after(),
        String("context one\nnew line\ncontext two\ntail\n"),
    )
    # Change navigation: Ctrl+Shift+PageDown/PageUp are claimed as review
    # chrome and set a nav intent the host drains (the host walks change
    # chunks in the editor and rolls across files via ``goto_file_rel``).
    rv.active = True
    rv.mode = 1   # _MODE_REVIEW
    var view = Rect(0, 0, 80, 24)
    var fwd = Event.key_event(KEY_PAGEDOWN, MOD_CTRL | MOD_SHIFT)
    var back = Event.key_event(KEY_PAGEUP, MOD_CTRL | MOD_SHIFT)
    assert_true(rv.handle_event(fwd, view, 0))    # chrome-claimed
    assert_equal(rv.consume_nav(), 1)             # forward intent
    assert_equal(rv.consume_nav(), 0)             # drained
    assert_true(rv.handle_event(back, view, 0))
    assert_equal(rv.consume_nav(), -1)            # backward intent
    # Cross-file moves clamp at both ends.
    assert_true(rv.goto_file_rel(1))              # 0 -> 1
    assert_equal(rv.cur_file, 1)
    assert_equal(rv.current_path(), String("b.txt"))
    assert_true(not rv.goto_file_rel(1))          # clamp at last file
    assert_equal(rv.cur_file, 1)
    assert_true(rv.goto_file_rel(-1))             # 1 -> 0
    assert_equal(rv.cur_file, 0)
    # A plain arrow key is NOT review chrome — it returns False so the host
    # forwards it to the hosted editor.
    assert_true(not rv.handle_event(Event.key_event(KEY_LEFT), view, 0))


def _reword_repo(tag: String) raises -> String:
    """A repo with three commits on ``main``, the middle one carrying a
    multi-paragraph message. Returns the directory, or ``""`` when git
    isn't on PATH (callers skip, matching the other git tests)."""
    var dir = _temp_path(tag)
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    if _run_git(dir, init_args^) != 0:
        _rm_rf(dir)
        return String("")
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    var subjects = List[String]()
    subjects.append(String("first"))
    subjects.append(String("second subject\n\nsecond body line"))
    subjects.append(String("third"))
    for i in range(len(subjects)):
        var f = join_path(dir, String("f") + String(i) + String(".txt"))
        assert_true(write_file(f, String("v") + String(i) + String("\n")))
        var add = List[String]()
        add.append(String("add"))
        add.append(String("."))
        _ = _run_git(dir, add^)
        var commit = List[String]()
        commit.append(String("commit"))
        commit.append(String("-q"))
        commit.append(String("-m"))
        commit.append(subjects[i])
        _ = _run_git(dir, commit^)
    return dir^


def test_fetch_commit_message_returns_full_body() raises:
    """``%B``, not ``%s``: the editor prefill has to include the body, or
    saving would silently truncate a multi-paragraph message to its
    subject. The trailing newline git adds is not part of the message."""
    var dir = _reword_repo(String("_reword_msg"))
    if len(dir.as_bytes()) == 0:
        return
    var commits = fetch_git_commits(dir, 10)
    assert_equal(len(commits), 3)
    # commits[1] is the middle one — the multi-paragraph message.
    var msg = fetch_commit_message(dir, commits[1].short_sha)
    assert_equal(msg, String("second subject\n\nsecond body line"))
    # Subject-only commits round-trip with no trailing blank line.
    var top = fetch_commit_message(dir, commits[0].short_sha)
    assert_equal(top, String("third"))
    _rm_rf(dir)


def test_head_short_sha_matches_the_top_of_the_log() raises:
    var dir = _reword_repo(String("_reword_head"))
    if len(dir.as_bytes()) == 0:
        return
    var commits = fetch_git_commits(dir, 10)
    assert_equal(head_short_sha(dir), commits[0].short_sha)
    # And it isn't the older ones — that's the distinction that picks
    # ``--amend`` over the replay path.
    assert_true(head_short_sha(dir) != commits[1].short_sha)
    _rm_rf(dir)


def test_create_reworded_commit_keeps_tree_and_parent() raises:
    """The new object must differ from the original *only* in its message:
    same tree, same parent. That's what makes the subsequent replay
    content-identical and therefore conflict-free."""
    var dir = _reword_repo(String("_reword_obj"))
    if len(dir.as_bytes()) == 0:
        return
    var commits = fetch_git_commits(dir, 10)
    var old_sha = commits[1].short_sha
    var new_sha = create_reworded_commit(dir, old_sha, String("rewritten"))
    assert_true(len(new_sha.as_bytes()) > 0)
    # Message changed...
    assert_equal(fetch_commit_message(dir, new_sha), String("rewritten"))
    # ...tree did not.
    var t1 = List[String]()
    t1.append(String("rev-parse"))
    t1.append(old_sha + String("^{tree}"))
    var t2 = List[String]()
    t2.append(String("rev-parse"))
    t2.append(new_sha + String("^{tree}"))
    assert_equal(_git_out(dir, t1^), _git_out(dir, t2^))
    # ...and neither did the parent.
    var p1 = List[String]()
    p1.append(String("rev-parse"))
    p1.append(old_sha + String("^"))
    var p2 = List[String]()
    p2.append(String("rev-parse"))
    p2.append(new_sha + String("^"))
    assert_equal(_git_out(dir, p1^), _git_out(dir, p2^))
    # Nothing moved: HEAD is untouched, so a failure here leaves no mess.
    assert_equal(head_short_sha(dir), commits[0].short_sha)
    _rm_rf(dir)


def test_has_merge_between_is_false_on_a_linear_history() raises:
    var dir = _reword_repo(String("_reword_linear"))
    if len(dir.as_bytes()) == 0:
        return
    var commits = fetch_git_commits(dir, 10)
    assert_false(has_merge_between(dir, commits[2].short_sha))
    _rm_rf(dir)


def test_local_changes_e_refuses_a_pushed_commit() raises:
    """The guard the whole feature rests on: a commit that's already on a
    remote can't be reworded, because rewriting it would need a
    force-push. No overlay, no git op — just an explanation."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    lc.commits.append(
        GitCommit(
            String("aaa1111"), String("A"), String("2026-01-01"),
            String("already pushed"), True, String(""), String("bbb2222"),
        ),
    )
    lc.focus = _PANE_COMMITS
    lc.sel_commit = 0
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x65)), screen, registry)   # 'e'
    assert_equal(lc.overlay, _OVERLAY_STATUS)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_true(_contains(lc.overlay_message, String("pushed")))


def test_local_changes_e_refuses_a_merge_commit() raises:
    """Rewording a merge would have to go through ``git rebase``, which
    flattens merges — so a message-only edit would restructure history."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    lc.commits.append(
        GitCommit(
            String("aaa1111"), String("A"), String("2026-01-01"),
            String("Merge branch 'x'"), False, String(""),
            String("bbb2222 ccc3333"),      # two parents == a merge
        ),
    )
    lc.focus = _PANE_COMMITS
    lc.sel_commit = 0
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x65)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_STATUS)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_true(_contains(lc.overlay_message, String("merge")))


def test_local_changes_e_opens_prefilled_editor_and_esc_cancels() raises:
    """``e`` on an unpushed commit opens the multi-line editor loaded with
    the existing message (body included), paints the Save button with its
    shortcut on the face, and ESC backs out without running git."""
    var dir = _reword_repo(String("_reword_open"))
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_COMMITS
    lc.sel_commit = 1                 # the multi-paragraph one
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x65)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_EDIT_MSG)
    assert_equal(lc._git_op, _GITOP_NONE)
    # Prefilled with the *whole* message, as multiple lines.
    assert_equal(
        lc.overlay_editor.text_snapshot(),
        String("second subject\n\nsecond body line"),
    )
    assert_equal(lc.overlay_editor.buffer.line_count(), 3)
    # The Save button advertises the chord, since Enter is a newline here.
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    var painted = String("")
    for y in range(screen.height()):
        for x in range(screen.width()):
            painted += canvas.get(x, y).glyph
        painted += String("\n")
    assert_true(_contains(painted, String("Save")))
    assert_true(_contains(painted, String("Ctrl+")))
    assert_true(_contains(painted, String("ESC: cancel")))
    # Plain Enter edits rather than submitting.
    _ = lc.handle_key(_key(KEY_ENTER), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_EDIT_MSG)
    assert_equal(lc._git_op, _GITOP_NONE)
    # ESC cancels: overlay gone, no git op, message on disk untouched.
    _ = lc.handle_key(_key(KEY_ESC), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_NONE)
    var commits = fetch_git_commits(dir, 10)
    assert_equal(
        fetch_commit_message(dir, commits[1].short_sha),
        String("second subject\n\nsecond body line"),
    )
    _rm_rf(dir)


def test_reword_editor_supports_keyboard_selection() raises:
    """The message box is a real ``Editor``, so Shift+arrow selects and
    typing replaces the selection. This is the whole reason it isn't a
    bespoke widget — a hand-rolled input had none of it."""
    var dir = _reword_repo(String("_reword_kbsel"))
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_COMMITS
    lc.sel_commit = 0                 # message is "third"
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x65)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_EDIT_MSG)
    assert_false(lc.overlay_editor.has_selection())
    # Home, then Shift+Right three times: "thi" is selected.
    _ = lc.handle_key(_key(KEY_HOME), screen, registry)
    for _ in range(3):
        _ = lc.handle_key(_key(KEY_RIGHT, MOD_SHIFT), screen, registry)
    assert_true(lc.overlay_editor.has_selection())
    assert_equal(lc.overlay_editor.selection_text(), String("thi"))
    # Typing over a selection replaces it.
    _ = lc.handle_key(_key(UInt32(0x58)), screen, registry)     # 'X'
    assert_equal(lc.overlay_editor.text_snapshot(), String("Xrd"))
    assert_false(lc.overlay_editor.has_selection())
    _rm_rf(dir)


def test_reword_editor_supports_mouse_selection_and_undo() raises:
    """Press-drag-release inside the box selects a range, and undo is the
    editor's own — two more things the message box gets for free by being
    an ``Editor``."""
    var dir = _reword_repo(String("_reword_mousesel"))
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_COMMITS
    lc.sel_commit = 1                 # "second subject\n\nsecond body line"
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x65)), screen, registry)
    # Paint once so the editor's view rect is recorded for hit-testing.
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    var area = lc._reword_area_rect
    # Drag across the first six cells of row 0: selects "second".
    var x0 = area.a.x
    var y0 = area.a.y
    _ = lc.handle_mouse(
        Event.mouse_event(Point(x0, y0), MOUSE_BUTTON_LEFT, True, False),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(x0 + 6, y0), MOUSE_BUTTON_LEFT, True, True),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(x0 + 6, y0), MOUSE_BUTTON_LEFT, False, False),
        screen, registry,
    )
    assert_true(lc.overlay_editor.has_selection())
    assert_equal(lc.overlay_editor.selection_text(), String("second"))
    # Delete the selection, then undo restores it — the editor's history,
    # not something reimplemented here.
    _ = lc.handle_key(_key(KEY_BACKSPACE), screen, registry)
    assert_true(
        _starts_with(lc.overlay_editor.text_snapshot(), String(" subject")),
    )
    _ = lc.handle_key(_key(UInt32(0x7A), MOD_META), screen, registry)   # ⌘Z
    assert_true(
        _starts_with(lc.overlay_editor.text_snapshot(), String("second subject")),
    )
    _rm_rf(dir)


def test_local_changes_reword_head_amends_the_message() raises:
    """Cmd+Enter on the tip runs ``commit --amend``: the message changes
    and the commit count doesn't."""
    var dir = _reword_repo(String("_reword_amend"))
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_COMMITS
    lc.sel_commit = 0                 # HEAD
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x65)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_EDIT_MSG)
    assert_true(lc._reword_is_head)
    lc.overlay_editor = lc._message_editor_for(
        String("amended subject\n\nwith a body"),
    )
    _ = lc.handle_key(_key(KEY_ENTER, MOD_META), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_REWORD)
    _drain_git_op(lc)
    var commits = fetch_git_commits(dir, 10)
    assert_equal(len(commits), 3)     # amended, not added
    assert_equal(
        fetch_commit_message(dir, commits[0].short_sha),
        String("amended subject\n\nwith a body"),
    )
    _rm_rf(dir)


def test_local_changes_reword_older_commit_keeps_its_children() raises:
    """The replay path. Rewording the *middle* commit rewrites it and
    replays the commit above it — the history keeps its shape (same
    count, same order, same file contents) and only the one message
    changes."""
    var dir = _reword_repo(String("_reword_replay"))
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_COMMITS
    lc.sel_commit = 1                 # middle commit, not HEAD
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x65)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_EDIT_MSG)
    assert_false(lc._reword_is_head)
    lc.overlay_editor = lc._message_editor_for(String("middle rewritten"))
    _ = lc.handle_key(_key(KEY_ENTER, MOD_META), screen, registry)
    assert_equal(lc._git_op, _GITOP_REWORD)
    _drain_git_op(lc)
    var commits = fetch_git_commits(dir, 10)
    assert_equal(len(commits), 3)
    # The rewritten message is in place...
    assert_equal(
        fetch_commit_message(dir, commits[1].short_sha),
        String("middle rewritten"),
    )
    # ...its child kept its own message and stayed on top...
    assert_equal(
        fetch_commit_message(dir, commits[0].short_sha), String("third"),
    )
    # ...and the first commit is untouched.
    assert_equal(
        fetch_commit_message(dir, commits[2].short_sha), String("first"),
    )
    # Content survived the replay: every file is still there.
    for i in range(3):
        var f = join_path(dir, String("f") + String(i) + String(".txt"))
        assert_true(len(read_file(f).as_bytes()) > 0)
    _rm_rf(dir)


def _git_out(dir: String, var args: List[String]) raises -> String:
    """``git -C dir <args>`` stdout, trimmed. Test-local since the
    production helper is private to ``git_changes``."""
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(dir)
    for i in range(len(args)):
        argv.append(args[i])
    var r = capture_command(argv^)
    return String(r.stdout.strip())


def _drain_git_op(mut lc: LocalChanges):
    """Spin ``tick`` until the in-flight git child reaps, so a test
    doesn't leave a zombie behind. Non-blocking, so this is a spin."""
    for _ in range(2000000):
        if lc._git_op == _GITOP_NONE:
            break
        lc.tick()


def _checkout(dir: String, name: String) raises -> Int:
    var a = List[String]()
    a.append(String("checkout"))
    a.append(String("-q"))
    a.append(name)
    return _run_git(dir, a^)


def _checkout_new(dir: String, name: String) raises -> Int:
    var a = List[String]()
    a.append(String("checkout"))
    a.append(String("-q"))
    a.append(String("-b"))
    a.append(name)
    return _run_git(dir, a^)


def _checkout_new_at(dir: String, name: String, start: String) raises -> Int:
    var a = List[String]()
    a.append(String("checkout"))
    a.append(String("-q"))
    a.append(String("-b"))
    a.append(name)
    a.append(start)
    return _run_git(dir, a^)


def _commit_file(
    dir: String, name: String, body: String, message: String,
) raises -> Int:
    if not write_file(join_path(dir, name), body):
        return -1
    var add = List[String]()
    add.append(String("add"))
    add.append(String("-A"))
    _ = _run_git(dir, add^)
    var c = List[String]()
    c.append(String("commit"))
    c.append(String("-q"))
    c.append(String("-m"))
    c.append(message)
    return _run_git(dir, c^)


def _init_repo_with_branches() raises -> String:
    """Throwaway repo on ``main`` with one commit, plus four branches
    covering every answer ``branch_is_merged`` has to give:

    * ``merged-x``    — same tip as main (plain ancestry).
    * ``rebased-x``   — its commit was replayed onto main under a new
      SHA, so ancestry says no but the patch-id says yes.
    * ``squashed-x``  — two commits squash-merged into one on main, so
      not even the per-commit patch-ids match — only their sum does.
    * ``unmerged-x``  — genuinely not in main.

    Returns the path, or the empty string when git isn't available."""
    var dir = _temp_path(String("_branch_ops"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    var rc = _run_git(dir, init_args^)
    if rc != 0:
        # No git on PATH — skip silently, matching the other repo tests.
        _rm_rf(dir)
        return String("")
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    if not write_file(join_path(dir, String("a.txt")), String("one\n")):
        return String("")
    var add = List[String]()
    add.append(String("add"))
    add.append(String("a.txt"))
    _ = _run_git(dir, add^)
    var commit = List[String]()
    commit.append(String("commit"))
    commit.append(String("-q"))
    commit.append(String("-m"))
    commit.append(String("init"))
    _ = _run_git(dir, commit^)
    # merged-x: same tip as main, nothing to lose.
    var br1 = List[String]()
    br1.append(String("branch"))
    br1.append(String("merged-x"))
    _ = _run_git(dir, br1^)
    # rebased-x: one commit, replayed onto a moved main. git rebase
    # gives it a fresh SHA, so only a patch-id comparison finds it.
    _ = _checkout_new(dir, String("rebased-x"))
    _ = _commit_file(dir, String("reb.txt"), String("reb\n"), String("reb"))
    _ = _checkout(dir, String("main"))
    _ = _commit_file(dir, String("moved.txt"), String("m\n"), String("moved"))
    _ = _checkout_new_at(dir, String("_tmp"), String("rebased-x"))
    var reb = List[String]()
    reb.append(String("rebase"))
    reb.append(String("-q"))
    reb.append(String("main"))
    _ = _run_git(dir, reb^)
    _ = _checkout(dir, String("main"))
    var ff = List[String]()
    ff.append(String("merge"))
    ff.append(String("-q"))
    ff.append(String("--ff-only"))
    ff.append(String("_tmp"))
    _ = _run_git(dir, ff^)
    var delt = List[String]()
    delt.append(String("branch"))
    delt.append(String("-q"))
    delt.append(String("-D"))
    delt.append(String("_tmp"))
    _ = _run_git(dir, delt^)
    # squashed-x: two commits collapsed into one on main. Per-commit
    # patch-ids all miss; only the combined diff matches.
    _ = _checkout_new_at(dir, String("squashed-x"), String("main"))
    _ = _commit_file(dir, String("s1.txt"), String("s1\n"), String("s1"))
    _ = _commit_file(dir, String("s2.txt"), String("s2\n"), String("s2"))
    _ = _checkout(dir, String("main"))
    var sq = List[String]()
    sq.append(String("merge"))
    sq.append(String("-q"))
    sq.append(String("--squash"))
    sq.append(String("squashed-x"))
    _ = _run_git(dir, sq^)
    var sqc = List[String]()
    sqc.append(String("commit"))
    sqc.append(String("-q"))
    sqc.append(String("-m"))
    sqc.append(String("squash it"))
    _ = _run_git(dir, sqc^)
    # unmerged-x: one commit main doesn't have, in any form.
    _ = _checkout_new_at(dir, String("unmerged-x"), String("main"))
    _ = _commit_file(dir, String("b.txt"), String("two\n"), String("wip"))
    _ = _checkout(dir, String("main"))
    return dir^


def _select_branch(mut lc: LocalChanges, name: String) -> Bool:
    for i in range(len(lc.branches)):
        if lc.branches[i].name == name:
            lc.sel_branch = i
            return True
    return False


def test_branch_is_merged_sees_through_rebase_and_squash() raises:
    """Ancestry alone would call a rebased or squash-merged branch
    unmerged — its commits are in main only as replayed or collapsed
    copies under different SHAs. The patch-id tiers are what make those
    two answer True, and they're the whole reason this is more useful
    than ``git branch -d``'s own check."""
    var dir = _init_repo_with_branches()
    if len(dir.as_bytes()) == 0:
        return                          # no git on PATH
    # Both are invisible to plain ancestry...
    assert_false(_is_ancestor_of_main(dir, String("rebased-x")))
    assert_false(_is_ancestor_of_main(dir, String("squashed-x")))
    # ...and both are recognized anyway.
    assert_true(branch_is_merged(dir, String("rebased-x")))
    assert_true(branch_is_merged(dir, String("squashed-x")))
    # A branch that really isn't in main stays False — the tiers must not
    # be so eager that the confirmation never fires.
    assert_false(branch_is_merged(dir, String("unmerged-x")))
    _rm_rf(dir)


def _git_capture(dir: String, var args: List[String]) raises -> String:
    """``_run_git`` but returning stdout instead of the exit status."""
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(dir)
    for i in range(len(args)):
        argv.append(args[i])
    return capture_command(argv).stdout


def _rev_list(dir: String, rev: String) raises -> List[String]:
    """Every commit SHA reachable from ``rev``, newest first."""
    var a = List[String]()
    a.append(String("rev-list"))
    a.append(rev)
    return split_lines_no_trailing(_git_capture(dir, a^))


def _current_branch(dir: String) raises -> String:
    var a = List[String]()
    a.append(String("rev-parse"))
    a.append(String("--abbrev-ref"))
    a.append(String("HEAD"))
    var lines = split_lines_no_trailing(_git_capture(dir, a^))
    return lines[0].copy() if len(lines) > 0 else String("")


def _is_ancestor_of_main(dir: String, branch: String) raises -> Bool:
    """The plain-ancestry check on its own, so the test above can show
    that it's the one that would have gotten these wrong."""
    var a = List[String]()
    a.append(String("merge-base"))
    a.append(String("--is-ancestor"))
    a.append(branch)
    a.append(String("main"))
    return _run_git(dir, a^) == 0


def test_branch_is_merged_reads_the_main_line() raises:
    """``branch_is_merged`` is what decides whether ``d`` needs a
    confirmation, so its three "be careful" answers matter as much as the
    happy path: the main branch itself, a repo with no main/master, and a
    non-repo all report False."""
    var dir = _init_repo_with_branches()
    if len(dir.as_bytes()) == 0:
        return                          # no git on PATH
    assert_equal(main_line_branch(dir), String("main"))
    assert_true(branch_is_merged(dir, String("merged-x")))
    assert_false(branch_is_merged(dir, String("unmerged-x")))
    # The main branch is trivially its own ancestor; we still say False so
    # deleting it can never skip the confirm.
    assert_false(branch_is_merged(dir, String("main")))
    # Not a repo / unknown branch.
    assert_equal(main_line_branch(String("/tmp")), String(""))
    assert_false(branch_is_merged(String("/tmp"), String("main")))
    assert_false(branch_is_merged(dir, String("no-such-branch")))
    _rm_rf(dir)


def test_local_changes_shift_m_asks_merge_commit_or_straight_history() raises:
    """``M`` on a non-current branch row doesn't run git — it asks which
    shape of history to produce, and only the answer spawns anything."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 1                       # feature-x
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x4D)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_MERGE_CHOICE)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_false(lc.git_runner.is_active())
    # The question names both branches, in the direction the work moves.
    assert_true(_contains(lc.overlay_message, String("feature-x")))
    assert_true(_contains(lc.overlay_message, String("main")))
    # Both answers are on screen, with what each one does.
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    var painted = String("")
    for y in range(screen.height()):
        for x in range(screen.width()):
            painted += canvas.get(x, y).glyph
        painted += String("\n")
    assert_true(_contains(painted, String("[m]")))
    assert_true(_contains(painted, String("[r]")))
    assert_true(_contains(painted, String("merge commit")))
    assert_true(_contains(painted, String("straight history")))
    # A key that isn't an answer leaves the question standing.
    _ = lc.handle_key(_key(UInt32(0x78)), screen, registry)   # 'x'
    assert_equal(lc.overlay, _OVERLAY_MERGE_CHOICE)
    # ESC backs out without running git.
    _ = lc.handle_key(_key(KEY_ESC), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_NONE)


def test_local_changes_merge_choice_m_spawns_a_no_ff_merge() raises:
    """``m`` answers "merge commit": ``git merge --no-ff``, never a bare
    merge — a bare merge fast-forwards when it can, which is the *other*
    answer's outcome and would make the choice a lie."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 1                       # feature-x
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x4D)), screen, registry)
    _ = lc.handle_key(_key(UInt32(0x6D)), screen, registry)   # 'm'
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_MERGE)
    assert_true(lc.git_runner.is_active())
    # ``command`` is the runner's shell-y rendering of the argv it spawned.
    var cmd = lc.git_runner.command
    assert_true(_contains(cmd, String("merge")))
    assert_true(_contains(cmd, String("--no-ff")))
    assert_true(_contains(cmd, String("--no-edit")))
    assert_true(_contains(cmd, String("feature-x")))
    _drain_git_op(lc)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_false(lc.git_runner.is_active())


def test_local_changes_merge_choice_r_spawns_a_rebase() raises:
    """``r`` answers "straight history" by replaying the *selected*
    branch onto the current one — ``git rebase <current> <branch>``.

    The argument order is the whole point. Bare ``git rebase <branch>``
    from the current branch integrates the same content but rewrites the
    current branch's commits, which for ``main`` means rewriting already
    pushed history. See ``test_rebase_preserves_current_branch_shas``."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 1                       # feature-x
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x4D)), screen, registry)
    _ = lc.handle_key(_key(UInt32(0x72)), screen, registry)   # 'r'
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_REBASE)
    assert_true(lc.git_runner.is_active())
    var cmd = lc.git_runner.command
    # Onto-branch first, topic branch second — never the bare one-arg form.
    assert_true(_contains(cmd, String("rebase main feature-x")))
    assert_false(_contains(cmd, String("merge")))
    _drain_git_op(lc)
    assert_equal(lc._git_op, _GITOP_NONE)


def test_rebase_preserves_current_branch_shas() raises:
    """The regression this exists for: "straight history" must not
    rewrite the branch you're standing on.

    ``main`` has a commit the topic branch doesn't, so the buggy
    direction (``git rebase <branch>`` from main) replays *that* commit
    and gives it a new SHA. In a real repo the rewritten commit is
    usually one that's already been pushed, which leaves the local branch
    diverged from its upstream and makes the next pull report "have
    diverged" and manufacture a merge.

    So: after the operation, main's pre-existing commits must still carry
    the same SHAs, the topic branch's work must be present, and the
    history must be linear (the whole point of the "straight" answer)."""
    var dir = _temp_path(String("_rebase_dir"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    if _run_git(dir, init_args^) != 0:
        _rm_rf(dir)
        return                              # no git on PATH
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)

    _ = _commit_file(dir, String("base.txt"), String("base\n"), String("A"))
    # feature-x branches here, then main moves on — that later commit on
    # main is what the wrong rebase direction rewrites.
    _ = _checkout_new(dir, String("feature-x"))
    _ = _commit_file(dir, String("f.txt"), String("f\n"), String("F"))
    _ = _checkout(dir, String("main"))
    _ = _commit_file(dir, String("m.txt"), String("m\n"), String("B on main"))
    var main_before = _rev_list(dir, String("main"))
    assert_equal(len(main_before), 2)

    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_BRANCHES
    if not _select_branch(lc, String("feature-x")):
        _rm_rf(dir)
        return
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x4D)), screen, registry)
    _ = lc.handle_key(_key(UInt32(0x72)), screen, registry)   # 'r'
    _drain_git_op(lc)
    assert_equal(lc._git_op, _GITOP_NONE)

    # Back on main, and every commit main already had kept its SHA.
    assert_equal(_current_branch(dir), String("main"))
    var main_after = _rev_list(dir, String("main"))
    assert_equal(len(main_after), 3)
    for i in range(len(main_before)):
        var kept = False
        for j in range(len(main_after)):
            if main_after[j] == main_before[i]:
                kept = True
        assert_true(kept)
    # feature-x's work arrived, and as one line — no merge commit.
    assert_equal(read_file(join_path(dir, String("f.txt"))), String("f\n"))
    var merges = List[String]()
    merges.append(String("rev-list"))
    merges.append(String("--merges"))
    merges.append(String("main"))
    assert_equal(
        len(split_lines_no_trailing(_git_capture(dir, merges^))), 0,
    )
    # The branch ref moved with the rewrite, so it's a plain ancestor now.
    var anc = List[String]()
    anc.append(String("merge-base"))
    anc.append(String("--is-ancestor"))
    anc.append(String("feature-x"))
    anc.append(String("main"))
    assert_equal(_run_git(dir, anc^), 0)
    _rm_rf(dir)


def test_rebase_success_output_is_routine() raises:
    """A finished rebase prints its progress counter and its verdict on one
    ``\\r``-joined line. That has to read as routine, or every successful
    rebase would pop the full-screen log."""
    var m = GitOutputMatcher(GIT_OUT_REBASE)
    assert_true(m.is_routine(String(
        "Rebasing (1/1)\rSuccessfully rebased and updated refs/heads/main.\n"
    )))
    assert_true(m.is_routine(String(
        "Rebasing (1/3)\rRebasing (2/3)\rRebasing (3/3)\r"
        "Successfully rebased and updated refs/heads/feature-x.\n"
    )))
    assert_true(m.is_routine(String("Current branch main is up to date.\n")))
    # A rebase that stopped has something to say, and must not be hidden.
    assert_false(m.is_routine(String(
        "Rebasing (1/2)\rerror: could not apply 1234abc... feat one\n"
        "hint: Resolve all conflicts manually.\n"
    )))


def test_autostash_pull_output_is_routine() raises:
    """A pull that had to stash dirty changes and put them back is still
    just a pull that worked. Both bodies below are verbatim captures from
    git 2.50 — note that the rebase backend prints ``Applied autostash.``
    at the *tail of the ``\\r`` redraw train* rather than on its own line,
    which is the shape a hand-written pattern gets wrong."""
    var m = GitOutputMatcher(GIT_OUT_PULL)
    # merge backend: autostash lines on their own, around the diffstat.
    assert_true(m.is_routine(String(
        "From /tmp/up\n"
        "   9cac3e9..07a89b3  main       -> origin/main\n"
        "Updating 9cac3e9..07a89b3\n"
        "Created autostash: 5a6300b\n"
        "Fast-forward\n"
        " f.txt | 1 +\n"
        " 1 file changed, 1 insertion(+)\n"
        "Applied autostash.\n"
    )))
    # rebase backend (``pull.rebase``): redraw train, then the apply
    # notice, then the rebase verdict.
    assert_true(m.is_routine(String(
        "Created autostash: 4620858\n"
        "Rebasing (1/3)\rRebasing (2/3)\rRebasing (3/3)\r"
        "Applied autostash.\n"
        "Successfully rebased and updated refs/heads/main.\n"
    )))
    # The one autostash outcome that must still surface: the stash did
    # not go back, the user's changes are sitting in it, and git says so
    # while *still exiting 0* — so the exit code can't catch this and the
    # classifier is the only thing standing between the user and silently
    # losing sight of their work.
    assert_false(m.is_routine(String(
        "Created autostash: bdde665\n"
        "Rebasing (1/3)\rRebasing (2/3)\rRebasing (3/3)\r"
        "Applying autostash resulted in conflicts.\n"
        "Your changes are safe in the stash.\n"
        "You can run \"git stash pop\" or \"git stash drop\" at any time.\n"
        "Successfully rebased and updated refs/heads/main.\n"
    )))
    # Fetch pads the local-ref column, so a pull's ref-update summary is
    # spaced differently from the push one the patterns were first
    # written against. Verbatim again, including the ``(none)`` source
    # git prints for a pruned remote branch.
    assert_true(m.is_routine(String(
        "From /tmp/up\n"
        " * [new branch]      sidebranch -> origin/sidebranch\n"
        " + f961126...e9952c6 sidebranch -> origin/sidebranch  (forced update)\n"
        " - [deleted]         (none)     -> origin/sidebranch\n"
        "Already up to date.\n"
    )))
    # Same lines are routine for a direct rebase and a direct merge,
    # both of which honor ``--autostash`` too.
    var reb = GitOutputMatcher(GIT_OUT_REBASE)
    assert_true(reb.is_routine(String(
        "Created autostash: 4620858\n"
        "Rebasing (1/1)\rApplied autostash.\n"
        "Successfully rebased and updated refs/heads/feature-x.\n"
    )))
    var mrg = GitOutputMatcher(GIT_OUT_MERGE)
    assert_true(mrg.is_routine(String(
        "Created autostash: 5a6300b\n"
        "Merge made by the 'ort' strategy.\n"
        " 1 file changed, 1 insertion(+)\n"
        "Applied autostash.\n"
    )))


def test_local_changes_shift_m_on_current_branch_is_a_noop() raises:
    """Merging the checked-out branch into itself is meaningless, so it
    flashes instead of spawning git."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 0                       # main, is_current
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x4D)), screen, registry)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_false(lc.git_runner.is_active())
    # A refusal, so it's modal — the user asked for something that didn't
    # happen and nothing on screen says so.
    assert_equal(lc.overlay, _OVERLAY_STATUS)
    assert_true(len(lc.overlay_message.as_bytes()) > 0)


def test_local_changes_d_on_current_branch_is_refused() raises:
    """Git won't delete the branch you're standing on, and neither will
    we — with our own message rather than relaying git's."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 0                       # main, is_current
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x64)), screen, registry)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_false(lc.git_runner.is_active())
    # A red status flash, explicitly *not* the delete confirmation —
    # there is no "yes, delete it anyway" answer for this case.
    assert_equal(lc.overlay, _OVERLAY_STATUS)
    assert_true(_contains(lc.overlay_message, String("main")))


def test_local_changes_d_on_unmerged_branch_confirms_first() raises:
    """The whole point of the confirmation: a branch that isn't merged
    into main must not vanish on one keystroke. ``y`` then runs the
    force-delete, since plain ``-d`` would refuse."""
    var dir = _init_repo_with_branches()
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_BRANCHES
    if not _select_branch(lc, String("unmerged-x")):
        _rm_rf(dir)
        return
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x64)), screen, registry)
    # Confirmation, not a delete.
    assert_equal(lc.overlay, _OVERLAY_DELETE_BRANCH_CONFIRM)
    assert_equal(lc._git_op, _GITOP_NONE)
    assert_true(_contains(lc.overlay_message, String("unmerged-x")))
    assert_true(_contains(lc.overlay_message, String("NOT merged")))
    # 'n' cancels and leaves the branch alone.
    _ = lc.handle_key(_key(UInt32(0x6E)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_NONE)
    var still = fetch_git_branches(dir)
    var found = False
    for i in range(len(still)):
        if still[i].name == String("unmerged-x"):
            found = True
    assert_true(found)
    # Re-open the confirm and answer 'y' this time.
    _ = lc.handle_key(_key(UInt32(0x64)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_DELETE_BRANCH_CONFIRM)
    _ = lc.handle_key(_key(UInt32(0x79)), screen, registry)
    assert_equal(lc._git_op, _GITOP_BRANCH_DELETE)
    _drain_git_op(lc)
    var after = fetch_git_branches(dir)
    for i in range(len(after)):
        assert_true(after[i].name != String("unmerged-x"))
    _rm_rf(dir)


def test_local_changes_d_on_merged_branch_deletes_immediately() raises:
    """A branch already contained in main loses nothing, so ``d`` acts
    straight away — no overlay in the way."""
    var dir = _init_repo_with_branches()
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_BRANCHES
    if not _select_branch(lc, String("merged-x")):
        _rm_rf(dir)
        return
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x64)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_BRANCH_DELETE)
    _drain_git_op(lc)
    var after = fetch_git_branches(dir)
    for i in range(len(after)):
        assert_true(after[i].name != String("merged-x"))
    # main survived.
    var has_main = False
    for i in range(len(after)):
        if after[i].name == String("main"):
            has_main = True
    assert_true(has_main)
    _rm_rf(dir)


def test_format_age_picks_one_unit() raises:
    """The branch pane's age column: one unit, truncated, and never
    ``m`` for months — minutes already own that letter."""
    assert_equal(format_age(0), String("0s"))
    assert_equal(format_age(-5), String("0s"))          # clock skew
    assert_equal(format_age(59), String("59s"))
    assert_equal(format_age(60), String("1m"))
    assert_equal(format_age(5 * 60 + 30), String("5m"))
    assert_equal(format_age(3599), String("59m"))
    assert_equal(format_age(3600), String("1h"))
    assert_equal(format_age(86399), String("23h"))
    assert_equal(format_age(86400), String("1d"))
    assert_equal(format_age(20 * 86400), String("20d"))
    # 364 days is still days; 365 flips to years.
    assert_equal(format_age(364 * 86400), String("364d"))
    assert_equal(format_age(365 * 86400), String("1y"))
    assert_equal(format_age(800 * 86400), String("2y"))


def test_local_changes_branch_pane_paints_age_column() raises:
    """One leftmost gutter holds *either* the age or the current-branch
    ``*``, right-aligned, with every name starting at the same column."""
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    # Without a timestamp there's no age to show — establishes that the
    # strings below come from the age column and not from some other
    # chrome that happens to contain them.
    var bare = _local_changes_with_branches()
    var bare_canvas = Canvas(screen.width(), screen.height())
    bare.paint(bare_canvas, screen, registry)
    var bare_painted = _screen_text(bare_canvas, screen)
    assert_false(_contains(bare_painted, String("37d")))
    assert_false(_contains(bare_painted, String("5m")))

    var lc = _local_changes_with_branches()
    var now = wall_clock_ms() // 1000
    lc.branches[0].committer_unix = now - 37 * 86400      # main, current
    lc.branches[1].committer_unix = now - 5 * 60          # feature-x, 5m
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    var painted = _screen_text(canvas, screen)
    # The current branch shows the marker and *no* age — you're already
    # there, so its age buys nothing and would widen the gutter.
    assert_true(_contains(painted, String(" * main")))
    assert_false(_contains(painted, String("37d")))
    # Everyone else shows an age, right-aligned into the same gutter, so
    # both names start at the same column.
    assert_true(_contains(painted, String("5m feature-x")))


def test_fetch_git_branches_carries_age_newest_first() raises:
    """Every branch row carries its tip's committer timestamp, and the
    list arrives newest-first — which is what puts the stalest branch at
    the bottom of the pane."""
    var dir = _init_repo_with_branches()
    if len(dir.as_bytes()) == 0:
        return                          # no git on PATH
    var branches = fetch_git_branches(dir)
    assert_true(len(branches) > 1)
    var now = wall_clock_ms() // 1000
    var prev = branches[0].committer_unix
    for i in range(len(branches)):
        # A real ref always has a parseable committer date, and these
        # commits were made moments ago.
        assert_true(branches[i].committer_unix > 0)
        assert_true(now - branches[i].committer_unix < 600)
        assert_true(branches[i].committer_unix <= prev)
        prev = branches[i].committer_unix
    _rm_rf(dir)


def test_routine_push_output_is_recognized() raises:
    """A plain push to an ordinary remote — including the "create a pull
    request" nudge GitHub adds for a new branch, which is the case that
    makes a blanket ``remote:`` allow-list wrong in one direction and a
    blanket ``remote:`` reject wrong in the other."""
    var m = GitOutputMatcher(GIT_OUT_PUSH)
    assert_true(m.is_routine(String("")))
    assert_true(m.is_routine(String("Everything up-to-date\n")))
    assert_true(m.is_routine(String(
        "Enumerating objects: 17, done.\n"
        "Counting objects: 100% (17/17), done.\n"
        "Delta compression uses up to 10 threads\n"
        "Compressing objects: 100% (9/9), done.\n"
        "Writing objects: 100% (9/9), 1.21 KiB | 1.21 MiB/s, done.\n"
        "Total 9 (delta 8), reused 0 (delta 0), pack-reused 0\n"
        "remote: Resolving deltas: 100% (8/8), completed with 8 local objects.\n"
        "To github.com:boxed/TurboKod.git\n"
        "   3fdfe00..bfc8c4a  main -> main\n"
    )))
    assert_true(m.is_routine(String(
        "To github.com:boxed/TurboKod.git\n"
        " * [new branch]      feature-x -> feature-x\n"
        "remote: \n"
        "remote: Create a pull request for 'feature-x' on GitHub by visiting:\n"
        "remote:      https://github.com/boxed/TurboKod/pull/new/feature-x\n"
        "remote: \n"
    )))


def test_git_output_matchers_compile_each_kind_once() raises:
    """The per-kind matchers are built once and kept.

    Nothing frees a compiled ``OnigRegex`` — its libonig handles live
    until the process exits — so a fresh ``GitOutputMatcher`` per git
    operation stranded ~25 KB every time the user committed, pushed,
    pulled, checked out, merged or rebased. ``GitOutputMatchers`` bounds
    that at one matcher per kind per session, which is what these counts
    assert.
    """
    var m = GitOutputMatchers()
    assert_equal(len(m.kinds), 0)
    for _ in range(4):
        assert_true(m.is_routine(
            GIT_OUT_PUSH, String("Everything up-to-date\n"),
        ))
        assert_true(m.is_routine(
            GIT_OUT_COMMIT, String("[main abc1234] a subject\n"),
        ))
        assert_false(m.is_routine(
            GIT_OUT_PUSH, String("remote: -----> Building myapp\n"),
        ))
    assert_equal(len(m.kinds), 2)
    assert_equal(len(m.matchers), 2)
    # An unarmed classifier (``GIT_OUT_OTHER``) still means "only silence
    # is routine", the state an idle LocalChanges sits in.
    assert_true(m.is_routine(GIT_OUT_OTHER, String("")))
    assert_false(m.is_routine(GIT_OUT_OTHER, String("anything\n")))
    assert_equal(len(m.kinds), 3)


def test_deploy_log_is_not_routine_push_output() raises:
    """The case this exists for: a Dokku / Heroku remote streaming a build
    back over ``remote:``. Its lines are not among the ones an ordinary
    push prints, so it must classify as worth showing — and it must do so
    from the *first* few lines, since that's what promotes the spinner to
    a full-screen log while the deploy is still running."""
    var m = GitOutputMatcher(GIT_OUT_PUSH)
    var head = String(
        "Enumerating objects: 5, done.\n"
        "Counting objects: 100% (5/5), done.\n"
        "remote: -----> Cleaning up...\n"
    )
    assert_false(m.is_routine(head))
    assert_false(m.is_routine(String(
        "To ssh://dokku@example.com:22/myapp\n"
        "remote: -----> Building myapp from Dockerfile\n"
        "remote:        Step 1/12 : FROM python:3.12-slim\n"
        "remote:         ---> a1b2c3d4e5f6\n"
        "remote: -----> Deploying myapp via Docker...\n"
        "remote: =====> Application deployed:\n"
        "remote:        https://myapp.example.com\n"
        "   abc1234..def5678  main -> main\n"
    )))


def test_routine_output_for_the_other_operations() raises:
    """The remaining ops' boring shapes, and one non-boring counterpart
    each: a talkative hook on commit, and a merge that reports a
    conflict."""
    var commit = GitOutputMatcher(GIT_OUT_COMMIT)
    assert_true(commit.is_routine(String(
        "[main 3fdfe00] Split the tests into per-topic suites\n"
        " 3 files changed, 41 insertions(+), 9 deletions(-)\n"
        " create mode 100644 tests/test_case_fold.mojo\n"
    )))
    # Verbatim from a real ``git commit`` — the first commit in a repo
    # gets an extra ``(root-commit)`` token inside the brackets, which is
    # not a shape you'd think to write by hand.
    assert_true(commit.is_routine(String(
        "[main (root-commit) f9618b8] test subject\n"
        " 1 file changed, 1 insertion(+)\n"
        " create mode 100644 a.txt\n"
    )))
    # Likewise verbatim: a checkout that carried local modifications
    # across, which git reports as tab-separated status lines.
    var co = GitOutputMatcher(GIT_OUT_CHECKOUT)
    assert_true(co.is_routine(String(
        "Already on 'main'\n"
        "M\tsrc/turbokod/local_changes.mojo\n"
        "Your branch is up to date with 'origin/main'.\n"
    )))
    assert_false(commit.is_routine(String(
        "black....................................................Failed\n"
        "- hook id: black\n"
        "[main 3fdfe00] wip\n"
    )))

    var checkout = GitOutputMatcher(GIT_OUT_CHECKOUT)
    assert_true(checkout.is_routine(String(
        "Switched to branch 'main'\n"
        "Your branch is up to date with 'origin/main'.\n"
    )))
    assert_true(checkout.is_routine(String("Already on 'main'\n")))

    var merge = GitOutputMatcher(GIT_OUT_MERGE)
    assert_true(merge.is_routine(String(
        "Updating 3fdfe00..bfc8c4a\n"
        "Fast-forward\n"
        " src/turbokod/git_output.mojo | 12 ++++++++++++\n"
        " 1 file changed, 12 insertions(+)\n"
    )))
    assert_false(merge.is_routine(String(
        "Auto-merging src/turbokod/editor.mojo\n"
        "CONFLICT (content): Merge conflict in src/turbokod/editor.mojo\n"
        "Automatic merge failed; fix conflicts and then commit the result.\n"
    )))

    var delete = GitOutputMatcher(GIT_OUT_BRANCH_DELETE)
    assert_true(delete.is_routine(
        String("Deleted branch merged-x (was 3fdfe00).\n"),
    ))

    # GIT_OUT_OTHER recognizes nothing, so any output at all shows.
    var other = GitOutputMatcher(GIT_OUT_OTHER)
    assert_true(other.is_routine(String("")))
    assert_false(other.is_routine(String("anything at all\n")))


def test_complete_lines_drops_a_partial_tail() raises:
    """Live classification must only judge whole lines: half of
    ``remote: Resolving deltas`` would not match the pattern that the
    whole line does, and would promote the spinner for nothing."""
    assert_equal(
        complete_lines(String("one\ntwo\nthr")), String("one\ntwo\n"),
    )
    assert_equal(complete_lines(String("one\n")), String("one\n"))
    assert_equal(complete_lines(String("no newline yet")), String(""))
    assert_equal(complete_lines(String("")), String(""))
    # And the partial-line case really would have misfired.
    var m = GitOutputMatcher(GIT_OUT_PUSH)
    var partial = String("Everything up-to-date\nremote: Resolving del")
    assert_false(m.is_routine(partial))
    assert_true(m.is_routine(complete_lines(partial)))


def test_deploy_log_promotes_the_spinner_to_full_screen() raises:
    """A push starts as the corner spinner and only grows into the whole
    view once the remote says something unexpected — which is what makes
    the ordinary push unintrusive and the deploy watchable, from the same
    keystroke. The decision is sticky: routine lines arriving afterwards
    must not shrink a live deploy log back into the corner."""
    var lc = _local_changes_with_branches()
    # Stand in for a push in flight; we drive the capture by hand rather
    # than needing a remote.
    lc._git_op = _GITOP_PUSH
    lc._output_kind = GIT_OUT_PUSH
    lc._output_promoted = False
    lc.git_runner.output = String("Enumerating objects: 5, done.\n")
    lc._promote_if_interesting()
    assert_false(lc._output_promoted)
    assert_false(lc.git_runner.full_screen)
    # A partial line must not decide anything either way.
    lc.git_runner.output += String("remote: -----> Buil")
    lc._promote_if_interesting()
    assert_false(lc.git_runner.full_screen)
    # Completed, it does.
    lc.git_runner.output += String("ding myapp from Dockerfile\n")
    lc._promote_if_interesting()
    assert_true(lc._output_promoted)
    assert_true(lc.git_runner.full_screen)
    # Sticky.
    lc.git_runner.output += String("   abc1234..def5678  main -> main\n")
    lc._promote_if_interesting()
    assert_true(lc.git_runner.full_screen)
    lc._git_op = _GITOP_NONE


def test_local_changes_success_flashes_without_a_modal() raises:
    """A successful op must not leave a box in the way. Its summary lands
    on the sub-title row, the overlay stays shut, and the next keystroke
    reaches the view instead of being eaten as a dismissal."""
    var dir = _init_repo_with_branches()
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_BRANCHES
    if not _select_branch(lc, String("merged-x")):
        _rm_rf(dir)
        return
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x64)), screen, registry)
    _drain_git_op(lc)
    # git printed "Deleted branch merged-x (was …)" — so this is the case
    # a literal "only skip when there's no output" rule would still have
    # popped a modal for.
    assert_true(len(lc.flash_message.as_bytes()) > 0)
    assert_equal(lc.overlay, _OVERLAY_NONE)
    # The flash is painted on the sub-title row, in place of the root.
    var canvas = Canvas(screen.width(), screen.height())
    lc.paint(canvas, screen, registry)
    var bounds = lc._panel_rect(screen)
    var row = String("")
    for x in range(bounds.a.x + 1, bounds.b.x - 1):
        row += canvas.get(x, bounds.a.y + 1).glyph
    assert_true(_contains(row, lc.flash_message))
    # And a keystroke afterwards is handled normally, not swallowed. Park
    # the cursor on row 0 first: the delete left ``sel_branch`` wherever
    # ``merged-x`` used to be, and ``fetch_git_branches`` sorts by
    # committer date — whether the surviving branches' commits land in the
    # same wall-clock second decides the order, so that row is sometimes
    # the last one, where Down legitimately can't move.
    if len(lc.branches) > 1:
        lc.sel_branch = 0
        _ = lc.handle_key(_key(KEY_DOWN), screen, registry)
        assert_equal(lc.sel_branch, 1)
    _rm_rf(dir)


def test_local_changes_failure_shows_the_whole_output() raises:
    """The other half of the rule: an op that didn't produce the routine
    success output stops and shows all of it, because nothing else on
    screen explains what happened. Merging a nonexistent branch is the
    cheapest way to make git exit non-zero with something to say."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 1                       # feature-x, not a real branch
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x4D)), screen, registry)
    _ = lc.handle_key(_key(UInt32(0x6D)), screen, registry)   # 'm': merge commit
    assert_equal(lc._git_op, _GITOP_MERGE)
    _drain_git_op(lc)
    assert_equal(lc.overlay, _OVERLAY_OUTPUT)
    assert_equal(len(lc.flash_message.as_bytes()), 0)
    assert_true(len(lc.overlay_output.as_bytes()) > 0)
    # Arrows scroll rather than dismiss — a log you can't page through
    # would be worse than the one-liner it replaced.
    _ = lc.handle_key(_key(KEY_DOWN), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_OUTPUT)
    # ESC closes.
    _ = lc.handle_key(_key(KEY_ESC), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_NONE)


def test_local_changes_flash_expires_on_its_own() raises:
    """The flash ages out without any input — that's what makes it
    non-blocking rather than just quieter."""
    var lc = _local_changes_with_branches()
    lc.sel_branch = 0
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(Event.key_event(KEY_SPACE), screen, registry)
    assert_true(len(lc.flash_message.as_bytes()) > 0)
    # tick() inside the window leaves it alone...
    lc.tick()
    assert_true(len(lc.flash_message.as_bytes()) > 0)
    # ...and drops it once the deadline has passed.
    lc._flash_until_ms = 0
    lc.tick()
    assert_equal(len(lc.flash_message.as_bytes()), 0)


def test_local_changes_d_on_rebased_branch_deletes_immediately() raises:
    """The user-visible payoff: a branch whose commits landed in main via
    rebase deletes on ``d`` with no confirmation, even though git itself
    would refuse ``git branch -d`` on it."""
    var dir = _init_repo_with_branches()
    if len(dir.as_bytes()) == 0:
        return
    var lc = LocalChanges()
    lc.open(dir)
    lc.focus = _PANE_BRANCHES
    if not _select_branch(lc, String("rebased-x")):
        _rm_rf(dir)
        return
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(_key(UInt32(0x64)), screen, registry)
    assert_equal(lc.overlay, _OVERLAY_NONE)
    assert_equal(lc._git_op, _GITOP_BRANCH_DELETE)
    _drain_git_op(lc)
    var after = fetch_git_branches(dir)
    for i in range(len(after)):
        assert_true(after[i].name != String("rebased-x"))
    _rm_rf(dir)


def test_git_view_overlay_editor_releases_its_find_regex() raises:
    """The commit-message editor hands its compiled Find regex back.

    It is the only ``Editor`` in the tree that doesn't live inside a
    ``Window``, so ``Desktop.shutdown``'s per-window walk cannot reach it.
    Nothing runs a Find in it today; this pins the invariant so that stays
    true if Find is ever wired into the reword box, and covers both
    discard points — ``close`` (user closes the view) and ``release``
    (the window is going away).
    """
    onig_global_init()
    var live = onig_tracked_count()
    var lc = LocalChanges()
    # The default search options are case-*insensitive*, which is the
    # configuration that has to go through libonig.
    _ = lc.overlay_editor.find_next(String("wip"))
    assert_true(onig_tracked_count() > live)
    lc.close()
    assert_equal(onig_tracked_count(), live)
    # ``release`` is independently sufficient — ``close`` need not have run.
    _ = lc.overlay_editor.find_next(String("wip"))
    assert_true(onig_tracked_count() > live)
    lc.release()
    assert_equal(onig_tracked_count(), live)


def test_local_changes_release_stops_an_in_flight_git_child() raises:
    """``release`` is the window-is-going-away path, so it has to stop the
    git child too.

    ``git_runner`` is a second ``InstallRunner`` alongside the one
    ``Desktop`` owns for installs, so ``Desktop.shutdown``'s
    ``install_runner.terminate()`` never reached it: closing a window
    during a push or pull to a slow remote left the git child running
    with our three pipe descriptors held. ``kill(pid, 0)`` failing is
    what proves it was reaped rather than merely signalled — a zombie
    would still answer.
    """
    var lc = _local_changes_with_branches()
    lc.sel_branch = 1                       # feature-x
    var screen = Rect(0, 0, 100, 30)
    var registry = GrammarRegistry()
    _ = lc.handle_key(Event.key_event(KEY_SPACE), screen, registry)
    assert_true(lc.git_runner.is_active())
    var pid = lc.git_runner.process.pid
    assert_true(pid > 0)
    lc.release()
    assert_false(lc.git_runner.is_active())
    assert_true(Int(kill_pid(pid, Int32(0))) != 0)
    registry.release()


def main() raises:
    setup_test_env()
    test_git_view_overlay_editor_releases_its_find_regex()
    test_diff3_merge_clean_when_only_ours_changed()
    test_diff3_merge_clean_when_only_theirs_changed()
    test_diff3_merge_clean_when_changes_disjoint()
    test_diff3_merge_identical_changes_dont_conflict()
    test_diff3_merge_conflict_when_both_edit_same_line()
    test_diff3_regions_all_stable_when_only_ours_changed()
    test_diff3_regions_conflict_boundaries()
    test_diff3_regions_multiple_conflicts()
    test_merge_view_resolved_text_all_local()
    test_merge_view_resolved_text_all_disk()
    test_merge_view_resolved_text_both()
    test_review_window_does_not_pollute_view_state()
    test_review_window_not_counted_as_document()
    test_review_teardown_saves_and_closes_editable_window()
    test_review_goto_change_saves_edits()
    test_review_progress_spans_whole_changeset()
    test_git_gutter_no_diff_when_buffer_matches_crlf_head()
    test_gitignore_matches_directory_pattern()
    test_gitignore_matches_glob_and_negate()
    test_diff_grammar_paints_inserted_deleted_and_hunk_header()
    test_diff_identical_inputs_have_no_hunks()
    test_diff_lines_pure_insert()
    test_diff_lines_pure_delete()
    test_diff_lines_replace_round_trips()
    test_unified_diff_renders_hunk_header_and_marks()
    test_git_blame_parses_two_line_porcelain()
    test_git_blame_captures_commit_detail_metadata()
    test_git_blame_propagates_full_metadata_across_a_group()
    test_git_blame_time_formats_in_the_authors_zone()
    test_git_blame_propagates_cached_author_for_repeated_sha()
    test_git_blame_marks_uncommitted_with_zero_sha_and_placeholder()
    test_diff_buffer_against_head_marks_added_and_modified()
    test_diff_modified_line_keeps_inserted_block_added()
    test_diff_buffer_marks_flags_pure_deletion_above()
    test_diff_buffer_marks_modify_is_not_a_deletion()
    test_diff_row_line_label_basics()
    test_diff_rows_removed_lines_have_no_line_number()
    test_diff_rows_pure_insertion_all_numbered()
    test_diff_rows_multiline_removal_numbers_skip_removed()
    test_diff_rows_inserted_block_before_modified_line()
    test_diff_view_renders_removed_rows_without_line_numbers()
    test_diff_view_modified_line_shows_old_removed_and_new_added()
    test_diff_view_phantom_syntax_overlay()
    test_diff_view_unhighlighted_text_uses_identifier_color()
    test_diff_view_dims_unchanged_context_lines()
    test_diff_row_emphasis_marks_changed_spans()
    test_diff_row_emphasis_pairs_by_similarity()
    test_diff_row_partner_matches_across_inserted_comment()
    test_diff_row_partner_skips_dissimilar_in_restructure()
    test_diff_view_intraline_emphasis_render()
    test_goto_change_chunk_navigates_and_builds_preview()
    test_revert_chunk_at_cursor_restores_head()
    test_local_changes_open_records_status_when_clean()
    test_local_changes_space_on_branch_checks_it_out()
    test_local_changes_space_on_current_branch_is_a_noop()
    test_branch_is_merged_reads_the_main_line()
    test_branch_is_merged_sees_through_rebase_and_squash()
    test_local_changes_d_on_rebased_branch_deletes_immediately()
    test_routine_push_output_is_recognized()
    test_git_output_matchers_compile_each_kind_once()
    test_deploy_log_is_not_routine_push_output()
    test_routine_output_for_the_other_operations()
    test_complete_lines_drops_a_partial_tail()
    test_deploy_log_promotes_the_spinner_to_full_screen()
    test_local_changes_success_flashes_without_a_modal()
    test_local_changes_failure_shows_the_whole_output()
    test_local_changes_flash_expires_on_its_own()
    test_local_changes_shift_m_asks_merge_commit_or_straight_history()
    test_local_changes_merge_choice_m_spawns_a_no_ff_merge()
    test_local_changes_merge_choice_r_spawns_a_rebase()
    test_rebase_preserves_current_branch_shas()
    test_rebase_success_output_is_routine()
    test_autostash_pull_output_is_routine()
    test_local_changes_shift_m_on_current_branch_is_a_noop()
    test_local_changes_d_on_current_branch_is_refused()
    test_local_changes_d_on_unmerged_branch_confirms_first()
    test_local_changes_d_on_merged_branch_deletes_immediately()
    test_format_age_picks_one_unit()
    test_local_changes_branch_pane_paints_age_column()
    test_fetch_git_branches_carries_age_newest_first()
    test_local_changes_commit_message_url_is_underlined()
    test_local_changes_click_on_commit_message_url_opens_browser()
    test_local_changes_sidebar_splitter_drag_resizes_right_pane()
    test_local_changes_untracked_file_shows_its_whole_contents()
    test_local_changes_untracked_empty_file_has_no_body_rows()
    test_git_state_mtimes_zero_for_non_repo()
    test_git_state_mtimes_nonzero_after_init_commit()
    test_stage_unstage_round_trip_against_real_git()
    test_fetch_git_status_expands_untracked_directories()
    test_local_changes_files_panel_is_a_tree()
    test_merge_commit_log_lists_the_commits_it_brought_in()
    test_merge_commit_info_panel_shows_merged_commits_section()
    test_review_mode_builds_changeset_model()
    test_fetch_commit_message_returns_full_body()
    test_head_short_sha_matches_the_top_of_the_log()
    test_create_reworded_commit_keeps_tree_and_parent()
    test_has_merge_between_is_false_on_a_linear_history()
    test_local_changes_e_refuses_a_pushed_commit()
    test_local_changes_e_refuses_a_merge_commit()
    test_local_changes_e_opens_prefilled_editor_and_esc_cancels()
    test_reword_editor_supports_keyboard_selection()
    test_reword_editor_supports_mouse_selection_and_undo()
    test_local_changes_reword_head_amends_the_message()
    test_local_changes_reword_older_commit_keeps_its_children()
    test_local_changes_release_stops_an_in_flight_git_child()
    print("git: 106 tests passed")
