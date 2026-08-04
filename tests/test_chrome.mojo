"""Chrome: menus, status bar, docked and floating panels, painting.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas, utf8_byte_to_cell, utf8_codepoint_count
from turbokod.painter import Painter
from turbokod.cell import Cell
from turbokod.colors import (
    Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, WHITE, PANE_BG, default_attr
)
from turbokod.editor import Editor
from turbokod.file_dialog import FileDialog
from turbokod.desktop import (
    APP_QUIT_ACTION, Desktop, EDITOR_FIND, EDITOR_OPEN, EDITOR_QUICK_OPEN,
    EDITOR_SAVE, WINDOW_CLOSE, ctrl_key
)
from turbokod.file_io import read_file, write_file
from turbokod.file_tree import FILE_TREE_WIDTH
from turbokod.menu import Menu, MenuBar, MenuItem
from turbokod.buttons import (
    ShadowButton, paint_shadow_button, shadow_button_hit
)
from turbokod.status import StatusBar, StatusTab
from turbokod.string_utils import utf8_cell_of_byte, utf8_byte_of_cell
from turbokod.posix import which
from turbokod.settings import Settings
from turbokod.canvas import paint_drop_shadow
from turbokod.window import (
    DockedPanelStack, PANEL_STATE_MAXIMIZED, PANEL_STATE_MINIMIZED,
    PANEL_STATE_NORMAL, TitleCommand, WindowManager, paint_title_commands
)
from turbokod.events import (
    Event, EVENT_KEY, KEY_BACKSPACE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F5, KEY_LEFT, KEY_RIGHT, KEY_UP, MOD_ALT, MOD_CTRL, MOD_META,
    MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE
)
from turbokod.geometry import Point, Rect
from turbokod.prompt import Prompt
from turbokod.terminal import parse_input
from turbokod.window import Window

from support import (
    _SCREEN, _contains, _empty_menu, _key, _temp_path, setup_test_env
)


def _has_spell_mark(ed: Editor) -> Bool:
    for i in range(len(ed.spell_lines)):
        if ed.spell_lines[i]:
            return True
    return False


def test_hotkeys_page_is_generated_from_registry() raises:
    """The page is built by looping the global hotkey registry, so every
    binding that carries a group + help is guaranteed to appear — this is
    the property that keeps the docs from drifting. Assert it directly:
    each documented hotkey's help string is present in the rendered text,
    and ``doc_only`` rows (editor-handled chords) are never dispatched."""
    var d = Desktop()
    var text = d._hotkeys_help_text()
    var documented = 0
    var doc_only_seen = 0
    for i in range(len(d._hotkeys)):
        if d._hotkeys[i].doc_only:
            doc_only_seen += 1
        if len(d._hotkeys[i].help.as_bytes()) == 0:
            continue
        documented += 1
        assert_true(_contains(text, d._hotkeys[i].help))
    # Sanity: the registry actually carries documented + doc_only entries
    # (guards against the loop silently doing nothing).
    assert_true(documented > 20)
    assert_true(doc_only_seen > 0)
    # A doc_only chord (Cmd+Up smart-select) must NOT be dispatched by the
    # desktop hotkey table — the editor owns it. dispatch_action is only
    # reached on a registry match, so a Cmd+Up key event must fall through
    # the hotkey loop (returns the unhandled forwarding path, not a
    # smart-select). We assert the table contains it as doc_only.
    var found_cmd_up_doc_only = False
    for i in range(len(d._hotkeys)):
        if d._hotkeys[i].key == KEY_UP \
                and d._hotkeys[i].mods == MOD_META \
                and d._hotkeys[i].doc_only:
            found_cmd_up_doc_only = True
    assert_true(found_cmd_up_doc_only)


def test_hotkey_gate_registers_editor_chords() raises:
    """The global hotkey gate (``_handle_key``) only lets a modified chord
    reach the editor if it's registered in ``_hotkeys``. Assert the predicate
    classifies chords correctly and that every chord the editor acts on —
    including the formerly-undocumented Ctrl+Shift+Up/Down git navigation — is
    registered, while ordinary typing is never gated."""
    var d = Desktop()
    # Gated: Ctrl/Alt/Cmd chords, navigation+Shift, and function keys.
    assert_true(
        Desktop._is_gated_combo(Event.key_event(KEY_UP, MOD_CTRL | MOD_SHIFT))
    )
    assert_true(Desktop._is_gated_combo(Event.key_event(KEY_LEFT, MOD_SHIFT)))
    assert_true(
        Desktop._is_gated_combo(Event.key_event(UInt32(ord("b")), MOD_META))
    )
    assert_true(Desktop._is_gated_combo(Event.key_event(KEY_F5, MOD_NONE)))
    # NOT gated: a capital letter arrives as (printable, MOD_SHIFT) from the
    # native host — gating it would swallow ordinary typing.
    assert_true(
        not Desktop._is_gated_combo(Event.key_event(UInt32(ord("A")), MOD_SHIFT))
    )
    assert_true(
        not Desktop._is_gated_combo(Event.key_event(UInt32(ord("a")), MOD_NONE))
    )
    # NOT gated: editing keys stay editing keys even with a modifier (Cmd+Enter
    # still splits a line; Ctrl+Backspace still deletes a word).
    assert_true(
        not Desktop._is_gated_combo(Event.key_event(KEY_ENTER, MOD_META))
    )
    assert_true(
        not Desktop._is_gated_combo(Event.key_event(KEY_BACKSPACE, MOD_CTRL))
    )
    # Every editor chord the gate must pass is registered — including the
    # git-change navigation that had no registry row before.
    assert_true(d._combo_registered(KEY_UP, MOD_CTRL | MOD_SHIFT))
    assert_true(d._combo_registered(KEY_DOWN, MOD_CTRL | MOD_SHIFT))
    assert_true(d._combo_registered(KEY_UP, MOD_META))
    assert_true(d._combo_registered(KEY_LEFT, MOD_SHIFT))
    assert_true(d._combo_registered(KEY_LEFT, MOD_ALT))
    assert_true(d._combo_registered(UInt32(ord("z")), MOD_META | MOD_ALT))
    # An arbitrary chord nobody bound is NOT registered — the gate swallows it.
    assert_true(not d._combo_registered(UInt32(ord("b")), MOD_META))
    # The git-change navigation now appears on the Keyboard Shortcuts page.
    assert_true(_contains(d._hotkeys_help_text(), String("Previous change")))


def test_tab_cell_byte_converters_match_put_text() raises:
    """Tabs expand to the next TAB_WIDTH (4) boundary, and the scalar
    byte↔cell converters used for cursor positioning agree with what
    ``put_text`` / ``utf8_byte_to_cell`` actually paint. Regression for
    the makefile case where the caret drifted off the glyph because the
    cursor's column was computed treating ``\\t`` as one cell."""
    # Leading tab (makefile recipe line): '\t' then "gcc".
    var line = String("\tgcc")
    # byte 0 is the tab; byte 1 ('g') sits at the cell-4 tab stop.
    assert_equal(utf8_cell_of_byte(line, 0), 0)
    assert_equal(utf8_cell_of_byte(line, 1), 4)
    assert_equal(utf8_cell_of_byte(line, 2), 5)
    # Inverse: cell 4 maps back to the 'g' byte; columns inside the tab's
    # expansion (1..3) snap to the tab's own start byte.
    assert_equal(utf8_byte_of_cell(line, 0), 0)
    assert_equal(utf8_byte_of_cell(line, 1), 0)
    assert_equal(utf8_byte_of_cell(line, 3), 0)
    assert_equal(utf8_byte_of_cell(line, 4), 1)

    # Agreement with the painter's own byte→cell map and with put_text.
    var cm = utf8_byte_to_cell(line)
    assert_equal(cm[0], 0)
    assert_equal(cm[1], 4)
    assert_equal(utf8_codepoint_count(line), 7)  # 4-cell tab + "gcc"
    var c = Canvas(20, 1)
    _ = c.put_text(Point(0, 0), line, default_attr())
    assert_equal(c.get(0, 0).glyph, String(" "))  # tab → spaces
    assert_equal(c.get(4, 0).glyph, String("g"))  # 'g' lands at cell 4

    # A tab partway through a line aligns to the *next* stop, not +4.
    var mid = String("ab\tc")  # a,b at 0,1; tab 2→4; c at 4
    assert_equal(utf8_cell_of_byte(mid, 2), 2)
    assert_equal(utf8_cell_of_byte(mid, 3), 4)
    assert_equal(utf8_byte_of_cell(mid, 4), 3)

    # Gutter offset: editor content starts right of the line-number gutter,
    # so a leading tab must expand to a FULL tab width measured from where
    # the text starts (``tab_base``), not from physical screen column 0.
    # Painting at column 6 (6 % 4 == 2) without a tab_base would collapse
    # the tab to 2 cells — the bug behind the makefile caret drift.
    var gut = Canvas(20, 1)
    _ = gut.put_text(Point(6, 0), line, default_attr(), -1, 6)  # tab_base=6
    assert_equal(gut.get(6, 0).glyph, String(" "))   # tab fills cells 6..9
    assert_equal(gut.get(10, 0).glyph, String("g"))  # 'g' a full 4 past 6
    # Painter passes its paint origin as tab_base automatically, so editor
    # content tabs align to the text's own left edge regardless of gutter.
    var pc = Canvas(20, 1)
    var pnt = Painter(Rect(6, 0, 20, 1))
    _ = pnt.put_text(pc, Point(6, 0), line, default_attr())
    assert_equal(pc.get(10, 0).glyph, String("g"))


