"""Dialogs, pickers and input widgets.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas, wrap_to_width
from turbokod.dir_browser import DirBrowser
from turbokod.painter import Painter
from turbokod.cell import Cell
from turbokod.colors import (
    Attr, BLACK, BLUE, CYAN, LIGHT_GRAY, WHITE, default_attr
)
from turbokod.theme import Theme
from turbokod.editor import Editor
from turbokod.file_dialog import FileDialog
from turbokod.find_symbol import (
    container_matches_qualifier, sanitize_symbol_query, _query_member,
    _query_qualifier
)
from turbokod.color_convert import (
    srgb_to_rgb255, rgb255_to_srgb, srgb_to_oklab, oklab_to_srgb, srgb_to_hsl,
    hsl_to_srgb, format_rgb, format_hsl, format_hex, fmt_fixed, parse_float
)
from turbokod.color_picker import (
    ColorPickerDialog, MODE_OKLAB, MODE_RGB, MODE_HSL
)
from turbokod.desktop import (
    Desktop, EDITOR_SAVE, PROJECT_FIND, _find_doc_entry_for_word
)
from turbokod.file_io import find_git_project, join_path, stat_file, write_file
from turbokod.menu import Menu, MenuBar, MenuItem
from turbokod.project import ProjectMatch, find_in_project, walk_project_files
from turbokod.find_results_pane import FindResultsPane
from turbokod.search_options import SearchOptions
from turbokod.text_field import TextField
from turbokod.quick_open import QuickOpen, quick_open_match
from turbokod.doc_store import DocEntry
from turbokod.language_config import built_in_servers
from turbokod.list_box import ListBox
from turbokod.lsp import capture_command
from turbokod.posix import monotonic_ms, which
from turbokod.spell import find_misspelled_runs
from turbokod.action_editor import ActionEditor
from turbokod.config import (
    LanguageServerOverride, MIN_FONT_SIZE, OnSaveAction, TurbokodConfig
)
from turbokod.dropdown import Dropdown
from turbokod.settings import (
    Settings, _FOCUS_LS_INLAY_HINTS, _FOCUS_MAX_WINDOWS
)
from turbokod.events import (
    Event, KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_TAB,
    KEY_UP, MOD_ALT, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP
)
from turbokod.geometry import Point, Rect
from turbokod.confirm_dialog import ConfirmDialog
from turbokod.prompt import Prompt
from turbokod.view import centered

from turbokod.buttons import (
    BUTTON_CANCELED, BUTTON_CAPTURED, BUTTON_FIRED, BUTTON_NONE,
    ShadowButton, paint_shadow_button, shadow_button_hit
)
from turbokod.dir_browser import jump_shortcuts
from turbokod.colors import GREEN

from support import (
    _contains, _key, _ps_open, _spell_with_dict, _starts_with, _temp_path,
    setup_test_env
)


def _ends_with(s: String, suffix: String) -> Bool:
    var sb = s.as_bytes()
    var fb = suffix.as_bytes()
    if len(fb) > len(sb):
        return False
    for i in range(len(fb)):
        if sb[len(sb) - len(fb) + i] != fb[i]:
            return False
    return True


def test_find_results_pane_multiselect() raises:
    # Build a pane with 5 results and stamp the painted geometry so
    # ``handle_mouse`` can map a click's y back to a row index (row r is
    # at y == _list_top + r when scroll is 0).
    var matches = List[ProjectMatch]()
    for i in range(5):
        matches.append(ProjectMatch(
            String("/proj/file") + String(i) + String(".txt"),
            String("file") + String(i) + String(".txt"),
            i + 1, String("hit ") + String(i),
        ))
    var pane = FindResultsPane()
    pane.load(matches^, String("hit"), String("/proj"))
    pane.focused = True
    pane._list_top = 1
    pane._list_height = 5
    var panel = Rect(0, 0, 40, 8)

    # Plain click selects exactly one row; nothing is marked yet.
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(5, 1 + 1), MOUSE_BUTTON_LEFT, True, False, MOD_NONE, 1,
        ),
        panel,
    )
    assert_equal(pane.selected, 1)
    assert_equal(pane._marked_count(), 0)

    # Cmd-click toggles individual rows into the multi-select set.
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(5, 1 + 1), MOUSE_BUTTON_LEFT, True, False, MOD_META, 1,
        ),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(5, 1 + 3), MOUSE_BUTTON_LEFT, True, False, MOD_META, 1,
        ),
        panel,
    )
    assert_true(pane.marked[1])
    assert_true(pane.marked[3])
    assert_equal(pane._marked_count(), 2)

    # Enter opens every marked hit (preserving order), then the queue drains.
    _ = pane.handle_key(Event.key_event(KEY_ENTER, MOD_NONE))
    var opened = pane.take_pending_opens()
    assert_equal(len(opened), 2)
    assert_equal(opened[0].line_no, 2)   # row 1 -> 1-based line 2
    assert_equal(opened[1].line_no, 4)   # row 3 -> 1-based line 4
    assert_equal(len(pane.take_pending_opens()), 0)

    # Shift-click selects a contiguous range from the anchor (row 3, set by
    # the last Cmd-click) to the clicked row 0 -> rows 0..3 marked.
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(5, 1 + 0), MOUSE_BUTTON_LEFT, True, False, MOD_SHIFT, 1,
        ),
        panel,
    )
    assert_equal(pane._marked_count(), 4)
    assert_true(pane.marked[0])
    assert_true(pane.marked[3])
    assert_false(pane.marked[4])

    # A plain click clears the multi-select set.
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(5, 1 + 2), MOUSE_BUTTON_LEFT, True, False, MOD_NONE, 1,
        ),
        panel,
    )
    assert_equal(pane._marked_count(), 0)
    assert_equal(pane.selected, 2)

    # Double-click opens just the clicked row when nothing is marked.
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(5, 1 + 2), MOUSE_BUTTON_LEFT, True, False, MOD_NONE, 2,
        ),
        panel,
    )
    var dbl = pane.take_pending_opens()
    assert_equal(len(dbl), 1)
    assert_equal(dbl[0].line_no, 3)


def test_find_in_project_options_smoke() raises:
    """Sanity check that project search compiles and runs with
    options. Picks a string the test file itself contains."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var opts = SearchOptions(True, False, False)
    var matches = find_in_project(
        root.value(), String("Turbokod: a Mojo-idiomatic port"), opts,
    )
    assert_true(len(matches) >= 1)


def test_find_git_project() raises:
    """Tests run from the repo root, which has a .git folder, so opening
    a file inside the repo should locate the project root."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    # The project root contains examples/, src/, and .git.
    var info = stat_file(join_path(root.value(), String(".git")))
    assert_true(info.ok)
    var examples = stat_file(join_path(root.value(), String("examples")))
    assert_true(examples.ok)


def test_walk_project_files_finds_known_files() raises:
    """The repo root has examples/, src/, tests/ — all should be reachable.

    ``.gitignore`` itself must be reachable (quick open lists it), but
    nothing under ``.git`` or gitignored trees like ``.pixi`` may leak."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var paths = walk_project_files(root.value())
    assert_true(len(paths) > 5)
    var saw_hello = False
    var saw_test = False
    var saw_dotfile = False
    var saw_gitignore = False
    for i in range(len(paths)):
        if _ends_with(paths[i], String("examples/hello.mojo")):
            saw_hello = True
        if _ends_with(paths[i], String("tests/support.mojo")):
            saw_test = True
        if _ends_with(paths[i], String("/.gitignore")):
            saw_gitignore = True
        if _contains(paths[i], String("/.git/")) \
                or _contains(paths[i], String("/.pixi/")):
            saw_dotfile = True
    assert_true(saw_hello)
    assert_true(saw_test)
    assert_true(saw_gitignore)
    assert_false(saw_dotfile)


def test_find_in_project_locates_string() raises:
    """Search the repo for a string that's known to live in exactly one place."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var matches = find_in_project(root.value(), String("Turbokod: a Mojo-idiomatic port"))
    assert_true(len(matches) >= 1)
    var found_in_init = False
    for i in range(len(matches)):
        if matches[i].rel == String("src/turbokod/__init__.mojo"):
            found_in_init = True
            assert_true(matches[i].line_no >= 1)
    assert_true(found_in_init)


def test_dropdown_reserves_indent_for_checkable_items() raises:
    """A dropdown that contains any checkable item must reserve a 2-cell
    label-indent so the ``✓`` glyph slot is consistent across rows.
    ``set_item_checked`` flips state by action without disturbing the
    rest of the menu."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(
        String("Line Numbers"), String("view:ln"), checkable=True,
    ))
    items.append(MenuItem(
        String("Soft Wrap"), String("view:sw"), checkable=True,
    ))
    bar.add(Menu(String("View"), items^))
    bar.open_idx = 0
    assert_true(bar._menu_has_checkable(0))
    var dr = bar._dropdown_rect(80)
    var widest_label = len(String("Line Numbers").as_bytes())
    # 2 (left pad) + 2 (checkbox slot) + label + 2 (right pad)
    var expected_min_w = widest_label + 6
    assert_true(dr.b.x - dr.a.x >= expected_min_w)
    bar.set_item_checked(String("view:ln"), True)
    assert_true(bar.menus[0].items[0].checked)
    assert_false(bar.menus[0].items[1].checked)
    bar.set_item_checked(String("view:ln"), False)
    assert_false(bar.menus[0].items[0].checked)