def test_paint_title_commands_renders_separator_and_labels() raises:
    """``paint_title_commands`` paints ``- <cmd1> <cmd2>`` after the
    given start point, returning one hit rect per fully-painted
    label (with x_end exclusive). The body-bg rule from
    ``paint_window_title`` applies here too — we don't assert
    colours but the basic glyph layout is enough to catch
    regressions."""
    var c = Canvas(40, 1)
    var commands = List[TitleCommand]()
    commands.append(TitleCommand(String("[A]"), String("a:1")))
    commands.append(TitleCommand(String("[BB]"), String("b:2")))
    var attr = Attr(WHITE, BLACK)
    var hits = paint_title_commands(
        c, Point(2, 0), commands, attr, attr, attr, 40,
    )
    # Layout: "- [A] [BB]" starting at x=2.
    assert_equal(c.get(2, 0).glyph, String("-"))
    assert_equal(c.get(3, 0).glyph, String(" "))
    assert_equal(c.get(4, 0).glyph, String("["))
    assert_equal(c.get(5, 0).glyph, String("A"))
    assert_equal(c.get(6, 0).glyph, String("]"))
    assert_equal(c.get(7, 0).glyph, String(" "))   # gap between commands
    assert_equal(c.get(8, 0).glyph, String("["))
    assert_equal(c.get(9, 0).glyph, String("B"))
    assert_equal(c.get(11, 0).glyph, String("]"))
    assert_equal(len(hits), 2)
    assert_equal(hits[0].id, String("a:1"))
    assert_equal(hits[0].x_start, 4)
    assert_equal(hits[0].x_end, 7)        # exclusive — past the ``]``
    assert_equal(hits[1].id, String("b:2"))
    assert_equal(hits[1].x_start, 8)
    assert_equal(hits[1].x_end, 12)


def test_paint_title_commands_drops_clipped_label() raises:
    """A label whose right edge would land past ``max_x`` must be
    skipped — we'd rather drop it than register a hit on a
    half-painted button."""
    var c = Canvas(20, 1)
    var commands = List[TitleCommand]()
    commands.append(TitleCommand(String("[A]"), String("a")))
    commands.append(TitleCommand(String("[verylong]"), String("b")))
    var attr = Attr(WHITE, BLACK)
    var hits = paint_title_commands(
        c, Point(0, 0), commands, attr, attr, attr, 8,
    )
    # Available range [0, 8): "- " (2) + "[A]" (3) = 5 cells used,
    # next gap + "[verylong]" wouldn't fit before x=8.
    assert_equal(len(hits), 1)
    assert_equal(hits[0].id, String("a"))


def test_menu_layout_pins_file_edit_window_help() raises:
    """Display order must always be File, Edit, [middle], Window, Help —
    regardless of insertion order. ``self.menus`` retains insertion order
    (so cached indices stay valid); only the layout rects reorder."""
    var bar = MenuBar()
    # Insert in deliberately scrambled order.
    bar.add(_empty_menu(String("Help")))
    bar.add(_empty_menu(String("Window")))
    bar.add(_empty_menu(String("Tools")))
    bar.add(_empty_menu(String("File")))
    bar.add(_empty_menu(String("Build")))
    bar.add(_empty_menu(String("Edit")))
    var rects = bar._layout(80)
    # Walk rects by display x; collect labels in order.
    var n = len(bar.menus)
    var sorted_labels = List[String]()
    var used = List[Bool]()
    for _ in range(n):
        used.append(False)
    for _ in range(n):
        var best = -1
        var best_x = 1_000_000
        for i in range(n):
            if used[i]: continue
            if rects[i].a.x < best_x and rects[i].b.x > rects[i].a.x:
                best_x = rects[i].a.x
                best = i
        if best < 0: break
        used[best] = True
        sorted_labels.append(bar.menus[best].label)
    assert_equal(len(sorted_labels), 6)
    assert_equal(sorted_labels[0], String("File"))
    assert_equal(sorted_labels[1], String("Edit"))
    # Middle two are Tools and Build in insertion order.
    assert_equal(sorted_labels[2], String("Tools"))
    assert_equal(sorted_labels[3], String("Build"))
    assert_equal(sorted_labels[4], String("Window"))
    assert_equal(sorted_labels[5], String("Help"))
    # The menus list itself must NOT be reordered (cached indices rely on it).
    assert_equal(bar.menus[0].label, String("Help"))
    assert_equal(bar.menus[5].label, String("Edit"))


def test_panel_rects_give_way_to_file_tree() raises:
    """Bottom-docked panes must not paint over the file tree: their
    rects stop at the tree's column on whichever side it's docked."""
    var d = Desktop()
    var screen = Rect(0, 0, 100, 30)
    d.detect_project_from(String("examples/hello.mojo"))
    d.debug_pane.visible = True
    d.test_pane.visible = True
    # No tree: full width.
    assert_equal(d.debug_pane_rect(screen).a.x, 0)
    assert_equal(d.debug_pane_rect(screen).b.x, 100)
    d._cycle_file_tree()    # tree on, docked right
    assert_equal(d.debug_pane_rect(screen).a.x, 0)
    assert_equal(d.debug_pane_rect(screen).b.x, 100 - FILE_TREE_WIDTH)
    assert_equal(d.test_pane_rect(screen).b.x, 100 - FILE_TREE_WIDTH)
    d._cycle_file_tree()    # docked left
    assert_equal(d.debug_pane_rect(screen).a.x, FILE_TREE_WIDTH)
    assert_equal(d.debug_pane_rect(screen).b.x, 100)
    assert_equal(d.test_pane_rect(screen).a.x, FILE_TREE_WIDTH)


def test_focus_loss_save_opt_out_when_auto_save_off() raises:
    """Setting ``config.auto_save = False`` (the Manual choice in
    Settings ▸ Editor ▸ Save behavior) suppresses both the
    window-to-window and the app-wide focus-loss saves — Ctrl+S
    becomes the only write path."""
    var path_a = _temp_path(String("_optout_a.txt"))
    var path_b = _temp_path(String("_optout_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    d.config.auto_save = False
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    d.paint(canvas, _SCREEN)
    # Dirty A.
    d.windows.focus_by_index(0)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    d.paint(canvas, _SCREEN)
    # Window-to-window focus switch — Manual: must NOT save.
    d.windows.focus_by_index(1)
    d.paint(canvas, _SCREEN)
    assert_true(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa\n"))
    # App-level focus-out — Manual: must NOT save either.
    _ = d.handle_event(Event.focus_event(False), _SCREEN)
    assert_true(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_ctrl_n_focuses_window_by_number() raises:
    """Ctrl+1..Ctrl+9 focus the corresponding window. The event has to
    arrive in the modifyOtherKeys form (mods=MOD_CTRL on a digit) since
    bare Ctrl+digit isn't representable as a control byte — but the
    parser already produces this form, and the hotkey table maps it to
    ``window:focus:N``. Crucially, ``windows`` itself stays in insertion
    order across focus changes so the bindings remain stable.

    The digits 0/2/4/5/6 ALSO have Cmd+ (MOD_META) bindings on the debug
    actions; those stay distinct from Ctrl+ since MOD_META and MOD_CTRL
    are separate modifier bits."""
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    assert_equal(d.windows.windows[d.windows.focused].title, String("c"))
    _ = d.handle_event(Event.key_event(UInt32(ord("1")), MOD_CTRL), _SCREEN)
    assert_equal(d.windows.focused, 0)
    assert_equal(d.windows.windows[0].title, String("a"))
    # The list order MUST NOT change just because focus changed.
    assert_equal(d.windows.windows[1].title, String("b"))
    assert_equal(d.windows.windows[2].title, String("c"))
    # Ctrl+2 focuses index 1 (still "b" thanks to stable list order).
    _ = d.handle_event(Event.key_event(UInt32(ord("2")), MOD_CTRL), _SCREEN)
    assert_equal(d.windows.focused, 1)
    assert_equal(d.windows.windows[d.windows.focused].title, String("b"))


def test_focus_changes_keep_window_list_order_stable() raises:
    """Repeated focus changes must not reshuffle ``windows``; only ``z_order``
    moves. This is what keeps Ctrl+N bindings (and the Window menu items)
    pointing at the same windows across rapid focus changes."""
    var wm = WindowManager()
    wm.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    wm.focus_by_index(0)
    wm.focus_by_index(2)
    wm.focus_by_index(1)
    wm.focus_by_index(0)
    assert_equal(wm.windows[0].title, String("a"))
    assert_equal(wm.windows[1].title, String("b"))
    assert_equal(wm.windows[2].title, String("c"))
    # z-order tail is the most recently focused window.
    assert_equal(wm.z_order[len(wm.z_order) - 1], 0)


def test_cmd_w_closes_focused_window() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("first"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    d.windows.add(Window.editor_window(
        String("second"), Rect(0, 1, 40, 12), String("world\n"),
    ))
    assert_equal(len(d.windows.windows), 2)
    var ev = Event.key_event(UInt32(ord("w")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_equal(len(d.windows.windows), 1)
    assert_equal(d.windows.windows[0].title, String("first"))


def test_menu_items_get_shortcut_text_after_refresh() raises:
    """Once Desktop's _refresh_shortcuts runs, every menu item that maps to
    a registered hotkey has the matching shortcut string stamped onto it."""
    var d = Desktop()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"),  EDITOR_SAVE))
    items.append(MenuItem(String("Quit"),  APP_QUIT_ACTION))
    items.append(MenuItem(String("Close"), WINDOW_CLOSE))
    items.append(MenuItem(String("New"),   String("noop")))
    d.menu_bar.add(Menu(String("File"), items^))
    d._refresh_shortcuts()
    var file_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
            break
    assert_true(file_idx >= 0)
    var fm = d.menu_bar.menus[file_idx].copy()
    assert_equal(fm.items[0].shortcut, String("Cmd+S"))
    assert_equal(fm.items[1].shortcut, String("Cmd+Q"))
    assert_equal(fm.items[2].shortcut, String("Cmd+W"))
    # Item with no registered hotkey: empty.
    assert_equal(fm.items[3].shortcut, String(""))


def test_cmd_s_via_modify_other_keys_triggers_save_hotkey() raises:
    """End-to-end: a Cmd+S event delivered as ``CSI 27;9;115~`` parses as
    ``(ord('s'), MOD_META)`` and triggers ``EDITOR_SAVE`` via the Cmd+S
    binding. Ctrl+S is intentionally *not* bound — Ctrl is reserved for
    window/panel focus."""
    var d = Desktop()
    var parsed = parse_input(String("\x1b[27;9;115~"))
    assert_true(parsed[0].kind == EVENT_KEY)
    assert_equal(Int(parsed[0].key), Int(ord("s")))
    assert_equal(Int(parsed[0].mods), Int(MOD_META))
    var maybe = d.handle_event(parsed[0], _SCREEN)
    # No editor focused → save is a no-op intercepted by Desktop. The
    # important assertion is that the action *was* recognized: nothing
    # bubbles back to the caller.
    assert_false(Bool(maybe))


def test_cmd_q_modifyOtherKeys_triggers_quit_action() raises:
    """End-to-end: a Cmd+Q event delivered as the modifyOtherKeys form
    parses to ``(ord('q'), MOD_META)`` and matches the default Cmd+Q
    hotkey. The Desktop returns APP_QUIT_ACTION; nothing is inserted
    into the focused editor."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    # ESC[27;9;113~ — modifyOtherKeys=2 form for Cmd+Q (mod = 1 + 8).
    var parsed = parse_input(String("\x1b[27;9;113~"))
    assert_true(parsed[0].kind == EVENT_KEY)
    var maybe = d.handle_event(parsed[0], _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)
    # And the buffer is untouched — none of the trailing bytes leaked.
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("hello"))


def test_ctrl_key_helper() raises:
    """``ctrl_key`` returns the canonical key codepoint for a
    ``Ctrl+letter`` hotkey: the lowercase letter codepoint (paired
    with ``MOD_CTRL`` at registration)."""
    assert_equal(Int(ctrl_key(String("q"))), Int(ord("q")))
    assert_equal(Int(ctrl_key(String("Q"))), Int(ord("q")))  # case-folded
    assert_equal(Int(ctrl_key(String("a"))), Int(ord("a")))
    assert_equal(Int(ctrl_key(String("z"))), Int(ord("z")))
    assert_equal(Int(ctrl_key(String("f"))), Int(ord("f")))


def test_menu_keyboard_nav_arrows_and_enter() raises:
    """Up/Down step the dropdown selection (skipping separators), Left/Right
    rotate to the next visible menu, Enter triggers the selected item's
    action."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"),  String("noop")))
    file_items.append(MenuItem.separator())
    file_items.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    d.menu_bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find..."), EDITOR_FIND))
    d.menu_bar.add(Menu(String("Edit"), edit_items^))
    # Open File via mnemonic; selection lands on the first non-separator.
    _ = d.handle_event(Event.key_event(UInt32(ord("f")), MOD_ALT), _SCREEN)
    var file_idx = -1
    var edit_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
        elif d.menu_bar.menus[i].label == String("Edit"):
            edit_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)
    assert_equal(d.menu_bar.selected_item, 0)   # New
    # Down skips the separator at index 1 → lands on Quit (index 2).
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    assert_equal(d.menu_bar.selected_item, 2)
    # Down wraps back to New (skipping the separator the long way).
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    assert_equal(d.menu_bar.selected_item, 0)
    # Right rotates to the Edit menu; selection resets.
    _ = d.handle_event(Event.key_event(KEY_RIGHT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, edit_idx)
    assert_equal(d.menu_bar.selected_item, 0)
    # Left rotates back.
    _ = d.handle_event(Event.key_event(KEY_LEFT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, file_idx)
    # Down to Quit, then Enter — the framework dispatches APP_QUIT_ACTION
    # back to the caller.
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    var maybe = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)
    # Activating an item closes the menu.
    assert_false(d.menu_bar.is_open())


def test_esc_prefix_opens_menu_by_mnemonic() raises:
    """Classic TV / DOS-style two-key sequence: ESC, then a letter, opens
    the matching menu. Lets users on macOS terminals (where Option+F is
    intercepted by the OS) still reach the mnemonic without reconfiguring
    their terminal."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    # First press: ESC alone. No menu opens; no action bubbles up.
    var maybe1 = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(Bool(maybe1))
    assert_false(d.menu_bar.is_open())
    # Second press: F. The framework picks it up as a mnemonic.
    var maybe2 = d.handle_event(
        Event.key_event(UInt32(ord("f"))), _SCREEN,
    )
    assert_false(Bool(maybe2))
    assert_true(d.menu_bar.is_open())
    var file_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)


def test_esc_prefix_disarms_after_one_keystroke() raises:
    """A non-letter (or unmatched letter) following ESC must disarm the
    prefix; the third keystroke is plain again."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String(""),
    ))
    _ = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    # No menu starts with 'z' — the keystroke disarms but doesn't open.
    _ = d.handle_event(Event.key_event(UInt32(ord("z"))), _SCREEN)
    assert_false(d.menu_bar.is_open())
    # Now type 'f' — it should reach the editor as plain typing, not the
    # mnemonic, because the previous keystroke disarmed the prefix.
    _ = d.handle_event(Event.key_event(UInt32(ord("f"))), _SCREEN)
    assert_false(d.menu_bar.is_open())
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("zf"))


def test_hotkey_overrides_default_when_registered_later() raises:
    """Registrations are scanned newest-first, so a later-registered binding
    for the same key/mods pair wins."""
    var d = Desktop()
    # Bind Cmd+Q to a custom app action; the default (APP_QUIT_ACTION)
    # should no longer fire.
    d.register_hotkey(UInt32(ord("q")), MOD_META, String("custom:thing"))
    var ev = Event.key_event(UInt32(ord("q")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), String("custom:thing"))


def test_hotkey_does_not_fire_while_prompt_active() raises:
    """Prompt modal keys must reach the prompt, not the hotkey table."""
    var d = Desktop()
    d.prompt.open(String("Find: "))
    # Without the modal-prompt guard, Cmd+Q here would return APP_QUIT.
    var ev = Event.key_event(UInt32(ord("q")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_true(d.prompt.active)


def test_menu_open_dropdown_type_to_jump() raises:
    """An open menu dropdown jumps to the first item whose label
    starts with the typed letter. Mnemonics use Alt+letter and run
    at the Desktop layer, so plain letters are free for in-dropdown
    search."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("New"),    String("file.new")))
    items.append(MenuItem(String("Open"),   String("file.open")))
    items.append(MenuItem(String("Save"),   String("file.save")))
    items.append(MenuItem(String("Save as"), String("file.saveas")))
    bar.add(Menu(String("File"), items^))
    bar.open_menu(0)
    assert_equal(bar.selected_item, 0)  # New
    var result = bar.handle_key(_key(UInt32(ord("s"))))
    assert_true(result.consumed)
    assert_equal(bar.selected_item, 2)  # Save


def test_cmd_o_bubbles_file_open() raises:
    """Cmd+O always bubbles ``EDITOR_OPEN`` up to the host so the
    framework's ``FileDialog`` can be used; the project-aware Quick
    Open picker is on Cmd+Shift+O."""
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    var ev = Event.key_event(UInt32(ord("o")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), EDITOR_OPEN)
    assert_false(d.quick_open.active)


def test_cmd_shift_o_opens_quick_open_when_project_active() raises:
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    var ev = Event.key_event(UInt32(ord("o")), MOD_META | MOD_SHIFT)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_true(d.quick_open.active)


def test_cmd_shift_o_bubbles_when_no_project() raises:
    var d = Desktop()
    var ev = Event.key_event(UInt32(ord("o")), MOD_META | MOD_SHIFT)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), EDITOR_QUICK_OPEN)
    assert_false(d.quick_open.active)


def test_painter_clips_text_at_right_edge() raises:
    """Long text passed to ``Painter.put_text`` must not bleed past the
    clip's right edge — every cell beyond ``clip.b.x`` stays untouched."""
    var canvas = Canvas(20, 3)
    canvas.fill(Rect(0, 0, 20, 3), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(2, 1, 8, 2))   # 6-cell wide clip
    _ = painter.put_text(
        canvas, Point(2, 1),
        String("ABCDEFGHIJKLMNOP"), Attr(BLACK, BLUE),
    )
    # Cells inside the clip get the letters; cells just outside on the
    # right keep their sentinel.
    assert_equal(canvas.get(2, 1).glyph, String("A"))
    assert_equal(canvas.get(7, 1).glyph, String("F"))
    assert_equal(canvas.get(8, 1).glyph, String("·"))   # right neighbour intact
    assert_equal(canvas.get(1, 1).glyph, String("·"))   # left neighbour intact
    # Drawing on a row outside the clip is a no-op.
    _ = painter.put_text(
        canvas, Point(2, 0),
        String("OUTSIDE"), Attr(BLACK, BLUE),
    )
    assert_equal(canvas.get(2, 0).glyph, String("·"))


def test_painter_skips_codepoints_left_of_clip() raises:
    """When the start point is left of the clip, leading codepoints
    must be skipped one cell at a time (codepoint-aware) so the
    remaining glyphs land at the right visual columns. ``café WORLD``
    occupies cells 0..9; with the clip starting at cell 5, only
    ``WORLD`` should appear, at its expected columns."""
    var canvas = Canvas(20, 1)
    canvas.fill(Rect(0, 0, 20, 1), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(5, 0, 15, 1))
    _ = painter.put_text(
        canvas, Point(0, 0),
        String("café WORLD"),
        Attr(BLACK, BLUE),
    )
    # Cells 0..4 left of clip stay sentinel.
    for x in range(5):
        assert_equal(canvas.get(x, 0).glyph, String("·"))
    # ``W``..``D`` land at cells 5..9 — same columns they would in an
    # unclipped paint, which is the whole point of codepoint-aware
    # skipping (a byte-stride skip would drop one extra cell from the
    # 2-byte ``é`` and shift everything left).
    assert_equal(canvas.get(5, 0).glyph, String("W"))
    assert_equal(canvas.get(6, 0).glyph, String("O"))
    assert_equal(canvas.get(9, 0).glyph, String("D"))
    # Cells 10..14 (still inside the clip) and 15+ (right of clip)
    # never got a glyph.
    assert_equal(canvas.get(10, 0).glyph, String("·"))
    assert_equal(canvas.get(15, 0).glyph, String("·"))


def test_painter_fill_intersects_with_clip() raises:
    var canvas = Canvas(10, 5)
    canvas.fill(Rect(0, 0, 10, 5), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(2, 1, 7, 4))
    # Caller-rect overhangs the clip; the fill is automatically trimmed.
    painter.fill(canvas, Rect(0, 0, 100, 100), String("#"), Attr(BLACK, BLUE))
    assert_equal(canvas.get(0, 0).glyph, String("·"))
    assert_equal(canvas.get(2, 1).glyph, String("#"))
    assert_equal(canvas.get(6, 3).glyph, String("#"))
    assert_equal(canvas.get(7, 3).glyph, String("·"))   # one past clip
    assert_equal(canvas.get(2, 4).glyph, String("·"))   # one below clip


def test_menu_hover_switches_open_menu() raises:
    """While a menu is open, hovering (button=NONE, motion=True) over a
    different menu in the bar switches the open menu to it. This is the
    macOS-style sticky behavior the user gets after a click-then-move."""
    var bar = MenuBar()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find"), EDITOR_FIND))
    bar.add(Menu(String("Edit"), edit_items^))
    bar.open_menu(0)
    var rects = bar._layout(80)
    var edit_x = (rects[1].a.x + rects[1].b.x) // 2
    var hover = Event.mouse_event(
        Point(edit_x, 0), MOUSE_BUTTON_NONE, True, True,
    )
    var r = bar.handle_event(hover, 80)
    assert_true(r.consumed)
    assert_equal(bar.open_idx, 1)


def test_menu_drag_release_on_item_triggers() raises:
    """Click-and-hold on File, drag down into the dropdown, release on the
    Save row → the release fires EDITOR_SAVE without an extra click."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    items.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    # Press on File — opens the menu, starts tracking.
    var press = Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False)
    _ = bar.handle_event(press, 80)
    assert_equal(bar.open_idx, 0)
    assert_true(bar.tracking)
    # Drag onto the second item in the dropdown.
    var dr = bar._dropdown_rect(80)
    var item_y = dr.a.y + 1 + 1   # row 1 inside the dropdown = "Quit"
    var drag = Event.mouse_event(
        Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, True, True,
    )
    _ = bar.handle_event(drag, 80)
    assert_equal(bar.selected_item, 1)
    # Release on the dragged-onto item triggers it.
    var release = Event.mouse_event(
        Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, False, False,
    )
    var r = bar.handle_event(release, 80)
    assert_true(r.action)
    assert_equal(r.action.value(), APP_QUIT_ACTION)
    assert_false(bar.is_open())
    assert_false(bar.tracking)


def test_menu_drag_release_outside_closes() raises:
    """Click-and-hold on File, drag off the bar and dropdown, release in
    empty space → the menu closes (drag-select cancellation)."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False), 80,
    )
    assert_true(bar.is_open())
    assert_true(bar.tracking)
    # Drag well below the dropdown, then release there.
    var dr = bar._dropdown_rect(80)
    var off = Point(dr.b.x + 5, dr.b.y + 5)
    _ = bar.handle_event(
        Event.mouse_event(off, MOUSE_BUTTON_LEFT, True, True), 80,
    )
    var r = bar.handle_event(
        Event.mouse_event(off, MOUSE_BUTTON_LEFT, False, False), 80,
    )
    assert_false(r.action)
    assert_false(bar.is_open())
    assert_false(bar.tracking)


def test_menu_click_then_click_flow() raises:
    """Sticky/Mac-style flow: a click that lands on File and releases there
    leaves the menu open in non-tracking mode; a separate later press +
    release on a dropdown item then triggers it (release fires, like a
    button)."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    # First click: press + release on File. Menu opens, tracking clears on
    # release.
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False), 80,
    )
    assert_true(bar.tracking)
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, False, False), 80,
    )
    assert_equal(bar.open_idx, 0)
    assert_false(bar.tracking)
    # Second click: press on the dropdown item highlights + re-arms tracking
    # but does NOT fire; the release is what runs the action.
    var dr = bar._dropdown_rect(80)
    var item_y = dr.a.y + 1
    var press = bar.handle_event(
        Event.mouse_event(Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, True, False),
        80,
    )
    assert_false(press.action)
    assert_true(bar.tracking)
    assert_true(bar.is_open())
    var r = bar.handle_event(
        Event.mouse_event(Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, False, False),
        80,
    )
    assert_true(r.action)
    assert_equal(r.action.value(), EDITOR_SAVE)
    assert_false(bar.is_open())


def test_paint_editor_region_does_not_mutate_minimap_spell_state() raises:
    """Regression: the smooth-scroll body composite (``paint_editor_region``)
    must NOT advance the shared spell/minimap state.

    The native host clips the right-edge minimap gutter out of that composite
    and keeps the prior main frame's gutter, repainting only the scrolling
    body. So if a body-only render cleared ``spell_lines`` as a side effect
    (it used to, via an inner ``flush_highlights``), the minimap mark would
    linger after the inline squiggle cleared — exactly what happens right
    after adding a word to the dictionary while the editor is mid-scroll. Only
    the main ``paint`` — which also repaints the gutter — may flush, so body
    and gutter clear on the same frame.
    """
    var path = _temp_path(String("_minimap_spell.py"))
    var content = String("# this flarbnik here\n")
    for i in range(1, 80):
        content += "x = " + String(i) + "\n"
    assert_true(write_file(path, content))
    var d = Desktop()
    var screen = Rect(0, 0, 120, 40)
    var canvas = Canvas(120, 40)
    d.open_file_at(path, 0, 0, screen)
    # Deterministic dictionary (don't depend on /usr/share/dict): "flarbnik"
    # is absent so it's flagged; "this"/"here" are present so they aren't.
    var dict = List[String]()
    dict.append(String("this"))
    dict.append(String("here"))
    d.speller.load_words(dict)
    d.paint(canvas, screen)
    d.paint(canvas, screen)
    var win = -1
    for i in range(len(d.windows.windows)):
        if d.windows.windows[i].is_editor:
            win = i
    assert_true(win >= 0)
    assert_true(_has_spell_mark(d.windows.windows[win].editor))  # mark present

    # Simulate "Add to dictionary": the word becomes known + spell invalidated.
    dict.append(String("flarbnik"))
    d.speller.load_words(dict)
    d.windows.windows[win].editor.invalidate_spell()
    # Still marked until a main paint re-derives it — the gutter on screen
    # still shows the mark at this point, which is fine.
    assert_true(_has_spell_mark(d.windows.windows[win].editor))

    # The body-only composite render must leave ``spell_lines`` untouched, or
    # the gutter (kept from the prior main frame) and the freshly-composited
    # body would disagree.
    var body = Canvas(120, 50)
    d.paint_editor_region(win, body, 120, 50, True)
    assert_true(_has_spell_mark(d.windows.windows[win].editor))

    # The next main paint (which repaints the gutter) clears it — both clear
    # on the same frame.
    d.paint(canvas, screen)
    assert_false(_has_spell_mark(d.windows.windows[win].editor))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_status_bar_tab_hit_test() raises:
    """Painting the bar captures per-tab rects; ``hit_test_tab`` then
    routes a click on each tab to its index, and a click outside
    the strip to -1."""
    var sb = StatusBar()
    var tabs = List[StatusTab]()
    tabs.append(StatusTab(String("tests"), False, False))
    tabs.append(StatusTab(String("main"), False, False))
    sb.set_tabs(tabs^, 0)
    var canvas = Canvas(80, 10)
    sb.paint(canvas, Rect(0, 0, 80, 10))
    var y = 9   # screen.b.y - 1
    var first = sb.hit_test_tab(Point(2, y), Rect(0, 0, 80, 10))
    var second = sb.hit_test_tab(Point(15, y), Rect(0, 0, 80, 10))
    # First tab starts at column 2 (1 padding + 1 separator); the
    # second tab is several columns over. Either way both >= 0.
    assert_true(first >= 0)
    assert_true(second >= 0)
    # Clicks on a different row never hit a tab.
    assert_equal(sb.hit_test_tab(Point(2, 0), Rect(0, 0, 80, 10)), -1)


def test_shadow_button_paints_face_and_shadow() raises:
    """The shared button widget must paint the label on a green
    face and drop a half-block shadow on the right column + the
    row below — same idiom the dir_browser jump strip uses."""
    var canvas = Canvas(20, 4)
    canvas.fill(Rect(0, 0, 20, 4), String(" "), Attr(BLACK, LIGHT_GRAY))
    var btn = ShadowButton(String(" OK "), 2, 1)
    paint_shadow_button(canvas, btn, Attr(BLACK, GREEN), LIGHT_GRAY)
    # Face row carries the label on green.
    assert_equal(canvas.get(2, 1).glyph, String(" "))
    assert_equal(canvas.get(3, 1).glyph, String("O"))
    assert_equal(canvas.get(4, 1).glyph, String("K"))
    assert_equal(canvas.get(3, 1).attr.bg, GREEN)
    # Right-edge shadow column at face_width + x.
    assert_equal(canvas.get(2 + 4, 1).glyph, String("▄"))
    assert_equal(canvas.get(2 + 4, 1).attr.bg, LIGHT_GRAY)
    # Bottom shadow row, shifted right by 1.
    assert_equal(canvas.get(3, 2).glyph, String("▀"))
    assert_equal(canvas.get(2 + 4, 2).glyph, String("▀"))
    # Cell to the left of the button stays untouched.
    assert_equal(canvas.get(1, 1).glyph, String(" "))
    assert_equal(canvas.get(1, 1).attr.bg, LIGHT_GRAY)


def test_shadow_button_hit_includes_shadow_rows() raises:
    """A click on the bottom-shadow row should still register —
    users miss-click downward routinely. Clicks outside the hit
    rect (or on motion / non-press events) must be rejected."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    # Press inside the face.
    var press_face = Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_face))
    # Press on the right-shadow column.
    var press_shadow_r = Event.mouse_event(Point(6, 1), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_shadow_r))
    # Press on the bottom-shadow row.
    var press_shadow_b = Event.mouse_event(Point(4, 2), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_shadow_b))
    # Press just below the shadow row — outside.
    var miss = Event.mouse_event(Point(4, 3), MOUSE_BUTTON_LEFT)
    assert_false(shadow_button_hit(btn, miss))
    # Release events don't activate.
    var release = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_false(shadow_button_hit(btn, release))