def test_dropdown_widens_to_fit_shortcut() raises:
    """The dropdown rect must accommodate label + gap + shortcut; without
    the widening, ``Cmd+Shift+F`` would overlap the menu item label."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    var save = MenuItem(String("Save"), EDITOR_SAVE)
    save.shortcut = String("Cmd+S")
    items.append(save)
    var pf = MenuItem(String("Find in project..."), PROJECT_FIND)
    pf.shortcut = String("Cmd+Shift+F")
    items.append(pf)
    bar.add(Menu(String("Edit"), items^))
    bar.open_idx = 0
    var dr = bar._dropdown_rect(80)
    var widest_label = len(String("Find in project...").as_bytes())
    var widest_sc = len(String("Cmd+Shift+F").as_bytes())
    # 2 (left pad) + label + 2 (gap) + shortcut + 2 (right pad)
    var expected_min_w = widest_label + widest_sc + 6
    assert_true(dr.b.x - dr.a.x >= expected_min_w)


def test_walk_project_files_respects_gitignore() raises:
    """A directory-only ``.gitignore`` pattern (``vendored/``) excludes the
    entire subtree from the default walk; ``respect_gitignore=False``
    reaches into it. Self-contained temp fixture — previously this test
    depended on the repo's own ``tvision/`` subtree, which broke once
    that vendored copy stopped being checked out on every dev machine.
    Use a temp dir we fully control instead."""
    var root = _temp_path(String("_walk_gitignore"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var vend = join_path(root, String("vendored"))
    _ = external_call["mkdir", Int32](
        (vend + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(
        join_path(root, String(".gitignore")), String("vendored/\n"),
    ))
    assert_true(write_file(
        join_path(root, String("kept.txt")), String("real\n"),
    ))
    assert_true(write_file(
        join_path(vend, String("buried.txt")), String("noise\n"),
    ))

    var paths = walk_project_files(root)
    var saw_vendored = False
    for i in range(len(paths)):
        if _contains(paths[i], String("/vendored/")):
            saw_vendored = True
            break
    assert_false(saw_vendored)

    # Without gitignore respect, the walk reaches into vendored/.
    var all_paths = walk_project_files(root, respect_gitignore=False)
    var any_vendored = False
    for i in range(len(all_paths)):
        if _contains(all_paths[i], String("/vendored/")):
            any_vendored = True
            break
    assert_true(any_vendored)


def test_walk_project_files_include_ignored_files_keeps_files_prunes_dirs() raises:
    """``include_ignored_files=True`` is the QuickOpen mode: a gitignored
    *file* like ``settings_local.py`` must appear (so users can open it),
    while a gitignored *directory* like ``node_modules`` must still be
    pruned (so its contents don't flood the picker)."""
    var root = _temp_path(String("_walk_ignored_files"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var nm = join_path(root, String("node_modules"))
    _ = external_call["mkdir", Int32](
        (nm + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(
        join_path(root, String(".gitignore")),
        String("settings_local.py\nnode_modules\n"),
    ))
    assert_true(write_file(
        join_path(root, String("settings.py")), String("# main\n"),
    ))
    assert_true(write_file(
        join_path(root, String("settings_local.py")), String("# local\n"),
    ))
    assert_true(write_file(
        join_path(nm, String("dep.js")), String("// noise\n"),
    ))

    # Default strict mode: ignored file is hidden, ignored dir is pruned.
    var strict = walk_project_files(root)
    var strict_saw_local = False
    var strict_saw_node = False
    for i in range(len(strict)):
        if _contains(strict[i], String("settings_local.py")):
            strict_saw_local = True
        if _contains(strict[i], String("/node_modules/")):
            strict_saw_node = True
    assert_false(strict_saw_local)
    assert_false(strict_saw_node)

    # Picker mode: ignored file shows up; ignored dir still pruned.
    var picker = walk_project_files(root, include_ignored_files=True)
    var picker_saw_local = False
    var picker_saw_main = False
    var picker_saw_node = False
    for i in range(len(picker)):
        if _contains(picker[i], String("settings_local.py")):
            picker_saw_local = True
        if _contains(picker[i], String("/settings.py")):
            picker_saw_main = True
        if _contains(picker[i], String("/node_modules/")):
            picker_saw_node = True
    assert_true(picker_saw_local)
    assert_true(picker_saw_main)
    assert_false(picker_saw_node)

    _ = external_call["unlink", Int32](
        (join_path(nm, String("dep.js")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32]((nm + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32](
        (join_path(root, String("settings_local.py")) + String("\0"))
        .unsafe_ptr(),
    )
    _ = external_call["unlink", Int32](
        (join_path(root, String("settings.py")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["unlink", Int32](
        (join_path(root, String(".gitignore")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_walk_project_files_git_fast_path_includes_ignored_files() raises:
    """Same contract as the manual-walk test above, but through the git
    fast path (``root`` is a real checkout, so ``walk_project_files``
    shells out to ``git ls-files``). ``include_ignored_files=True`` must
    surface a file the ``.gitignore`` names explicitly while still
    pruning the contents of an ignored *directory* — previously the fast
    path dropped the flag entirely and ignored files never made the
    quick-open list on git projects."""
    var root = _temp_path(String("_walk_git_ignored"))
    var init = List[String]()
    init.append(String("git"))
    init.append(String("init"))
    init.append(String("-q"))
    init.append(root)
    var cap = capture_command(init)
    if Int(cap.status) != 0:
        return  # no git available — fast path can't be exercised
    var nm = join_path(root, String("node_modules"))
    _ = external_call["mkdir", Int32](
        (nm + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(
        join_path(root, String(".gitignore")),
        String("settings_local.py\nnode_modules/\n"),
    ))
    assert_true(write_file(
        join_path(root, String("settings.py")), String("# main\n"),
    ))
    assert_true(write_file(
        join_path(root, String("settings_local.py")), String("# local\n"),
    ))
    assert_true(write_file(
        join_path(nm, String("dep.js")), String("// noise\n"),
    ))

    # Default strict mode: ignored file hidden, ignored dir pruned.
    var strict = walk_project_files(root)
    var strict_saw_local = False
    for i in range(len(strict)):
        if _contains(strict[i], String("settings_local.py")):
            strict_saw_local = True
    assert_false(strict_saw_local)

    # Picker mode: ignored file shows up; ignored dir contents stay out.
    var picker = walk_project_files(root, include_ignored_files=True)
    var picker_saw_local = False
    var picker_saw_main = False
    var picker_saw_node = False
    for i in range(len(picker)):
        if _contains(picker[i], String("settings_local.py")):
            picker_saw_local = True
        if _contains(picker[i], String("/settings.py")):
            picker_saw_main = True
        if _contains(picker[i], String("/node_modules/")):
            picker_saw_node = True
    assert_true(picker_saw_local)
    assert_true(picker_saw_main)
    assert_false(picker_saw_node)

    # ``.git`` is deep — clean up with rm -rf rather than unlink/rmdir.
    var rm = List[String]()
    rm.append(String("rm"))
    rm.append(String("-rf"))
    rm.append(root)
    _ = capture_command(rm)


def test_settings_open_seeds_state() raises:
    """Settings ``open`` parks focus on the section rail (arrow keys move
    sections) and starts not-dirty."""
    var s = Settings()
    s.open(False)
    assert_true(s.active)
    assert_equal(s.section, 0)
    assert_false(s.dirty)
    s.close()
    assert_false(s.active)


def test_settings_language_server_section_seeds_and_toggles() raises:
    """The Language Server section seeds its checkboxes from the ``ls_*``
    params, and toggling one flips the working copy + raises dirty so the
    host's persistence loop writes it back."""
    var s = Settings()
    s.open(
        False, List[LanguageServerOverride](),
        String(""), True, True, False, String("Turbo C++ 3.0"),
        String(""), List[String](), 0, 0, 0, 0, -1, 20, True,
        ls_format_on_save=True,
        ls_signature_help=False,
        ls_inlay_hints=True,
    )
    assert_true(s.ls_format_on_save)
    assert_false(s.ls_signature_help)
    assert_true(s.ls_inlay_hints)
    # Defaults for params left unspecified.
    assert_true(s.ls_document_highlight)
    assert_false(s.ls_code_lens)
    assert_false(s.dirty)
    # Toggling by focus id flips the working copy and marks dirty.
    _ = s._toggle_ls_focus(_FOCUS_LS_INLAY_HINTS)
    assert_false(s.ls_inlay_hints)
    assert_true(s.dirty)


def test_settings_windowed_default_is_centered_dialog() raises:
    """In-grid (terminal) Settings is a centered floating dialog, not a
    workspace takeover — the editor behind it stays visible so a theme
    change retints it live. The first paint establishes the default
    bounds inside the workspace (rows 1..h-1, menu/status excluded)."""
    var s = Settings()
    s.open(False)
    var c = Canvas(100, 40)
    c.clear(default_attr())
    s.paint(c, Rect(0, 0, 100, 40))
    assert_true(s.bounds.a.y >= 1)
    assert_true(s.bounds.b.y <= 39)
    assert_true(s.bounds.width() <= 104)
    assert_true(s.bounds.a.x > 0)
    # The dialog's top-left corner carries the double-line box; a cell
    # left of the dialog is untouched workspace.
    assert_equal(
        c.get(s.bounds.a.x, s.bounds.a.y).glyph, String("╔"),
    )
    var outside = c.get(0, s.bounds.a.y)
    assert_equal(outside.attr.fg, default_attr().fg)
    assert_equal(outside.attr.bg, default_attr().bg)


def test_settings_windowed_move_and_resize() raises:
    """Dragging the title row moves the dialog; dragging the bottom-right
    corner resizes it (mirrors WindowStack's chrome). The drag owns events
    until release, and sizes clamp to the minimums."""
    var s = Settings()
    s.open(False)
    var screen = Rect(0, 0, 100, 40)
    var c = Canvas(100, 40)
    s.paint(c, screen)   # establish default bounds
    var b0 = s.bounds
    # Move: press on the title row, drag +3 cols / +2 rows, release.
    _ = s.handle_mouse(Event.mouse_event(
        Point(b0.a.x + 5, b0.a.y), MOUSE_BUTTON_LEFT, True, False,
    ), screen)
    _ = s.handle_mouse(Event.mouse_event(
        Point(b0.a.x + 8, b0.a.y + 2), MOUSE_BUTTON_LEFT, True, True,
    ), screen)
    _ = s.handle_mouse(Event.mouse_event(
        Point(b0.a.x + 8, b0.a.y + 2), MOUSE_BUTTON_LEFT, False, False,
    ), screen)
    assert_equal(s.bounds.a.x, b0.a.x + 3)
    assert_equal(s.bounds.a.y, b0.a.y + 2)
    assert_equal(s.bounds.width(), b0.width())
    assert_equal(s.bounds.height(), b0.height())
    # Resize: press the bottom-right corner, drag inward 10 cols / 3 rows.
    var b1 = s.bounds
    _ = s.handle_mouse(Event.mouse_event(
        Point(b1.b.x - 1, b1.b.y - 1), MOUSE_BUTTON_LEFT, True, False,
    ), screen)
    _ = s.handle_mouse(Event.mouse_event(
        Point(b1.b.x - 11, b1.b.y - 4), MOUSE_BUTTON_LEFT, True, True,
    ), screen)
    _ = s.handle_mouse(Event.mouse_event(
        Point(b1.b.x - 11, b1.b.y - 4), MOUSE_BUTTON_LEFT, False, False,
    ), screen)
    assert_equal(s.bounds.width(), b1.width() - 10)
    assert_equal(s.bounds.height(), b1.height() - 3)
    # Bounds survive close + reopen (session-persistent size/position).
    var kept = s.bounds
    s.close()
    s.open(False)
    s.paint(c, screen)
    assert_equal(s.bounds.a.x, kept.a.x)
    assert_equal(s.bounds.width(), kept.width())


def test_settings_detached_fills_surface() raises:
    """Detached (native settings window) the dialog fills the whole
    surface and skips the in-grid window chrome — the host window
    provides the title bar, close button, and move/resize instead."""
    var s = Settings()
    s.detached = True
    s.open(False)
    var c = Canvas(80, 24)
    c.clear(default_attr())
    s.paint(c, Rect(0, 0, 80, 24))
    # No border box, no " Settings " title — just the dialog bg fill
    # edge to edge.
    assert_equal(c.get(0, 0).glyph, String(" "))
    assert_equal(c.get(79, 23).glyph, String(" "))
    var title_found = False
    for x in range(80):
        if c.get(x, 0).glyph == String("S"):
            title_found = True
    assert_false(title_found)
    # In-grid still draws its own chrome.
    var s2 = Settings()
    s2.open(False)
    var c2 = Canvas(80, 24)
    c2.clear(default_attr())
    s2.paint(c2, Rect(0, 0, 80, 24))
    assert_equal(c2.get(s2.bounds.a.x, s2.bounds.a.y).glyph, String("╔"))


def test_settings_open_empty_parks_selection_at_minus_one() raises:
    """Project Settings on-save with an empty library: selection = -1 so
    Edit / Remove skip themselves in the focus walk."""
    var ps = _ps_open(List[OnSaveAction](), List[OnSaveAction]())
    assert_true(ps.active)
    assert_equal(len(ps._os_union()), 0)
    assert_equal(ps.selected_os, -1)


def test_settings_remove_marks_dirty() raises:
    """Removing the highlighted library entry shrinks the library, raises
    ``on_save_dirty``, and moves the selection to -1 when it empties."""
    var lib = List[OnSaveAction]()
    lib.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    var ps = _ps_open(lib^, List[OnSaveAction]())
    ps.selected_os = 0
    ps._os_remove()
    assert_equal(len(ps.library), 0)
    assert_equal(ps.selected_os, -1)
    assert_true(ps.on_save_dirty)


def test_settings_editor_submit_appends_new_entry() raises:
    """Add → edit fields → submit appends to the library *and* enables it
    for the project (a copy into project_actions), raising on_save_dirty."""
    var ps = _ps_open(List[OnSaveAction](), List[OnSaveAction]())
    ps._os_add()
    assert_true(ps.editor.active)
    ps.editor.entry.language_id = String("python")
    ps.editor.form.set_text(UInt8(1), String("/usr/bin/black"))
    ps.editor.submitted = True
    ps._maybe_consume_editor()
    assert_false(ps.editor.active)
    assert_equal(len(ps.library), 1)
    assert_equal(ps.library[0].language_id, String("python"))
    assert_equal(ps.library[0].program, String("/usr/bin/black"))
    assert_equal(len(ps.project_actions), 1)
    assert_true(ps.on_save_dirty)


def test_settings_editor_submit_replaces_existing_entry() raises:
    """Editing a library entry replaces it in place. With frozen-snapshot
    semantics an already-enabled project copy is left untouched, so the
    edited entry surfaces as a fresh (unticked) suggestion row alongside
    the still-ticked original."""
    var lib = List[OnSaveAction]()
    lib.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    var pa = List[OnSaveAction]()
    pa.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    var ps = _ps_open(lib^, pa^)
    ps.selected_os = 0
    ps._os_edit()
    ps.editor.form.set_text(UInt8(1), String("/opt/bin/black-edge"))
    ps.editor.submitted = True
    ps._maybe_consume_editor()
    # Library entry replaced…
    assert_equal(len(ps.library), 1)
    assert_equal(ps.library[0].program, String("/opt/bin/black-edge"))
    # …project's frozen copy untouched (still the original black)…
    assert_equal(len(ps.project_actions), 1)
    assert_equal(ps.project_actions[0].program, String("/usr/bin/black"))
    # …so the union shows both: edited library row + frozen original.
    assert_equal(len(ps._os_union()), 2)
    assert_true(ps.on_save_dirty)


def test_settings_open_seeds_save_behavior_dropdown() raises:
    """``open(actions, auto_save)`` must seed both the working copy
    and the dropdown's index so the painted strip and the persisted
    value agree on first paint."""
    var s = Settings()
    s.open(True)
    assert_true(s.auto_save)
    assert_equal(s._save_dropdown.index, 1)
    s.close()
    s.open(False)
    assert_false(s.auto_save)
    assert_equal(s._save_dropdown.index, 0)


def test_settings_save_behavior_commit_marks_dirty() raises:
    """Switching the dropdown commits Manual → Automatic, mirrors the
    new value into ``auto_save``, and raises ``dirty`` so the host
    persists ``TurbokodConfig.auto_save`` on the next paint."""
    var s = Settings()
    s.open(False)
    # Simulate the user opening the popup, moving to "Automatic", and
    # pressing Enter — same final state ``Dropdown.handle_key`` lands
    # on, observed by ``_sync_dropdown_commit``.
    var prev_idx = s._save_dropdown.index
    s._save_dropdown.index = 1
    s._sync_dropdown_commit(prev_idx)
    assert_true(s.auto_save)
    assert_true(s.dirty)


def test_settings_save_behavior_no_change_no_dirty() raises:
    """Re-committing the same value (Manual → Manual) must not raise
    ``dirty`` — otherwise the host would write the config on every
    open/close cycle even when nothing changed."""
    var s = Settings()
    s.open(False)
    var prev_idx = s._save_dropdown.index
    # Index unchanged — the dropdown closed without committing a new
    # value (Esc, click-outside, or Enter on the same row).
    s._sync_dropdown_commit(prev_idx)
    assert_false(s.auto_save)
    assert_false(s.dirty)


def test_settings_open_seeds_editor_toggles() raises:
    """``open`` must seed the Editor-section toggle working copies and
    their checkbox glyphs from the passed-in config values (defaulting
    to on)."""
    var s = Settings()
    s.open(
        True,
        List[LanguageServerOverride](), String(""),
        True, True,
    )
    assert_true(s.trim_trailing_whitespace)
    assert_true(s.ensure_final_newline)
    assert_true(s._trim_cb.on)
    assert_true(s._final_nl_cb.on)
    s.close()
    s.open(
        True,
        List[LanguageServerOverride](), String(""),
        False, False,
    )
    assert_false(s.trim_trailing_whitespace)
    assert_false(s.ensure_final_newline)
    assert_false(s._trim_cb.on)
    assert_false(s._final_nl_cb.on)


def test_settings_editor_toggle_marks_dirty() raises:
    """Toggling either Editor checkbox flips the working copy, keeps the
    checkbox glyph in sync, and raises ``dirty`` so the host persists it."""
    var s = Settings()
    s.open(
        True,
        List[LanguageServerOverride](), String(""),
        True, True,
    )
    s._toggle_trim_ws()
    assert_false(s.trim_trailing_whitespace)
    assert_false(s._trim_cb.on)
    assert_true(s.dirty)
    s.dirty = False
    s._toggle_final_nl()
    assert_false(s.ensure_final_newline)
    assert_false(s._final_nl_cb.on)
    assert_true(s.dirty)


def test_settings_max_open_windows_seeds_and_edits() raises:
    """``open`` seeds the max-open-windows field from config (0 → blank =
    no limit; a positive value shows its digits), and the inline editor
    appends digits / backspaces, parsing back to the persisted int while
    raising ``dirty``."""
    var s = Settings()
    s.open(
        True,
        List[LanguageServerOverride](), String(""),
        True, True,
        max_open_windows=20,
    )
    assert_equal(s._mw_tf.text, String("20"))
    assert_equal(s.max_open_windows_value(), 20)
    assert_false(s.dirty)
    # 0 (no limit) renders as an empty field and parses back to 0.
    s.close()
    s.open(
        True,
        List[LanguageServerOverride](), String(""),
        True, True,
        max_open_windows=0,
    )
    assert_equal(len(s._mw_tf.text.as_bytes()), 0)
    assert_equal(s.max_open_windows_value(), 0)
    # Editing the field through the shared TextField (digits append,
    # Backspace removes, value reparses) once it owns focus.
    s.focus = _FOCUS_MAX_WINDOWS
    s.dirty = False
    _ = s.handle_key(Event.key_event(UInt32(ord("5")), MOD_NONE))
    _ = s.handle_key(Event.key_event(UInt32(ord("0")), MOD_NONE))
    assert_equal(s._mw_tf.text, String("50"))
    assert_equal(s.max_open_windows_value(), 50)
    assert_true(s.dirty)
    _ = s.handle_key(Event.key_event(KEY_BACKSPACE, MOD_NONE))
    assert_equal(s.max_open_windows_value(), 5)
    # Non-digit input is filtered out, leaving the value unchanged.
    _ = s.handle_key(Event.key_event(UInt32(ord("x")), MOD_NONE))
    assert_equal(s.max_open_windows_value(), 5)
    # Field is capped at 4 digits so it can't overflow the box.
    s._mw_tf.set_text(String("9999"))
    _ = s.handle_key(Event.key_event(UInt32(ord("9")), MOD_NONE))
    assert_equal(len(s._mw_tf.text.as_bytes()), 4)


def test_settings_languages_section_seeded() raises:
    """``open(... , language_overrides)`` must populate
    ``language_overrides`` and rebuild the effective ``languages_view``
    so the right pane has rows on first paint."""
    var s = Settings()
    var argvs = List[List[String]]()
    var argv = List[String]()
    argv.append(String("custom"))
    argvs.append(argv^)
    var ov = LanguageServerOverride(
        String("xyzlang"), List[String](), argvs^,
    )
    var overrides = List[LanguageServerOverride]()
    overrides.append(ov^)
    s.open(False, overrides^)
    assert_equal(len(s.language_overrides), 1)
    # ``xyzlang`` should appear in the effective view.
    var found = False
    for i in range(len(s.languages_view)):
        if s.languages_view[i].language_id == String("xyzlang"):
            found = True
            break
    assert_true(found)


def test_settings_open_selects_current_language() raises:
    """When ``open`` receives the focused editor's extension, the
    Languages section must pre-select the matching row so the user
    lands on the language they're editing — and the scroll-snap in
    ``_paint_languages_list`` brings that row into view."""
    var s = Settings()
    s.open(False, List[LanguageServerOverride](),
           String("py"))
    var selected_id = s.languages_view[s.selected_language].language_id
    assert_equal(selected_id, String("python"))


def test_settings_open_unknown_extension_falls_back_to_first() raises:
    """An unrecognized extension shouldn't strand the selection on
    -1 — the user can still navigate the list. Fall back to row 0."""
    var s = Settings()
    s.open(False, List[LanguageServerOverride](),
           String("zzzunknownext"))
    assert_equal(s.selected_language, 0)


def test_settings_font_section_requires_host_fonts() raises:
    """The Font section only exists when the host registered font
    options (the native macOS frontend). Without them — the terminal
    frontend — the rail ends at Theme."""
    var s = Settings()
    s.open(False)
    var labels = s._labels()
    # Editor, Spell check, Languages, Theme, Language Server — no Font.
    assert_equal(len(labels), 5)
    assert_equal(labels[3], String("Theme"))
    assert_equal(labels[4], String("Language Server"))
    s.close()
    var fonts = List[String]()
    fonts.append(String("IBM VGA 8x16 (built-in)"))
    fonts.append(String("Menlo"))
    fonts.append(String("Monaco"))
    s.open(
        False, List[LanguageServerOverride](),
        String(""), True, True, False, String("Turbo C++ 3.0"),
        String("Menlo"), fonts^,
    )
    labels = s._labels()
    assert_equal(len(labels), 6)
    assert_equal(labels[5], String("Font"))
    # The active font row is pre-selected.
    assert_equal(s.selected_font, 1)
    assert_equal(s.font_choice, String("Menlo"))


def test_settings_font_step_commits_and_marks_dirty() raises:
    """Arrowing through the Font list commits the new choice and raises
    ``dirty`` so the host applies + persists it — same live-preview
    contract as the Theme list."""
    var s = Settings()
    var fonts = List[String]()
    fonts.append(String("IBM VGA 8x16 (built-in)"))
    fonts.append(String("Menlo"))
    s.open(
        False, List[LanguageServerOverride](),
        String(""), True, True, False, String("Turbo C++ 3.0"),
        String("IBM VGA 8x16 (built-in)"), fonts^,
    )
    assert_equal(s.selected_font, 0)
    assert_false(s.dirty)
    s._step_font(1)
    assert_equal(s.selected_font, 1)
    assert_equal(s.font_choice, String("Menlo"))
    assert_true(s.dirty)
    # Stepping past the end clamps without re-dirtying a fresh ack.
    s.ack_dirty()
    s._step_font(1)
    assert_equal(s.selected_font, 1)
    assert_false(s.dirty)


def test_settings_font_size_stepper_commits_and_marks_dirty() raises:
    """The Font pane's size stepper steps from the *displayed* size (the
    explicit choice, or the host-reported effective size when the choice
    is 0), clamps, commits an explicit size, and raises ``dirty``."""
    var s = Settings()
    var fonts = List[String]()
    fonts.append(String("IBM VGA 8x16 (built-in)"))
    s.open(
        False, List[LanguageServerOverride](),
        String(""), True, True, False, String("Turbo C++ 3.0"),
        String("IBM VGA 8x16 (built-in)"), fonts^,
        0,    # font_size: default
        16,   # host-reported effective size
        16,   # host-reported ideal size
    )
    assert_equal(s.font_size_choice, 0)
    assert_equal(s._font_display_size(), 16)
    assert_false(s.dirty)
    # First bump turns the default into an explicit 17.
    s._bump_font_size(1)
    assert_equal(s.font_size_choice, 17)
    assert_true(s.dirty)
    s.ack_dirty()
    # Subsequent bumps step the explicit value.
    s._bump_font_size(-1)
    assert_equal(s.font_size_choice, 16)
    assert_true(s.dirty)
    s.ack_dirty()
    # Clamped at the bottom of the range: stepping to the floor dirties
    # once, stepping past it is a no-op.
    s.font_size_choice = MIN_FONT_SIZE + 1
    s._bump_font_size(-1)
    assert_equal(s.font_size_choice, MIN_FONT_SIZE)
    s.ack_dirty()
    s._bump_font_size(-1)
    assert_equal(s.font_size_choice, MIN_FONT_SIZE)
    assert_false(s.dirty)


def test_settings_restore_ideal_font_size() raises:
    """"Restore ideal" snaps the explicit size to the host-reported
    design size; it's a no-op when the host reported none (vector
    fonts) or when already there."""
    var s = Settings()
    var fonts = List[String]()
    fonts.append(String("IBM VGA 8x16 (built-in)"))
    s.open(
        False, List[LanguageServerOverride](),
        String(""), True, True, False, String("Turbo C++ 3.0"),
        String("IBM VGA 8x16 (built-in)"), fonts^,
        20, 20, 16,
    )
    s._restore_ideal_font_size()
    assert_equal(s.font_size_choice, 16)
    assert_true(s.dirty)
    s.ack_dirty()
    # Already at the ideal: no re-dirty.
    s._restore_ideal_font_size()
    assert_false(s.dirty)
    # Host reports no ideal (e.g. the user picked a vector font while
    # the dialog was open): the button does nothing.
    s.update_font_info(13, 0)
    s.font_size_choice = 20
    s._restore_ideal_font_size()
    assert_equal(s.font_size_choice, 20)
    assert_false(s.dirty)


def test_settings_remove_language_override_marks_dirty() raises:
    """Removing the override for a custom language drops it from
    ``language_overrides``, marks ``dirty``, and rebuilds the view so
    the row disappears (since the language has no built-in fallback)."""
    var s = Settings()
    var argvs = List[List[String]]()
    var argv = List[String]()
    argv.append(String("custom"))
    argvs.append(argv^)
    var ov = LanguageServerOverride(
        String("xyzlang"), List[String](), argvs^,
    )
    var overrides = List[LanguageServerOverride]()
    overrides.append(ov^)
    s.open(False, overrides^)
    # Find and select the custom row.
    for i in range(len(s.languages_view)):
        if s.languages_view[i].language_id == String("xyzlang"):
            s.selected_language = i
            break
    s._remove_language_override()
    assert_true(s.dirty)
    assert_equal(len(s.language_overrides), 0)
    for i in range(len(s.languages_view)):
        assert_true(s.languages_view[i].language_id != String("xyzlang"))


def test_list_box_paint_never_overflows_bounds() raises:
    """Framework guarantee: a ``ListBox`` whose item text is wider than
    its rect must clip at the rect boundary on every side. No paint
    pixel may land outside the list's ``bounds`` — that's what saves
    the surrounding dialog chrome (frame, padding, neighbour controls)
    from being damaged by a too-long entry.

    The test paints into a canvas pre-filled with a sentinel glyph,
    runs ``ListBox.paint`` on a 6-wide × 3-tall rect surrounded by the
    sentinel, and asserts every cell outside the rect still shows the
    sentinel. The selected-row fill, the row text, and a row that
    overflows on the right are all included so the assertion covers
    every code path that writes a cell.
    """
    var c = Canvas(20, 7)
    var sentinel = Cell(String("·"), Attr(WHITE, BLACK), 1)
    for y in range(c.height):
        for x in range(c.width):
            c.set(x, y, sentinel)
    var bounds = Rect(2, 2, 8, 5)
    var items = List[String]()
    items.append(String("short"))
    items.append(String("this-is-way-too-long-for-the-list"))
    items.append(String("mid"))
    var lb = ListBox()
    lb.set_selected(1)
    lb.paint(c, bounds, items, True, Attr(BLACK, CYAN))
    for y in range(c.height):
        for x in range(c.width):
            var inside = (
                bounds.a.x <= x and x < bounds.b.x
                and bounds.a.y <= y and y < bounds.b.y
            )
            if not inside:
                assert_equal(c.get(x, y).glyph, String("·"))


def test_list_box_paint_empty_hint_clipped() raises:
    """``paint_empty_hint`` writes a single line inside the list rect;
    a hint longer than the rect must still not leak into the cells on
    the right."""
    var c = Canvas(20, 3)
    var sentinel = Cell(String("·"), Attr(WHITE, BLACK), 1)
    for y in range(c.height):
        for x in range(c.width):
            c.set(x, y, sentinel)
    var bounds = Rect(4, 1, 10, 2)
    var lb = ListBox()
    lb.paint_empty_hint(
        c, bounds,
        String("hint-far-too-wide-to-fit"),
        Attr(BLUE, LIGHT_GRAY),
    )
    for y in range(c.height):
        for x in range(c.width):
            var inside = (
                bounds.a.x <= x and x < bounds.b.x
                and bounds.a.y <= y and y < bounds.b.y
            )
            if not inside:
                assert_equal(c.get(x, y).glyph, String("·"))


def test_list_box_mouse_wheel_clamps_to_item_count() raises:
    """Wheel-down past the last visible row must not advance the
    scroll origin past ``items - height`` — otherwise the next paint
    sees an out-of-range index and silently shows nothing."""
    var lb = ListBox()
    var items = List[String]()
    var i = 0
    while i < 5:
        items.append(String("row"))
        i += 1
    var bounds = Rect(0, 0, 10, 3)
    # Five wheel-downs on a 3-row view over 5 items: clamp at 2.
    var down = Event.mouse_event(Point(5, 1), MOUSE_WHEEL_DOWN, True, False)
    i = 0
    while i < 5:
        _ = lb.handle_mouse_press(down, bounds, len(items))
        i += 1
    assert_equal(lb._scroll, 2)


def test_settings_languages_list_type_to_jump() raises:
    """The Languages section list is type-to-jump. After focusing the
    list, typing a letter must move ``selected_language`` to the
    first language whose id starts with the typed prefix — no
    explicit hookup per list, the framework helper drives it."""
    var s = Settings()
    s.open(False)
    # Park the user on the Languages section list.
    s.section = 3
    s.focus = UInt8(10)  # _FOCUS_LANG_LIST
    # Find the index where 'r' would land — the first language id
    # starting with "r" — so the assert is independent of catalog
    # order changes.
    var expected = -1
    for i in range(len(s.languages_view)):
        var lid = s.languages_view[i].language_id
        if len(lid.as_bytes()) > 0:
            var first = lid.as_bytes()[0]
            if first == 0x72 or first == 0x52:  # 'r' / 'R'
                expected = i
                break
    if expected < 0:
        # Bundled JSON missing or no 'r' language — skip rather than
        # fail; ``built_in_servers`` returning an empty list is
        # already tested elsewhere.
        return
    var consumed = s.handle_key(_key(UInt32(ord("r"))))
    assert_true(consumed)
    assert_equal(s.selected_language, expected)


def test_settings_actions_list_type_to_jump() raises:
    """Type-to-jump in the Project Settings On-save list: typing a letter
    moves ``selected_os`` to the first row whose label (language id +
    program) starts with that letter."""
    var lib = List[OnSaveAction]()
    lib.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    lib.append(OnSaveAction(
        String("rust"), String("/usr/bin/rustfmt"),
        List[String](), String(""),
    ))
    var ps = _ps_open(lib^, List[OnSaveAction]())
    ps.section = 0  # On save
    ps.focus = UInt8(2)  # _FOCUS_OS_LIST
    _ = ps.handle_key(_key(UInt32(ord("r"))))
    assert_equal(ps.selected_os, 1)
    # No-match keystroke: selection survives.
    ps._type_ahead.reset()
    _ = ps.handle_key(_key(UInt32(ord("z"))))
    assert_equal(ps.selected_os, 1)


def test_action_editor_lang_dropdown_has_options() raises:
    """The dropdown's language options are sourced from
    ``built_in_servers()``. If that returns an empty list (e.g. because
    the bundled languages.json isn't on disk relative to cwd), the
    user sees a one-option dropdown showing "(none)" and the field
    looks broken. Guard against the empty case so a regression here
    surfaces as a test failure rather than an in-the-wild "the
    dropdown for language is empty" bug report.
    """
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    var dd = ed._lang_dropdown(String(""))
    # Always at least the empty "(any)" sentinel — if it's the only
    # entry, the language registry didn't load.
    assert_true(len(dd.options) >= 2,
        msg=String("dropdown only has the empty sentinel — built_in_servers() "
                   "returned no languages (cwd missing the bundled JSON?)"))


def test_action_editor_enter_opens_lang_popup() raises:
    """Pressing Enter on the focused (closed) language dropdown opens
    its popup. Without this, clicks/Enter were no-ops and users had no
    way to discover the available languages — earlier code rebuilt the
    dropdown stateless each paint, so any toggle was discarded
    immediately."""
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    ed._focus.focus_force(0)  # _FOCUS_LANG
    assert_false(ed.lang_dropdown.is_open)
    var ev = Event.key_event(KEY_ENTER, MOD_NONE)
    _ = ed.handle_key(ev)
    assert_true(ed.lang_dropdown.is_open)
    # Esc on an open popup just closes the popup, not the dialog.
    var esc = Event.key_event(KEY_ESC, MOD_NONE)
    _ = ed.handle_key(esc)
    assert_false(ed.lang_dropdown.is_open)
    assert_true(ed.active)


def test_dropdown_type_to_search_jumps_to_prefix() raises:
    """Typing while a popup is open jumps the highlight to the first
    option matching the accumulated prefix. Mirrors the file-list
    behavior so the muscle memory transfers."""
    var opts = List[String]()
    opts.append(String(""))
    opts.append(String("apple"))
    opts.append(String("banana"))
    opts.append(String("blueberry"))
    opts.append(String("cherry"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    assert_true(dd.type_to_search(String("b")))
    assert_equal(dd.highlight, 2)  # banana
    assert_true(dd.type_to_search(String("l")))
    assert_equal(dd.highlight, 3)  # blueberry (prefix "bl")


def test_dropdown_type_to_search_skips_empty_sentinel() raises:
    """The empty "" option (most callers prepend one as the "(none)"
    sentinel) is not a search target. A user typing 'p' wants
    "python", not the blank row at index 0."""
    var opts = List[String]()
    opts.append(String(""))
    opts.append(String("python"))
    opts.append(String("rust"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    assert_true(dd.type_to_search(String("p")))
    assert_equal(dd.highlight, 1)  # python, not the empty sentinel


def test_dropdown_type_to_search_recovers_from_stale_prefix() raises:
    """When the accumulated prefix doesn't match anything, retry with
    just the new char. Otherwise typing 'b' then 'z' would silently
    do nothing — confusing, since the user clearly intends to jump
    somewhere starting with 'z'."""
    var opts = List[String]()
    opts.append(String("apple"))
    opts.append(String("banana"))
    opts.append(String("zebra"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    _ = dd.type_to_search(String("b"))
    assert_equal(dd.highlight, 1)  # banana
    # 'z' makes the buffer "bz" which matches nothing — fallback to
    # the single 'z' should jump to "zebra".
    assert_true(dd.type_to_search(String("z")))
    assert_equal(dd.highlight, 2)


def test_dropdown_type_to_search_resets_on_close() raises:
    """Closing the popup discards the type-to-search prefix so the
    next open starts fresh. A stale prefix surviving across reopens
    would silently misroute the first keystroke."""
    var opts = List[String]()
    opts.append(String("apple"))
    opts.append(String("banana"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    _ = dd.type_to_search(String("b"))
    assert_equal(dd._type_ahead.buf, String("b"))
    dd.close()
    assert_equal(dd._type_ahead.buf, String(""))


def test_action_editor_consumes_browse_path() raises:
    """When the embedded file dialog submits, the picked path must
    land in the program field (not the cwd field, not nowhere). This
    is the contract that lets the user click a file in Browse and end
    up with that path filled in for them."""
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    ed.file_dialog.open(String("/"))
    ed.file_dialog.selected_path = String("/usr/bin/black")
    ed.file_dialog.submitted = True
    ed._maybe_consume_browse()
    assert_false(ed.file_dialog.active)
    assert_equal(ed.form.text(UInt8(1)), String("/usr/bin/black"))


def test_action_editor_args_field_accepts_spaces() raises:
    """Typing ``a b c`` into the Arguments field used to drop the
    interior spaces because the field round-tripped through
    ``_split_args``/``_join_args`` on every keystroke. The fix holds a
    single string in ``args_text`` while editing and only splits on
    Save, so multiple arguments can actually be typed."""
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    ed._focus.focus_force(3)  # _FOCUS_ARGS
    var letters = String("a b c")
    var lb = letters.as_bytes()
    for i in range(len(lb)):
        var ev = Event.key_event(UInt32(Int(lb[i])), MOD_NONE)
        _ = ed.handle_key(ev)
    assert_equal(ed.form.text(UInt8(3)), String("a b c"))
    # The committed list is empty until Save fires.
    assert_equal(len(ed.entry.args), 0)
    ed._focus.focus_force(5)  # _FOCUS_SAVE
    var enter = Event.key_event(KEY_ENTER, MOD_NONE)
    _ = ed.handle_key(enter)
    assert_true(ed.submitted)
    assert_equal(len(ed.entry.args), 3)
    assert_equal(ed.entry.args[0], String("a"))
    assert_equal(ed.entry.args[1], String("b"))
    assert_equal(ed.entry.args[2], String("c"))


def test_action_editor_args_buffer_seeded_from_entry() raises:
    """Editing an existing action seeds the args edit-buffer with the
    space-joined existing args. Without this, opening a record with
    args ``["--quiet", "$FilePath$"]`` would show an empty Arguments
    field and the user would lose their config the moment they saved."""
    var args = List[String]()
    args.append(String("--quiet"))
    args.append(String("$FilePath$"))
    var existing = OnSaveAction(
        String("python"), String("/usr/bin/black"), args^, String(""),
    )
    var ed = ActionEditor()
    ed.open(existing^, 0)
    assert_equal(ed.form.text(UInt8(3)), String("--quiet $FilePath$"))


def test_quick_open_match_rules() raises:
    """Locked-in spec: the query is split on spaces into tokens, and each
    token is then split around every ``/`` (with ``/`` kept as its own
    one-byte part). Each part must appear as a case-insensitive substring
    of the path, in order."""
    var path = String("src/turbokod/cell.mojo")
    # `k/c` → parts ["k", "/", "c"] all present as substrings in order.
    assert_true(quick_open_match(path, String("k/c")))
    # Space-separated tokens — both substrings, in order.
    assert_true(quick_open_match(path, String("k c")))
    # `k/m` → "k" (in turbokod), "/" (after turbokod), "m" (in .mojo).
    assert_true(quick_open_match(path, String("k/m")))
    # `km/` → "km" then "/". "km" is not a substring of the path.
    assert_false(quick_open_match(path, String("km/")))

    # Multi-token across other shapes:
    assert_true(quick_open_match(String("job_call"),  String("j c")))
    assert_true(quick_open_match(String("jobCall"),   String("j c")))
    # Plain substring matching — `j` then `c` are both in "jack", in order.
    assert_true(quick_open_match(String("jack"),      String("j c")))

    # Empty query matches everything; tokens must keep their order.
    assert_true(quick_open_match(path, String("")))
    assert_false(quick_open_match(String("cell mojo"), String("mojo cell")))


def test_quick_open_match_case_and_separator_shapes() raises:
    # Case-insensitive substring matching across mixed case.
    assert_true(quick_open_match(String("HelloWorld"), String("h w")))
    assert_true(quick_open_match(String("Helloworld"), String("h")))
    # Substrings can sit on either side of any separator byte.
    assert_true(quick_open_match(String("foo-bar.baz"), String("f b b")))
    # Path-segment boundaries via slashes — each token a substring in order.
    assert_true(quick_open_match(String("a/b/c"), String("a b c")))


def test_quick_open_slash_in_query_requires_directory_separator() raises:
    """A space-separated query like ``foo bar`` matches when both ``foo``
    and ``bar`` appear as substrings of the path, in that order. A slash
    in the query — ``foo/bar`` — works the same way, except the slash
    itself is also a required substring between the two parts: it is
    equivalent to the three-part query ``foo`` / ``/`` / ``bar``, all
    matched as substrings in order. So ``foo/bar`` demands that ``foo``
    and ``bar`` straddle a real directory separator in the path.

    Worked example with ``pro/views``:

    * ``myapp/prospects/views.py`` — ``pro`` is in ``prospects``, then a
      ``/``, then ``views`` is in ``views.py``. Match.
    * ``myapp/homepage/cms/migrations/0003_snippet_preview_values.py`` —
      no segment contains ``pro`` (``preview_values`` has ``p``, ``r``,
      ``v``, ``i``, ``e``, ``w``, ``s`` only as a *subsequence*, not a
      contiguous substring; the literal text ``pro`` is absent), so the
      first part already fails. No match.
    """
    assert_true(quick_open_match(
        String("myapp/prospects/views.py"), String("pro/views"),
    ))
    assert_false(quick_open_match(
        String("myapp/homepage/cms/migrations/0003_snippet_preview_values.py"),
        String("pro/views"),
    ))


def test_quick_open_filters_as_you_type() raises:
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var qo = QuickOpen()
    qo.open(root.value())
    assert_true(qo.active)
    # QuickOpen.open is async on git projects — it spawns ``git ls-files``
    # and the entries fill in via subsequent ``tick()`` calls (Desktop
    # pumps these every frame). Drive the same loop here, capped so a
    # silent indexer can't hang the test. ~5 s budget is comfortable for
    # any normal repo (~100 ms for this one).
    var deadline = monotonic_ms() + 5000
    while qo.indexing and monotonic_ms() < deadline:
        qo.tick()
        _ = external_call["usleep", Int32](Int32(5000))   # 5 ms
    var initial_count = len(qo.matched)
    assert_true(initial_count > 5)
    # Typing narrows the match list.
    qo.query.set_text(String("editor"))
    qo._refilter()
    assert_true(len(qo.matched) > 0)
    assert_true(len(qo.matched) < initial_count)
    var found_editor_module = False
    for i in range(len(qo.matched)):
        if qo.entries[qo.matched[i]] == String("src/turbokod/editor.mojo"):
            found_editor_module = True
            break
    assert_true(found_editor_module)
    # Submission produces an absolute path joined with root.
    qo.selected_path = join_path(qo.root, qo.entries[qo.matched[0]])
    qo.submitted = True
    assert_true(_starts_with(qo.selected_path, root.value()))


def test_quick_open_preserves_query_across_close_and_reopen() raises:
    """``close()`` (whether triggered by ESC or by Desktop after submit)
    should stash the current query so the *next* ``open()`` restores it
    select-all'd. That way the user reopens to the same filter and can
    either keep going or replace it with the first keystroke."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var qo = QuickOpen()
    qo.open(root.value())
    qo.query.set_text(String("editor"))
    qo._refilter()
    # Simulate "user picked a file" — same path Desktop runs after Enter.
    qo.close()
    assert_false(qo.active)
    # Reopen: the query and its filtered selection should come back.
    qo.open(root.value())
    assert_equal(qo.query.text, String("editor"))
    # Restored text is selected so the next keystroke replaces it.
    assert_equal(qo.query.anchor, 0)
    assert_equal(qo.query.cursor, len(qo.query.text.as_bytes()))
    # Drain the indexer so we can confirm the restored query actually
    # filters the freshly-indexed list (not just that the field text
    # came back).
    var deadline = monotonic_ms() + 5000
    while qo.indexing and monotonic_ms() < deadline:
        qo.tick()
        _ = external_call["usleep", Int32](Int32(5000))   # 5 ms
    qo._refilter()
    assert_true(len(qo.matched) > 0)
    var found_editor_module = False
    for i in range(len(qo.matched)):
        if qo.entries[qo.matched[i]] == String("src/turbokod/editor.mojo"):
            found_editor_module = True
            break
    assert_true(found_editor_module)


def test_quick_open_preserves_selection_and_scroll_across_close_and_reopen() raises:
    """The cursor row and scroll offset should both come back on the
    next ``open()``, scoped to the same project root. Tracks against
    saved indices clamped into the current matched length, so a project
    where the file list grew slightly still lands close to where the
    user was."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var qo = QuickOpen()
    qo.open(root.value())
    var deadline = monotonic_ms() + 5000
    while qo.indexing and monotonic_ms() < deadline:
        qo.tick()
        _ = external_call["usleep", Int32](Int32(5000))   # 5 ms
    assert_true(len(qo.matched) > 20)
    # User scrolls / cursors down, then closes.
    qo.selected = 17
    qo.anchor = 17
    qo.scroll = 5
    qo.close()
    # Reopen the same project — selection and scroll should restore.
    qo.open(root.value())
    var deadline2 = monotonic_ms() + 5000
    while qo.indexing and monotonic_ms() < deadline2:
        qo.tick()
        _ = external_call["usleep", Int32](Int32(5000))   # 5 ms
    assert_equal(qo.selected, 17)
    assert_equal(qo.scroll, 5)
    # First navigation should treat the restored position as the
    # starting point AND end "restore mode" so the next tick (were
    # one to fire) wouldn't snap back to the saved row.
    var ev_down = Event.key_event(KEY_DOWN)
    _ = qo.handle_key(ev_down)
    assert_equal(qo.selected, 18)
    assert_false(qo._pending_restore)


def test_quick_open_resets_saved_state_when_project_root_changes() raises:
    """Saved indices belong to the previous tree; carrying them into a
    different project would land the cursor on an unrelated file. The
    saved query is dropped too — it was about the previous tree."""
    var root_a = find_git_project(String("examples/hello.mojo"))
    assert_true(root_a)
    var qo = QuickOpen()
    qo.open(root_a.value())
    qo.query.set_text(String("editor"))
    qo._refilter()
    qo.selected = 12
    qo.scroll = 4
    qo.close()
    # A different root invalidates the saved query / sel / scroll.
    qo.open(String("/tmp"))
    assert_equal(qo.query.text, String(""))
    assert_equal(qo.selected, 0)
    assert_equal(qo.scroll, 0)


def test_quick_open_shift_down_extends_multi_selection() raises:
    """Holding Shift while pressing DOWN extends the selection without
    moving the anchor. Enter then submits *all* paths in the range
    with the cursor row exposed as ``selected_path``."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var qo = QuickOpen()
    qo.open(root.value())
    var deadline = monotonic_ms() + 5000
    while qo.indexing and monotonic_ms() < deadline:
        qo.tick()
        _ = external_call["usleep", Int32](Int32(5000))   # 5 ms
    assert_true(len(qo.matched) > 3)
    # Start at row 0 (anchor=0, selected=0). Two shift+down keystrokes
    # should extend the range to rows [0..2] without moving the anchor.
    _ = qo.handle_key(Event.key_event(KEY_DOWN, MOD_SHIFT))
    _ = qo.handle_key(Event.key_event(KEY_DOWN, MOD_SHIFT))
    assert_equal(qo.anchor, 0)
    assert_equal(qo.selected, 2)
    # Enter submits the whole range; ``selected_paths`` has 3 entries
    # in row order, and ``selected_path`` is the cursor row (the last
    # one navigated to).
    _ = qo.handle_key(Event.key_event(KEY_ENTER))
    assert_true(qo.submitted)
    assert_equal(len(qo.selected_paths), 3)
    assert_equal(qo.selected_paths[0], qo.entries_abs[qo.matched[0]])
    assert_equal(qo.selected_paths[2], qo.entries_abs[qo.matched[2]])
    assert_equal(qo.selected_path, qo.entries_abs[qo.matched[2]])


def test_quick_open_plain_down_after_shift_collapses_anchor() raises:
    """A plain (no-shift) arrow key after a shift+arrow run should
    collapse the multi-selection back to a single row at the cursor
    position. That keeps "I extended, then changed my mind" usable
    without ESC + reopen."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var qo = QuickOpen()
    qo.open(root.value())
    var deadline = monotonic_ms() + 5000
    while qo.indexing and monotonic_ms() < deadline:
        qo.tick()
        _ = external_call["usleep", Int32](Int32(5000))   # 5 ms
    assert_true(len(qo.matched) > 3)
    _ = qo.handle_key(Event.key_event(KEY_DOWN, MOD_SHIFT))
    _ = qo.handle_key(Event.key_event(KEY_DOWN, MOD_SHIFT))
    assert_equal(qo.anchor, 0)
    assert_equal(qo.selected, 2)
    # Plain down: collapse anchor to the new cursor.
    _ = qo.handle_key(Event.key_event(KEY_DOWN))
    assert_equal(qo.anchor, 3)
    assert_equal(qo.selected, 3)
    # Submit yields a single-entry list now.
    _ = qo.handle_key(Event.key_event(KEY_ENTER))
    assert_true(qo.submitted)
    assert_equal(len(qo.selected_paths), 1)
    assert_equal(qo.selected_paths[0], qo.entries_abs[qo.matched[3]])


def test_dir_browser_long_name_does_not_overflow_listing() raises:
    """Regression: a directory entry far longer than the listing rect
    must not overwrite cells outside the rect, on any side. Drives the
    overflow with a 200-char synthetic entry — anything longer than
    the rect width would have leaked under the pre-Painter code only
    when callers forgot ``max_x``."""
    var canvas = Canvas(40, 5)
    var sentinel = Attr(BLACK, BLUE)
    canvas.fill(Rect(0, 0, 40, 5), String("·"), sentinel)
    var br = DirBrowser(False)
    br.entries = List[String]()
    br.entry_is_dir = List[Bool]()
    var huge = String("")
    for _ in range(200):
        huge = huge + String("X")
    br.entries.append(huge^)
    br.entry_is_dir.append(False)
    br.selected = 0
    var clip = Rect(5, 1, 15, 4)
    br.paint(canvas, clip, True)
    # Every cell outside the clip must still be the sentinel.
    for y in range(5):
        for x in range(40):
            var inside = (
                clip.a.x <= x and x < clip.b.x
                and clip.a.y <= y and y < clip.b.y
            )
            if not inside:
                assert_equal(canvas.get(x, y).glyph, String("·"))


def test_file_dialog_lists_and_navigates() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    assert_true(dlg.active)
    # Should have at least ".." and a few example files.
    assert_true(len(dlg.browser.entries) >= 2)
    assert_equal(dlg.browser.entries[0], String(".."))
    # Navigate to second entry; arrow event-driven.
    _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    assert_equal(dlg.browser.selected, 1)
    _ = dlg.handle_key(Event.key_event(KEY_UP))
    assert_equal(dlg.browser.selected, 0)


def test_file_dialog_selects_a_file() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo in the listing and step to it.
    var target = -1
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    while dlg.browser.selected < target:
        _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


def test_file_dialog_mouse_click_selects() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    var screen = Rect(0, 0, 80, 24)
    # Geometry: width=60, height=18, x=10, y=3 → list_top=6.
    # Clicking row 7 (in-screen) maps to entry index = 0 + (7 - 6) = 1.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 7), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_equal(dlg.browser.selected, 1)
    assert_false(dlg.submitted)


def test_file_dialog_double_click_opens() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo, then click it twice.
    var target = -1
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    var screen = Rect(0, 0, 80, 24)
    var list_top = 6
    var visible_y = list_top + (target - dlg.browser.scroll)
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, visible_y), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_equal(dlg.browser.selected, target)
    assert_false(dlg.submitted)
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, visible_y), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


def test_file_dialog_wheel_scrolls() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    var screen = Rect(0, 0, 80, 24)
    var initial = dlg.browser.scroll
    # Wheel down a few times.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_DOWN, True, False),
        screen,
    )
    # If there are more entries than the visible window, scroll moves; else stays.
    if len(dlg.browser.entries) > 13:
        assert_true(dlg.browser.scroll > initial)
    # Wheel up resets toward 0.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_UP, True, False),
        screen,
    )
    assert_true(dlg.browser.scroll <= initial + 3)


def test_file_dialog_directory_mode_picks_current_dir() raises:
    """``open_directory`` filters the listing to directories and sets
    up the right-aligned " Open Project " button. Clicking that
    button submits ``browser.dir`` (not a clicked entry), so the host
    can route the picked path through ``open_project``."""
    var dlg = FileDialog()
    dlg.open_directory(String("."))
    assert_true(dlg.active)
    assert_true(dlg.dirs_only)
    assert_equal(dlg.title, String(" Open Project "))
    assert_equal(dlg.browser.dir, String("."))
    # The repo root has plain files; the dirs-only filter should
    # leave only directories (plus ``..``) in the listing.
    var saw_real_entry = False
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String(".."):
            continue
        saw_real_entry = True
        assert_true(dlg.browser.entry_is_dir[i])
    assert_true(saw_real_entry)
    # Geometry: width=60, height=18, dialog at x=10 / y=3 (centered in
    # 80×24). Buttons row at y=18; " Open Project " is 14-wide, so the
    # button face starts at x = (b.x - 1) - 14 = 55.
    var screen = Rect(0, 0, 80, 24)
    # Press on the button face — captures the click.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(56, 18), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_false(dlg.submitted)
    # Release inside the same button fires it; ``selected_path`` must
    # be the *current dir*, not whatever happened to be highlighted.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(56, 18), MOUSE_BUTTON_LEFT, False, False),
        screen,
    )
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("."))


def test_file_dialog_directory_mode_enter_does_not_submit() raises:
    """In dirs-only mode every entry is navigable, so Enter on a
    directory descends rather than submitting. Submission goes
    exclusively through the Open button — otherwise the user could
    never browse past their starting directory."""
    var dlg = FileDialog()
    dlg.open_directory(String("."))
    # Step the selection off ``..`` and onto the first real directory,
    # then press Enter. The dialog should descend (browser.dir
    # changes) without flipping ``submitted``.
    _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    var initial_dir = dlg.browser.dir
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_false(dlg.submitted)
    assert_true(dlg.browser.dir != initial_dir)


def test_color_convert_roundtrips() raises:
    """OkLab and HSL must round-trip an 8-bit color back to the same 8-bit
    color (the picker leans on this for non-destructive space switching)."""
    var samples = List[Tuple[Int, Int, Int]]()
    samples.append((255, 87, 51))
    samples.append((0, 0, 0))
    samples.append((255, 255, 255))
    samples.append((18, 52, 86))
    samples.append((127, 200, 9))
    for i in range(len(samples)):
        var c = samples[i]
        var s = rgb255_to_srgb(c[0], c[1], c[2])
        var ok = srgb_to_oklab(s[0], s[1], s[2])
        var ok_srgb = oklab_to_srgb(ok[0], ok[1], ok[2])
        var ok_back = srgb_to_rgb255(ok_srgb[0], ok_srgb[1], ok_srgb[2])
        assert_equal(ok_back[0], c[0])
        assert_equal(ok_back[1], c[1])
        assert_equal(ok_back[2], c[2])
        var hsl = srgb_to_hsl(s[0], s[1], s[2])
        var hsl_srgb = hsl_to_srgb(hsl[0], hsl[1], hsl[2])
        var hsl_back = srgb_to_rgb255(hsl_srgb[0], hsl_srgb[1], hsl_srgb[2])
        assert_equal(hsl_back[0], c[0])
        assert_equal(hsl_back[1], c[1])
        assert_equal(hsl_back[2], c[2])


def test_color_convert_formatting() raises:
    """Literal formatters produce CSS syntax with the expected precision."""
    assert_equal(fmt_fixed(0.6279999, 3), String("0.628"))
    assert_equal(fmt_fixed(11.0, 0), String("11"))
    assert_equal(fmt_fixed(-0.0021, 3), String("-0.002"))
    assert_equal(format_rgb(255, 87, 51), String("rgb(255, 87, 51)"))
    assert_equal(format_hex(255, 87, 51), String("#ff5733"))
    assert_equal(format_hsl(11.0, 100.0, 60.0), String("hsl(11, 100%, 60%)"))
    # parse_float accepts clean numbers, rejects junk.
    assert_true(Bool(parse_float(String("0.42"))))
    assert_true(Bool(parse_float(String("-3"))))
    assert_false(Bool(parse_float(String("abc"))))
    assert_false(Bool(parse_float(String(""))))
    assert_false(Bool(parse_float(String("1.2.3"))))


def test_color_picker_opens_in_oklab() raises:
    """The picker defaults to the OkLab space and seeds its channels from
    the swatch color (focus starts on the first channel)."""
    var d = ColorPickerDialog()
    d.open(0xFF5733)
    assert_true(d.active)
    assert_equal(d.mode, MODE_OKLAB)
    assert_equal(d.focus, 1)
    # The formatted literal is an oklab() call.
    assert_true(d._format_current().find(String("oklab(")) >= 0)


def test_color_picker_mode_switch_preserves_color() raises:
    """Cycling the color space must keep the on-screen color identical —
    only its representation changes. Switching OkLab→RGB then applying
    yields the original 8-bit color."""
    var d = ColorPickerDialog()
    d.open(0xFF5733)
    d._set_mode(MODE_RGB)
    assert_equal(d.mode, MODE_RGB)
    assert_equal(d._format_current(), String("rgb(255, 87, 51)"))
    d._set_mode(MODE_HSL)
    # Back through HSL and on to apply still round-trips the color.
    var srgb = d._current_srgb()
    var rgb = srgb_to_rgb255(srgb[0], srgb[1], srgb[2])
    assert_equal(rgb[0], 255)
    assert_equal(rgb[1], 87)
    assert_equal(rgb[2], 51)


def test_color_picker_text_entry_commits_value() raises:
    """Typing digits into a focused channel and pressing Enter commits the
    exact value (clamped to range)."""
    var d = ColorPickerDialog()
    d.open(0xFF5733)
    d._set_mode(MODE_RGB)
    d.focus = 1  # R channel
    # Type "100" then Enter.
    _ = d.handle_key(Event.key_event(UInt32(ord("1"))))
    _ = d.handle_key(Event.key_event(UInt32(ord("0"))))
    _ = d.handle_key(Event.key_event(UInt32(ord("0"))))
    assert_true(d.editing)
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_false(d.editing)
    assert_equal(Int(d.chan[0] + 0.5), 100)
    # Over-range entry clamps to the channel max (255 for RGB).
    _ = d.handle_key(Event.key_event(UInt32(ord("9"))))
    _ = d.handle_key(Event.key_event(UInt32(ord("9"))))
    _ = d.handle_key(Event.key_event(UInt32(ord("9"))))
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_equal(Int(d.chan[0] + 0.5), 255)


def test_color_picker_apply_and_cancel() raises:
    """Enter applies (accepted + result_text set); Esc cancels (not
    accepted)."""
    var d = ColorPickerDialog()
    d.open(0xFF5733)
    d._set_mode(MODE_RGB)
    d.focus = 1
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d.submitted)
    assert_true(d.accepted)
    assert_equal(d.result_text, String("rgb(255, 87, 51)"))
    var d2 = ColorPickerDialog()
    d2.open(0xFF5733)
    _ = d2.handle_key(Event.key_event(KEY_ESC))
    assert_true(d2.submitted)
    assert_false(d2.accepted)


def test_find_doc_entry_exact_match_wins() raises:
    """Exact name match beats both case-insensitive and suffix matches.

    Without this priority a click on ``find`` (which has a top-level
    DevDocs entry in some languages) would land on a method like
    ``str.find`` instead of the canonical entry, even though both are
    plausible — the LSP couldn't resolve, so we don't know which one
    the user meant. Exact equality is the least surprising default.
    """
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("str.find"), String("library/str"),
        String("find"), String("Methods"),
    ))
    entries.append(DocEntry(
        String("find"), String("library/find"),
        String(""), String("Built-in Functions"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("find"))
    # Exact "find" should win over the suffix match on "str.find".
    assert_equal(idx, 1)


def test_find_doc_entry_falls_back_to_suffix_match() raises:
    """When no entry matches the bare word, ``foo`` should still resolve
    to ``Type.foo`` so a Cmd+click on ``s.find()`` opens ``str.find``."""
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("dict.get"), String("library/stdtypes"),
        String("dict.get"), String("Methods"),
    ))
    entries.append(DocEntry(
        String("str.find"), String("library/stdtypes"),
        String("str.find"), String("Methods"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("find"))
    assert_equal(idx, 1)


def test_find_doc_entry_returns_minus_one_when_no_match() raises:
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("abs"), String("library/functions"),
        String("abs"), String("Built-in Functions"),
    ))
    assert_equal(
        _find_doc_entry_for_word(entries, String("nonexistent")),
        -1,
    )
    # Empty word never matches anything.
    assert_equal(_find_doc_entry_for_word(entries, String("")), -1)


def test_find_doc_entry_case_insensitive_when_no_exact() raises:
    """CSS / HTML docs spell some entries lowercase even if the source
    site uses TitleCase; a Cmd+click that comes back empty from the
    LSP should still find the entry. Exact match would have already
    been preferred (this case has none), so case-folded match is the
    next best signal."""
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("Display"), String("css/display"),
        String(""), String("Properties"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("display"))
    assert_equal(idx, 0)


def test_prompt_wrap_short_text_stays_on_one_line() raises:
    var lines = wrap_to_width(String("Find: "), 56)
    assert_equal(len(lines), 1)
    assert_equal(lines[0], String("Find: "))


def test_prompt_wrap_breaks_at_last_space_within_budget() raises:
    var lines = wrap_to_width(
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
        20,
    )
    # Every line must fit the 20-cell budget; rejoining yields a string
    # that — modulo the soft-break spaces — recovers the original tokens.
    for i in range(len(lines)):
        assert_true(len(lines[i].as_bytes()) <= 20)
    var joined = String("")
    for i in range(len(lines)):
        if i > 0: joined = joined + String(" ")
        joined = joined + lines[i]
    # Trailing space on the original is preserved on the final line —
    # the prompt renders the input strip after that space, so leaving
    # it in the wrap output keeps inline and wrapped layouts visually
    # consistent around the input.
    assert_equal(
        joined,
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
    )


def test_prompt_wrap_hard_breaks_an_unbreakable_word() raises:
    # No spaces — the wrapper must still chop the input into width-sized
    # chunks rather than emit one giant overflowing line.
    var lines = wrap_to_width(String("aaaaaaaaaaaaaaaaaaaa"), 6)
    assert_equal(len(lines), 4)
    assert_equal(lines[0], String("aaaaaa"))
    assert_equal(lines[1], String("aaaaaa"))
    assert_equal(lines[2], String("aaaaaa"))
    assert_equal(lines[3], String("aa"))


def test_prompt_wrap_empty_returns_empty_list() raises:
    var lines = wrap_to_width(String(""), 60)
    assert_equal(len(lines), 0)


def test_prompt_paint_clamps_long_label_inside_dialog() raises:
    """The painted cells of a long-label prompt must all live inside
    the prompt's dialog rect — nothing leaks into the surrounding
    workspace cells the way the un-clamped ``put_text`` used to."""
    var screen = Rect(0, 0, 80, 24)
    var canvas = Canvas(80, 24)
    canvas.clear(Attr(BLACK, BLUE))
    var prompt = Prompt()
    prompt.open(
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
    )
    prompt.paint(canvas, screen)
    # The dialog centers itself; the only cells whose attr changed
    # from the (BLACK, BLUE) workspace fill are inside the dialog rect
    # *or* inside the drop-shadow strip directly to its right and
    # below. Anything else is a paint leak.
    var dialog_w = 60
    var dx = (80 - dialog_w) // 2
    # Walk a generous outer band around the dialog and shadow and
    # confirm the workspace fill is intact: cells outside the dialog
    # rect (and outside the 2-cell right shadow / 1-row bottom shadow)
    # must still carry the original blue background.
    for y in range(24):
        for x in range(80):
            var inside_dialog = (
                x >= dx and x < dx + dialog_w and y >= 8 and y < 16
            )
            var in_right_shadow = (
                x >= dx + dialog_w and x < dx + dialog_w + 2
                and y >= 9 and y < 16
            )
            var in_bottom_shadow = (
                x >= dx + 2 and x < dx + dialog_w + 2 and y == 16
            )
            if inside_dialog or in_right_shadow or in_bottom_shadow:
                continue
            var c = canvas.get(x, y)
            assert_equal(c.attr.bg, BLUE)


def test_confirm_dialog_y_key_resolves_yes() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    assert_true(d.active)
    assert_false(d.submitted)
    _ = d.handle_key(Event.key_event(UInt32(ord("y"))))
    assert_true(d.submitted)
    assert_true(d.confirmed)


def test_confirm_dialog_n_key_resolves_no() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    _ = d.handle_key(Event.key_event(UInt32(ord("n"))))
    assert_true(d.submitted)
    assert_false(d.confirmed)


def test_confirm_dialog_esc_cancels() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    _ = d.handle_key(Event.key_event(KEY_ESC))
    assert_true(d.submitted)
    assert_false(d.confirmed)


def test_confirm_dialog_enter_uses_focused_button() raises:
    """Default focus is No (safer for installs); Tab toggles to Yes;
    Enter resolves whichever side is focused."""
    var d = ConfirmDialog()
    d.open(String("Download docs?"))
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d.submitted)
    assert_false(d.confirmed)   # default focus is No
    var d2 = ConfirmDialog()
    d2.open(String("Download docs?"))
    _ = d2.handle_key(Event.key_event(KEY_TAB))
    _ = d2.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d2.submitted)
    assert_true(d2.confirmed)


def test_confirm_dialog_default_yes_focuses_yes() raises:
    """Callers that want Enter to mean Yes pass ``default_yes=True``."""
    var d = ConfirmDialog()
    d.open(String("Save changes?"), default_yes=True)
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d.submitted)
    assert_true(d.confirmed)


def test_confirm_dialog_paints_inside_dialog_rect() raises:
    """Same overflow guarantee as the Prompt: a long install hint
    must stay inside the centered dialog rect (plus the drop shadow)."""
    var screen = Rect(0, 0, 80, 24)
    var canvas = Canvas(80, 24)
    canvas.clear(Attr(BLACK, BLUE))
    var dialog = ConfirmDialog()
    dialog.open(
        String("Install rust LSP? 'rustup component add rust-analyzer'"),
    )
    dialog.paint(canvas, screen)
    var dialog_w = 60
    var dx = (80 - dialog_w) // 2
    # The painted area covers the dialog rect itself plus the right-edge
    # shadow column (dx + dialog_w) and the bottom-shadow row. Cells
    # outside that band must still carry the workspace fill.
    for y in range(24):
        for x in range(80):
            var c = canvas.get(x, y)
            if c.attr.bg == BLUE:
                continue
            assert_true(x >= dx and x < dx + dialog_w + 2)


def test_find_misspelled_runs_keeps_unicode_letters_in_word() raises:
    """``Godkänn`` (Swedish ``approve``) used to tokenize as three runs:
    ``Godk`` (4 letters, flagged), the lone ``ä`` (skipped as non-letter),
    and ``nn`` (skipped as <4). After the UTF-8 fix the whole word is
    one token and either passes (if in dict) or is flagged as a single
    region — never as ``Godk`` alone."""
    var words = List[String]()
    words.append(String("godkänn"))
    var s = _spell_with_dict(words)
    var runs = find_misspelled_runs(s, String("Godkänn"))
    assert_equal(len(runs), 0)
    # And without "godkänn" in the dictionary, the run that gets flagged
    # is the whole word — not the ASCII prefix in isolation.
    var s2 = _spell_with_dict(List[String]())
    s2.load_words(List[String]())
    # Force loaded=True so check_word actually runs.
    var seed2 = List[String]()
    seed2.append(String("hello"))
    s2.load_words(seed2)
    var runs2 = find_misspelled_runs(s2, String("Godkänn"))
    assert_equal(len(runs2), 1)
    var rng = runs2[0]
    # 7 bytes: G(1) o(1) d(1) k(1) ä(2) n(1) n(1) = wait, that's 8.
    # ``ä`` is U+00E4 = 2 bytes (0xC3 0xA4). G=1, o=1, d=1, k=1, ä=2,
    # n=1, n=1 → 8 bytes total. Run covers all of them.
    assert_equal(rng[0], 0)
    assert_equal(rng[1], 8)


def test_find_misspelled_runs_filters_identifiers_and_short_words() raises:
    """Word-shape filters should suppress: <4 letters, all caps, mixed
    case mid-word, identifier fragments with digits/underscores."""
    var words = List[String]()
    words.append(String("hello"))
    var s = _spell_with_dict(words)
    var text = String("ok URL flushHighlights foo_bar123 helo world hello")
    var runs = find_misspelled_runs(s, text)
    # ``ok`` (too short), ``URL`` (acronym), ``flushHighlights``
    # (internal cap), ``foo_bar123`` (identifier), ``hello`` (in dict)
    # all skipped. Only ``helo`` and ``world`` should flag.
    assert_equal(len(runs), 2)
    var b = text.as_bytes()
    var first_word = String(StringSpan(unsafe_from_utf8=b[runs[0][0]:runs[0][1]]))
    var second_word = String(StringSpan(unsafe_from_utf8=b[runs[1][0]:runs[1][1]]))
    assert_equal(first_word, String("helo"))
    assert_equal(second_word, String("world"))


def test_text_field_scrolls_to_keep_cursor_visible() raises:
    """Typing past the strip width must scroll horizontally so the
    caret stays inside the strip — otherwise the user can't see what
    they're typing once the field overflows."""
    var tf = TextField()
    tf.set_text(String("abcdefghijklmnop"))   # 16 chars
    var canvas = Canvas(20, 1)
    var rect = Rect(0, 0, 10, 1)
    tf.paint(canvas, rect, True)
    # Cursor sits at the end of the text. Strip is 10 wide, so the
    # cursor must be at the rightmost cell (col 9) and the visible
    # window must show the *trailing* 10 cells of text.
    assert_equal(canvas.get(0, 0).glyph, String("h"))   # text cell 7
    assert_equal(canvas.get(8, 0).glyph, String("p"))   # last char
    # The caret cell sits past the last char (cursor at end-of-text).
    # Just assert the field hasn't scrolled past where text is visible.
    assert_true(tf._scroll > 0)
    assert_equal(tf._scroll, 7)   # 16 cells - 10 width + 1 caret cell


def test_text_field_scrolls_back_when_cursor_moves_left_of_view() raises:
    """Pressing Home on an overflowed field jumps the cursor to byte
    0; the visible window must follow so the user lands on the start
    of the text rather than staring at the (now-invisible) caret."""
    var tf = TextField()
    tf.set_text(String("abcdefghijklmnop"))
    var canvas = Canvas(20, 1)
    var rect = Rect(0, 0, 10, 1)
    tf.paint(canvas, rect, True)
    assert_true(tf._scroll > 0)
    _ = tf.handle_key(_key(KEY_HOME))
    tf.paint(canvas, rect, True)
    assert_equal(tf._scroll, 0)
    assert_equal(canvas.get(0, 0).glyph, String("a"))
    assert_equal(canvas.get(9, 0).glyph, String("j"))


def test_text_field_click_maps_to_text_byte_via_scroll() raises:
    """A click on a scrolled field must land on the codepoint that's
    *visually* under the cursor — i.e. text cell = strip cell +
    scroll. If we ignored scroll the click would always land in the
    first chunk of the text regardless of how far it had scrolled."""
    var tf = TextField()
    tf.set_text(String("abcdefghijklmnop"))
    var canvas = Canvas(20, 1)
    var rect = Rect(0, 0, 10, 1)
    tf.paint(canvas, rect, True)
    # The strip is now scrolled (cursor at end). Click on strip cell
    # 0 (which displays text cell 7 = 'h').
    _ = tf.handle_mouse(
        Event.mouse_event(Point(0, 0), MOUSE_BUTTON_LEFT, True, False),
        rect,
    )
    assert_equal(tf.cursor, 7)
    # Click on strip cell 5 (text cell 12 = 'm').
    _ = tf.handle_mouse(
        Event.mouse_event(Point(5, 0), MOUSE_BUTTON_LEFT, True, False),
        rect,
    )
    assert_equal(tf.cursor, 12)


def test_text_field_cmd_a_selects_all() raises:
    """Cmd+A should select the entire field on macOS — the same chord
    that triggers select-all in every other native input. Without the
    MOD_META branch in ``clipboard_chord``, only Ctrl+A worked."""
    var tf = TextField()
    tf.set_text(String("hello"))
    # Move cursor away from end so we can assert a real selection
    # change rather than an empty one.
    _ = tf.handle_key(_key(KEY_HOME))
    var r = tf.handle_key(_key(UInt32(ord("a")), MOD_META))
    assert_true(r.consumed)
    assert_true(tf.has_selection())
    assert_equal(tf.anchor, 0)
    assert_equal(tf.cursor, 5)


def test_text_field_ctrl_a_still_selects_all() raises:
    """The Cmd+A fix must not regress the existing Ctrl+A behavior —
    both modifiers map to select-all (Linux/Windows + macOS muscle
    memory)."""
    var tf = TextField()
    tf.set_text(String("hello"))
    _ = tf.handle_key(_key(KEY_HOME))
    var r = tf.handle_key(_key(UInt32(ord("a")), MOD_CTRL))
    assert_true(r.consumed)
    assert_true(tf.has_selection())
    assert_equal(tf.anchor, 0)
    assert_equal(tf.cursor, 5)


def test_text_field_cmd_letter_does_not_insert() raises:
    """Cmd+B (or any unbound Cmd chord) used to fall through the
    modifier check and insert ``b`` as plain text — the check at the
    bottom of ``handle_key`` only excluded MOD_CTRL / MOD_ALT and
    silently ignored MOD_META. Now Cmd+letter is always consumed and
    the field stays unchanged."""
    var tf = TextField()
    tf.set_text(String("hi"))
    var before = tf.text
    var r = tf.handle_key(_key(UInt32(ord("b")), MOD_META))
    assert_true(r.consumed)
    assert_true(not r.changed)
    assert_equal(tf.text, before)


def test_text_field_ctrl_letter_does_not_insert() raises:
    """Ctrl+B with no clipboard / select-all chord match should also
    leave the field untouched — same reasoning as the Cmd+letter
    case, but on Linux/Windows the modifier is Ctrl."""
    var tf = TextField()
    tf.set_text(String("hi"))
    var before = tf.text
    var r = tf.handle_key(_key(UInt32(ord("b")), MOD_CTRL))
    assert_true(r.consumed)
    assert_true(not r.changed)
    assert_equal(tf.text, before)


def test_text_field_paints_visible_window_after_scroll() raises:
    """When scrolled, ``paint`` must render the slice of text starting
    at ``_scroll`` and not draw the leading characters that fall
    before the strip — otherwise the off-screen text would smear into
    the strip's left edge."""
    var tf = TextField()
    tf.set_text(String("0123456789ABCDEF"))
    var canvas = Canvas(20, 1)
    var rect = Rect(2, 0, 10, 1)   # 8-wide strip starting at col 2
    tf.paint(canvas, rect, True)
    # Cursor at end; scroll = 16 - 8 + 1 = 9. Visible text cells are
    # [9, 17), so strip col 2 shows text cell 9 = '9', strip col 9
    # shows text cell 16 = caret-only space.
    assert_equal(canvas.get(2, 0).glyph, String("9"))
    assert_equal(canvas.get(8, 0).glyph, String("F"))
    # Outside the strip on the left: untouched (still default blank).
    assert_equal(canvas.get(0, 0).glyph, String(" "))
    assert_equal(canvas.get(1, 0).glyph, String(" "))


def test_find_symbol_query_keeps_dot() raises:
    # The dot survives sanitization so the user can type a qualified
    # ``Class.member`` query (it used to be stripped, leaving the field
    # apparently ignoring the keypress).
    assert_equal(
        sanitize_symbol_query(String("User.has_permission")),
        String("User.has_permission"),
    )
    # All other punctuation is still stripped — the member is the only
    # thing that reaches rg's regex, so the injection guard holds.
    assert_equal(
        sanitize_symbol_query(String("-User.has*()")), String("User.has"),
    )


def test_find_symbol_query_split() raises:
    # Split on the last dot: everything after is the member rg searches
    # for, everything before is the container qualifier.
    assert_equal(
        _query_member(String("User.has_permission")),
        String("has_permission"),
    )
    assert_equal(_query_qualifier(String("User.has_permission")), String("User"))
    # No dot → the whole query is the member, no qualifier.
    assert_equal(_query_member(String("has_permission")), String("has_permission"))
    assert_equal(_query_qualifier(String("has_permission")), String(""))
    # Nested qualifier splits on the *last* dot.
    assert_equal(_query_member(String("pkg.User.method")), String("method"))
    assert_equal(_query_qualifier(String("pkg.User.method")), String("pkg.User"))


def test_find_symbol_container_match() raises:
    # Exact and case-insensitive container hits.
    assert_true(container_matches_qualifier(String("User"), String("User")))
    assert_true(container_matches_qualifier(String("user"), String("User")))
    # Either side may spell out more of the path than the other.
    assert_true(
        container_matches_qualifier(String("mypkg.User"), String("User")),
    )
    assert_true(
        container_matches_qualifier(String("User"), String("mypkg.User")),
    )
    # A different class is rejected — this is what disambiguates
    # ``User.has_permission`` from ``Account.has_permission``.
    assert_false(container_matches_qualifier(String("Account"), String("User")))
    # Empty qualifier matches anything (the unqualified path).
    assert_true(container_matches_qualifier(String("Account"), String("")))
    # A real qualifier against a container-less symbol can't match.
    assert_false(container_matches_qualifier(String(""), String("User")))


# --- ShadowButton + DirBrowser jump buttons ------------------------------
# Merged in from the former ``tests/test_buttons.mojo``, which had been
# unbuildable (and therefore unrun) since ``targets_dialog`` was replaced by
# ``project_settings``. Its two TargetsDialog tests went with that type.

def test_shadow_button_press_captures_and_release_fires() raises:
    """A press inside the hit rect captures the mouse; a release
    inside the same rect fires. The latch clears on release."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var press = Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT)
    assert_equal(btn.handle_mouse(press), BUTTON_CAPTURED)
    assert_true(btn.pressed)
    assert_true(btn.pressed_inside)
    var release = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_equal(btn.handle_mouse(release), BUTTON_FIRED)
    assert_false(btn.pressed)


def test_shadow_button_release_outside_cancels() raises:
    """Press inside, drag outside, release: button must NOT fire.
    The state machine returns ``BUTTON_CANCELED`` so the host can
    distinguish "ran the action" from "user backed out"."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var press = Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT)
    assert_equal(btn.handle_mouse(press), BUTTON_CAPTURED)
    # Drag-motion off the button: still captured, but inside flag clears.
    var drag_off = Event.mouse_event(
        Point(50, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    )
    assert_equal(btn.handle_mouse(drag_off), BUTTON_CAPTURED)
    assert_true(btn.pressed)
    assert_false(btn.pressed_inside)
    # Release outside.
    var release_off = Event.mouse_event(
        Point(50, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_equal(btn.handle_mouse(release_off), BUTTON_CANCELED)
    assert_false(btn.pressed)


def test_shadow_button_drag_back_in_re_fires() raises:
    """Press, drag out, drag back in, release: must fire — matches
    native button affordance where re-entering the held button
    re-arms it for the click."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    _ = btn.handle_mouse(Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT))
    _ = btn.handle_mouse(Event.mouse_event(
        Point(50, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    ))
    assert_false(btn.pressed_inside)
    _ = btn.handle_mouse(Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    ))
    assert_true(btn.pressed_inside)
    var release = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_equal(btn.handle_mouse(release), BUTTON_FIRED)


def test_shadow_button_press_outside_returns_none() raises:
    """A press that doesn't land on the button is unconsumed —
    callers can then route it elsewhere without their own
    hit-test."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var press = Event.mouse_event(Point(50, 50), MOUSE_BUTTON_LEFT)
    assert_equal(btn.handle_mouse(press), BUTTON_NONE)
    assert_false(btn.pressed)


def test_shadow_button_motion_without_capture_returns_none() raises:
    """Drag motion when no button is captured is not ours to
    consume — must return NONE so the host can route it to e.g.
    a title-bar drag."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    var drag = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=True, motion=True,
    )
    assert_equal(btn.handle_mouse(drag), BUTTON_NONE)


def test_paint_shadow_button_pressed_omits_shadow() raises:
    """When the button is captured AND the cursor is over it, the
    drop-shadow cells are overpainted with the dialog body so the
    button reads as sunken-flush."""
    var canvas = Canvas(20, 4)
    canvas.fill(Rect(0, 0, 20, 4), String(" "), Attr(BLACK, LIGHT_GRAY))
    var btn = ShadowButton(String(" OK "), 2, 1)
    btn.pressed = True
    btn.pressed_inside = True
    paint_shadow_button(canvas, btn, Attr(BLACK, GREEN), LIGHT_GRAY)
    # Face row still carries the label on green.
    assert_equal(canvas.get(3, 1).glyph, String("O"))
    assert_equal(canvas.get(3, 1).attr.bg, GREEN)
    # Shadow column overpainted to body.
    assert_equal(canvas.get(2 + 4, 1).glyph, String(" "))
    assert_equal(canvas.get(2 + 4, 1).attr.bg, LIGHT_GRAY)
    # Bottom-shadow row collapses to body cells.
    assert_equal(canvas.get(3, 2).glyph, String(" "))
    assert_equal(canvas.get(2 + 4, 2).glyph, String(" "))


def test_paint_shadow_button_dragged_off_shows_shadow_again() raises:
    """While the button is captured but the cursor has moved off
    the hit rect, the shadow returns — the user sees the click is
    armed to cancel."""
    var canvas = Canvas(20, 4)
    canvas.fill(Rect(0, 0, 20, 4), String(" "), Attr(BLACK, LIGHT_GRAY))
    var btn = ShadowButton(String(" OK "), 2, 1)
    btn.pressed = True
    btn.pressed_inside = False  # dragged off
    paint_shadow_button(canvas, btn, Attr(BLACK, GREEN), LIGHT_GRAY)
    assert_equal(canvas.get(2 + 4, 1).glyph, String("▄"))
    assert_equal(canvas.get(3, 2).glyph, String("▀"))


def test_dir_browser_jump_button_release_inside_jumps() raises:
    """Press + release inside the Root jump button must navigate
    via ``jump_to``. Press alone must not navigate (release-fire
    semantics)."""
    var browser = DirBrowser()
    var start_dir = browser.dir
    var row = Rect(2, 10, 60, 12)
    var layout = jump_shortcuts(row.a.x)
    var idx = len(layout) - 1
    var b = layout[idx]
    var inside = Point(b.x + 1, row.a.y)
    var press = Event.mouse_event(inside, MOUSE_BUTTON_LEFT)
    assert_true(browser.handle_jump_click(press, row))
    # Press alone hasn't navigated.
    assert_true(browser.dir == start_dir)
    var release = Event.mouse_event(
        inside, MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_true(browser.handle_jump_click(release, row))
    assert_true(browser.dir == String("/"))


def test_dir_browser_jump_button_release_outside_cancels() raises:
    """Press inside Root, release way outside — must NOT navigate."""
    var browser = DirBrowser()
    var start_dir = browser.dir
    var row = Rect(2, 10, 60, 12)
    var layout = jump_shortcuts(row.a.x)
    var idx = len(layout) - 1
    var b = layout[idx]
    var inside = Point(b.x + 1, row.a.y)
    _ = browser.handle_jump_click(
        Event.mouse_event(inside, MOUSE_BUTTON_LEFT), row,
    )
    # Release in a clearly-outside cell.
    var release = Event.mouse_event(
        Point(row.b.x - 1, row.a.y), MOUSE_BUTTON_LEFT, pressed=False,
    )
    _ = browser.handle_jump_click(release, row)
    assert_true(browser.dir == start_dir)


def main() raises:
    setup_test_env()
    test_find_results_pane_multiselect()
    test_find_in_project_options_smoke()
    test_find_git_project()
    test_walk_project_files_finds_known_files()
    test_find_in_project_locates_string()
    test_dropdown_reserves_indent_for_checkable_items()
    test_dropdown_widens_to_fit_shortcut()
    test_walk_project_files_respects_gitignore()
    test_walk_project_files_include_ignored_files_keeps_files_prunes_dirs()
    test_walk_project_files_git_fast_path_includes_ignored_files()
    test_settings_open_seeds_state()
    test_settings_language_server_section_seeds_and_toggles()
    test_settings_windowed_default_is_centered_dialog()
    test_settings_windowed_move_and_resize()
    test_settings_detached_fills_surface()
    test_settings_open_empty_parks_selection_at_minus_one()
    test_settings_remove_marks_dirty()
    test_settings_editor_submit_appends_new_entry()
    test_settings_editor_submit_replaces_existing_entry()
    test_settings_open_seeds_save_behavior_dropdown()
    test_settings_save_behavior_commit_marks_dirty()
    test_settings_save_behavior_no_change_no_dirty()
    test_settings_open_seeds_editor_toggles()
    test_settings_editor_toggle_marks_dirty()
    test_settings_max_open_windows_seeds_and_edits()
    test_settings_languages_section_seeded()
    test_settings_open_selects_current_language()
    test_settings_open_unknown_extension_falls_back_to_first()
    test_settings_font_section_requires_host_fonts()
    test_settings_font_step_commits_and_marks_dirty()
    test_settings_font_size_stepper_commits_and_marks_dirty()
    test_settings_restore_ideal_font_size()
    test_settings_remove_language_override_marks_dirty()
    test_list_box_paint_never_overflows_bounds()
    test_list_box_paint_empty_hint_clipped()
    test_list_box_mouse_wheel_clamps_to_item_count()
    test_settings_languages_list_type_to_jump()
    test_settings_actions_list_type_to_jump()
    test_action_editor_lang_dropdown_has_options()
    test_action_editor_enter_opens_lang_popup()
    test_dropdown_type_to_search_jumps_to_prefix()
    test_dropdown_type_to_search_skips_empty_sentinel()
    test_dropdown_type_to_search_recovers_from_stale_prefix()
    test_dropdown_type_to_search_resets_on_close()
    test_action_editor_consumes_browse_path()
    test_action_editor_args_field_accepts_spaces()
    test_action_editor_args_buffer_seeded_from_entry()
    test_quick_open_match_rules()
    test_quick_open_match_case_and_separator_shapes()
    test_quick_open_slash_in_query_requires_directory_separator()
    test_quick_open_filters_as_you_type()
    test_quick_open_preserves_query_across_close_and_reopen()
    test_quick_open_preserves_selection_and_scroll_across_close_and_reopen()
    test_quick_open_resets_saved_state_when_project_root_changes()
    test_quick_open_shift_down_extends_multi_selection()
    test_quick_open_plain_down_after_shift_collapses_anchor()
    test_dir_browser_long_name_does_not_overflow_listing()
    test_file_dialog_lists_and_navigates()
    test_file_dialog_selects_a_file()
    test_file_dialog_mouse_click_selects()
    test_file_dialog_double_click_opens()
    test_file_dialog_wheel_scrolls()
    test_file_dialog_directory_mode_picks_current_dir()
    test_file_dialog_directory_mode_enter_does_not_submit()
    test_color_convert_roundtrips()
    test_color_convert_formatting()
    test_color_picker_opens_in_oklab()
    test_color_picker_mode_switch_preserves_color()
    test_color_picker_text_entry_commits_value()
    test_color_picker_apply_and_cancel()
    test_find_doc_entry_exact_match_wins()
    test_find_doc_entry_falls_back_to_suffix_match()
    test_find_doc_entry_returns_minus_one_when_no_match()
    test_find_doc_entry_case_insensitive_when_no_exact()
    test_prompt_wrap_short_text_stays_on_one_line()
    test_prompt_wrap_breaks_at_last_space_within_budget()
    test_prompt_wrap_hard_breaks_an_unbreakable_word()
    test_prompt_wrap_empty_returns_empty_list()
    test_prompt_paint_clamps_long_label_inside_dialog()
    test_confirm_dialog_y_key_resolves_yes()
    test_confirm_dialog_n_key_resolves_no()
    test_confirm_dialog_esc_cancels()
    test_confirm_dialog_enter_uses_focused_button()
    test_confirm_dialog_default_yes_focuses_yes()
    test_confirm_dialog_paints_inside_dialog_rect()
    test_find_misspelled_runs_keeps_unicode_letters_in_word()
    test_find_misspelled_runs_filters_identifiers_and_short_words()
    test_text_field_scrolls_to_keep_cursor_visible()
    test_text_field_scrolls_back_when_cursor_moves_left_of_view()
    test_text_field_click_maps_to_text_byte_via_scroll()
    test_text_field_cmd_a_selects_all()
    test_text_field_ctrl_a_still_selects_all()
    test_text_field_cmd_letter_does_not_insert()
    test_text_field_ctrl_letter_does_not_insert()
    test_text_field_paints_visible_window_after_scroll()
    test_find_symbol_query_keeps_dot()
    test_find_symbol_query_split()
    test_find_symbol_container_match()
    test_shadow_button_press_captures_and_release_fires()
    test_shadow_button_release_outside_cancels()
    test_shadow_button_drag_back_in_re_fires()
    test_shadow_button_press_outside_returns_none()
    test_shadow_button_motion_without_capture_returns_none()
    test_paint_shadow_button_pressed_omits_shadow()
    test_paint_shadow_button_dragged_off_shows_shadow_again()
    test_dir_browser_jump_button_release_inside_jumps()
    test_dir_browser_jump_button_release_outside_cancels()
    print("dialogs: 107 tests passed")