def test_paint_drop_shadow_targets_right_and_bottom() raises:
    """``paint_drop_shadow`` darkens the 2-cell right strip (offset
    one row down from the top edge) and the 1-row bottom strip
    (offset 2 cells right of the left edge), matching the diagonal
    "lifted" effect of the per-button shadows."""
    var c = Canvas(20, 8)
    # Background that the shadow needs to dim.
    c.fill(Rect(0, 0, 20, 8), String("·"), Attr(WHITE, BLUE))
    var dialog = Rect(3, 2, 13, 6)   # 10×4 dialog
    paint_drop_shadow(c, dialog)
    # Right strip: x in {13, 14}, y in [3, 6).
    assert_equal(c.get(13, 3).attr.bg, PANE_BG)
    assert_equal(c.get(14, 3).attr.bg, PANE_BG)
    assert_equal(c.get(13, 5).attr.bg, PANE_BG)
    assert_equal(c.get(14, 5).attr.bg, PANE_BG)
    # Glyph underneath the shadow survives.
    assert_equal(c.get(13, 3).glyph, String("·"))
    # Top-right corner of the dialog is *not* shadowed (shadow starts
    # one row down so the top edge looks "lit").
    assert_equal(c.get(13, 2).attr.bg, BLUE)
    # Bottom strip: x in [5, 15), y == 6.
    assert_equal(c.get(5, 6).attr.bg, PANE_BG)
    assert_equal(c.get(14, 6).attr.bg, PANE_BG)
    # The two cells immediately under the dialog's left edge are
    # *not* shadowed (offset 2) — keeps the bottom-left corner lit.
    assert_equal(c.get(3, 6).attr.bg, BLUE)
    assert_equal(c.get(4, 6).attr.bg, BLUE)
    # Cells inside the dialog rect are untouched by the shadow.
    assert_equal(c.get(5, 3).attr.bg, BLUE)


def test_docked_panel_stack_layout_normal_split() raises:
    """All sections NORMAL → equal share of available content rows."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    # 23 rows total. 2 splitter rows between 3 sections → 21 content rows.
    # Equal share: 7 each.
    var lay = dock.layout(0, 23)
    assert_equal(len(lay), 6)
    assert_equal(lay[0], 0)   # section 0 top
    assert_equal(lay[1], 7)   # section 0 height
    assert_equal(lay[2], 8)   # section 1 top (0 + 7 + 1 splitter)
    assert_equal(lay[3], 7)
    assert_equal(lay[4], 16)
    assert_equal(lay[5], 7)


def test_docked_panel_stack_max_collapses_others() raises:
    """Maximizing one section should give it nearly all the content
    while the other two collapse to header-only (height 1)."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    dock.toggle_max(1)  # Maximize section B
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_NORMAL))
    assert_equal(Int(dock.state(1)), Int(PANEL_STATE_MAXIMIZED))
    assert_equal(Int(dock.state(2)), Int(PANEL_STATE_NORMAL))
    var lay = dock.layout(0, 23)
    # 21 content rows, A and C take 1 each → B gets 19.
    assert_equal(lay[1], 1)
    assert_equal(lay[3], 19)
    assert_equal(lay[5], 1)
    # Title rows still positioned correctly (so the user sees them).
    assert_equal(lay[0], 0)
    assert_equal(lay[2], 2)   # 0 + 1 + 1 splitter
    assert_equal(lay[4], 22)  # 2 + 19 + 1 splitter


def test_docked_panel_stack_max_then_restore_resets_all() raises:
    """Toggling max twice on the same section restores everyone to
    NORMAL (and clears the other sections' visually-min'd state too)."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    dock.toggle_max(0)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_MAXIMIZED))
    dock.toggle_max(0)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_NORMAL))
    assert_equal(Int(dock.state(1)), Int(PANEL_STATE_NORMAL))
    assert_true(dock.all_normal())


def test_docked_panel_stack_min_collapses_one() raises:
    """A single minimized section stays at height 1; the rest split
    the leftover."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    dock.toggle_min(0)
    var lay = dock.layout(0, 23)
    assert_equal(lay[1], 1)
    # 21 - 1 = 20 across two NORMALs → 10 each.
    assert_equal(lay[3], 10)
    assert_equal(lay[5], 10)


def test_docked_panel_stack_min_on_max_sibling_clears_max() raises:
    """If section A is MAXIMIZED (so B is visually min'd), clicking
    B's min/restore button must clear A's max and restore B to NORMAL —
    the ``effective`` state on B was MINIMIZED (because of A), so the
    click is treated as a restore."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    dock.toggle_max(0)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_MAXIMIZED))
    # Click min/restore on B — the visually-min'd sibling.
    dock.toggle_min(1)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_NORMAL))
    assert_equal(Int(dock.state(1)), Int(PANEL_STATE_NORMAL))
    assert_true(dock.all_normal())


def test_floating_panel_splitter_drag_resizes_upper_pane() raises:
    """Floating panel window: dragging the splitter between two stacked
    panels resizes the panel *above* it (top-anchored), not the lower
    one. The lower panel absorbs the remainder, so the docked path's
    bottom-anchored `height = bottom - cursor` math would leave the
    upper pane untouched — this is the regression that bug fixed."""
    var d = Desktop()
    # Two non-terminal panels (no pty needed): debug on top, test below.
    d.debug_pane.visible = True
    d.test_pane.visible = True
    d.panels_detached = True
    var screen = Rect(0, 0, 80, 40)
    # Default preferred_height is 14, so the debug slot is rows [0,14)
    # and the test slot (last) absorbs [14,40). The splitter is row 14.
    assert_equal(d.debug_pane.dock.preferred_height, 14)
    assert_equal(d.test_pane.dock.preferred_height, 14)
    # The splitter row shows the vertical-resize cursor.
    assert_equal(
        d.pointer_shape_panels(Point(5, 14), screen), String("ns-resize"),
    )
    # Press on the splitter (x=5 avoids the right-edge chrome buttons),
    # drag down to row 22, release.
    _ = d.handle_panels_event(
        Event.mouse_event(Point(5, 14), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    _ = d.handle_panels_event(
        Event.mouse_event(Point(5, 22), MOUSE_BUTTON_LEFT, True, True),
        screen,
    )
    _ = d.handle_panels_event(
        Event.mouse_event(Point(5, 22), MOUSE_BUTTON_LEFT, False, False),
        screen,
    )
    # Upper (debug) pane grew to the cursor row; lower (test) pane,
    # which only absorbs the remainder, kept its preferred height.
    assert_equal(d.debug_pane.dock.preferred_height, 22)
    assert_equal(d.test_pane.dock.preferred_height, 14)
    assert_false(d.debug_pane.dock.is_resizing())


def test_floating_panel_top_border_does_not_self_resize() raises:
    """A press on the *first* panel's top border (the window's top row,
    no splitter above it) must not start a resize — only focus. The
    docked path would have started a bottom-anchored drag here."""
    var d = Desktop()
    d.debug_pane.visible = True
    d.test_pane.visible = True
    d.panels_detached = True
    var screen = Rect(0, 0, 80, 40)
    _ = d.handle_panels_event(
        Event.mouse_event(Point(5, 0), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_false(d.debug_pane.dock.is_resizing())
    # A subsequent drag therefore changes nothing.
    _ = d.handle_panels_event(
        Event.mouse_event(Point(5, 8), MOUSE_BUTTON_LEFT, True, True),
        screen,
    )
    assert_equal(d.debug_pane.dock.preferred_height, 14)


def test_floating_panel_title_command_click_beats_splitter() raises:
    """Clicking a title-strip command button (Stop / Restart / Clear) on
    a panel that sits *below* another panel in the floating window must
    fire the command — not start a splitter drag for the panel above.
    The splitter check excludes the min/max chrome and must exclude the
    command strip the same way. This was a real regression: the run
    pane's Stop/Restart/Clear were dead whenever another panel sat
    above it in the floating stack."""
    var d = Desktop()
    d.panels_detached = True
    var screen = Rect(0, 0, 80, 40)
    # Post-run hold on both panes keeps them visible through dap_tick
    # and builds their command strips (Restart/Re-run + Clear).
    d._run_output_held = True
    d._test_output_held = True
    d.dap_tick(screen)
    # Paint the floating stack so the title rows latch their hit rects.
    var canvas = Canvas(80, 40)
    canvas.clear(default_attr())
    d.paint_panels(canvas, screen)
    # The test pane is the lower panel; its title row is the splitter
    # row for the debug pane above.
    assert_true(len(d.test_pane.dock.last_cmd_hits) > 0)
    var hit = d.test_pane.dock.last_cmd_hits[0].copy()
    var pos = Point((hit.x_start + hit.x_end) // 2, hit.y)
    _ = d.handle_panels_event(
        Event.mouse_event(pos, MOUSE_BUTTON_LEFT, True, False), screen,
    )
    # The button latched its command; no splitter drag started.
    assert_false(d.debug_pane.dock.is_resizing())
    assert_equal(d.test_pane.dock.pending_command_id, hit.id)
    _ = d.handle_panels_event(
        Event.mouse_event(pos, MOUSE_BUTTON_LEFT, False, False), screen,
    )
    # A press on the same row but *off* the buttons still starts the
    # splitter drag for the pane above.
    var last = d.test_pane.dock.last_cmd_hits[
        len(d.test_pane.dock.last_cmd_hits) - 1
    ].copy()
    _ = d.handle_panels_event(
        Event.mouse_event(
            Point(last.x_end + 2, last.y), MOUSE_BUTTON_LEFT, True, False,
        ),
        screen,
    )
    assert_true(d.debug_pane.dock.is_resizing())


def test_floating_panel_minimize_bottom_keeps_one_row() raises:
    """Minimizing the *bottom* panel in the floating window must collapse
    it to its single header row — the upper panel becomes the absorber and
    takes the freed rows. Regression: the old layout let the last panel
    absorb the remainder unconditionally, so minimizing it did nothing."""
    var d = Desktop()
    d.debug_pane.visible = True   # top
    d.test_pane.visible = True    # bottom
    d.panels_detached = True
    var screen = Rect(0, 0, 80, 40)
    d.test_pane.dock.set_state(PANEL_STATE_MINIMIZED)
    var slots = d._panel_window_slots(screen)
    assert_equal(len(slots), 2)
    # Bottom (test) pane collapses to one row; top (debug) absorbs the rest.
    assert_equal(slots[1].rect.a.y, 39)
    assert_equal(slots[1].rect.b.y, 40)
    assert_equal(slots[0].rect.a.y, 0)
    assert_equal(slots[0].rect.b.y, 39)


def test_floating_panel_minimize_top_keeps_one_row() raises:
    """Minimizing the *top* panel collapses it to one row and the bottom
    panel (the absorber) takes the rest — the symmetric case."""
    var d = Desktop()
    d.debug_pane.visible = True   # top
    d.test_pane.visible = True    # bottom
    d.panels_detached = True
    var screen = Rect(0, 0, 80, 40)
    d.debug_pane.dock.set_state(PANEL_STATE_MINIMIZED)
    var slots = d._panel_window_slots(screen)
    assert_equal(len(slots), 2)
    assert_equal(slots[0].rect.a.y, 0)
    assert_equal(slots[0].rect.b.y, 1)
    assert_equal(slots[1].rect.a.y, 1)
    assert_equal(slots[1].rect.b.y, 40)


def main() raises:
    setup_test_env()
    test_hotkeys_page_is_generated_from_registry()
    test_hotkey_gate_registers_editor_chords()
    test_tab_cell_byte_converters_match_put_text()
    test_paint_title_commands_renders_separator_and_labels()
    test_paint_title_commands_drops_clipped_label()
    test_menu_layout_pins_file_edit_window_help()
    test_panel_rects_give_way_to_file_tree()
    test_focus_loss_save_opt_out_when_auto_save_off()
    test_ctrl_n_focuses_window_by_number()
    test_focus_changes_keep_window_list_order_stable()
    test_cmd_w_closes_focused_window()
    test_menu_items_get_shortcut_text_after_refresh()
    test_cmd_s_via_modify_other_keys_triggers_save_hotkey()
    test_cmd_q_modifyOtherKeys_triggers_quit_action()
    test_ctrl_key_helper()
    test_menu_keyboard_nav_arrows_and_enter()
    test_esc_prefix_opens_menu_by_mnemonic()
    test_esc_prefix_disarms_after_one_keystroke()
    test_hotkey_overrides_default_when_registered_later()
    test_hotkey_does_not_fire_while_prompt_active()
    test_menu_open_dropdown_type_to_jump()
    test_cmd_o_bubbles_file_open()
    test_cmd_shift_o_opens_quick_open_when_project_active()
    test_cmd_shift_o_bubbles_when_no_project()
    test_painter_clips_text_at_right_edge()
    test_painter_skips_codepoints_left_of_clip()
    test_painter_fill_intersects_with_clip()
    test_menu_hover_switches_open_menu()
    test_menu_drag_release_on_item_triggers()
    test_menu_drag_release_outside_closes()
    test_menu_click_then_click_flow()
    test_paint_editor_region_does_not_mutate_minimap_spell_state()
    test_status_bar_tab_hit_test()
    test_shadow_button_paints_face_and_shadow()
    test_shadow_button_hit_includes_shadow_rows()
    test_paint_drop_shadow_targets_right_and_bottom()
    test_docked_panel_stack_layout_normal_split()
    test_docked_panel_stack_max_collapses_others()
    test_docked_panel_stack_max_then_restore_resets_all()
    test_docked_panel_stack_min_collapses_one()
    test_docked_panel_stack_min_on_max_sibling_clears_max()
    test_floating_panel_splitter_drag_resizes_upper_pane()
    test_floating_panel_top_border_does_not_self_resize()
    test_floating_panel_title_command_click_beats_splitter()
    test_floating_panel_minimize_bottom_keeps_one_row()
    test_floating_panel_minimize_top_keeps_one_row()
    print("chrome: 46 tests passed")
