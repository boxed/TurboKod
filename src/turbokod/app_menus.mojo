"""The application menu bar, shared by every frontend.

``Desktop.menu_bar`` holds the menu *data*; how it's shown depends on the
host (painted in-grid by the terminal frontend, mirrored as a native
NSMenu by the macOS app — see docs/native-menu.md). Building it here, in
one place, is what keeps the two surfaces from drifting apart.
"""

from std.collections.list import List

from .desktop import (
    Desktop,
    APP_QUIT_ACTION, APP_SETTINGS,
    DEBUG_ADD_WATCH, DEBUG_CONDITIONAL_BP, DEBUG_START_OR_CONTINUE,
    DEBUG_STEP_IN, DEBUG_STEP_OUT, DEBUG_STEP_OVER, DEBUG_STOP,
    DEBUG_TOGGLE_BREAKPOINT, DEBUG_TOGGLE_RAISED,
    DEBUG_FOCUS_PANE,
    EDITOR_COMPARE_CLIPBOARD, EDITOR_COPY, EDITOR_CUT, EDITOR_FILL,
    EDITOR_FIND, EDITOR_FIND_NEXT, EDITOR_FIND_PREV, EDITOR_FIND_SYMBOL,
    EDITOR_GOTO,
    EDITOR_GOTO_SYMBOL, EDITOR_LOOKUP_DOCS, EDITOR_NEW, EDITOR_OPEN,
    EDITOR_FORMAT_DOCUMENT, EDITOR_FORMAT_SELECTION,
    EDITOR_GOTO_DECL, EDITOR_GOTO_IMPL, EDITOR_GOTO_TYPE_DEF,
    EDITOR_NAV_BACK, EDITOR_NAV_FORWARD,
    EDITOR_OPEN_RECENT, EDITOR_PASTE, EDITOR_QUICK_OPEN, EDITOR_REDO,
    EDITOR_RENAME_SYMBOL,
    EDITOR_REPLACE, EDITOR_SAVE, EDITOR_SAVE_AS, EDITOR_SELECT_ALL,
    EDITOR_TOGGLE_BLAME,
    EDITOR_SORT_LINES, EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT, EDITOR_TOGGLE_COMPRESS_KWARGS,
    EDITOR_TOGGLE_GIT_CHANGES,
    EDITOR_TOGGLE_LINE_NUMBERS, EDITOR_TOGGLE_MINIMAP,
    EDITOR_TOGGLE_STICKY_SCROLL,
    EDITOR_TOGGLE_TAB_BAR, EDITOR_UNDO,
    FILE_TREE_FOCUS, FILE_TREE_REVEAL,
    GIT_HISTORY_FILE, GIT_HISTORY_SELECTION, GIT_LOCAL_CHANGES,
    GIT_OPEN_ALL_CHANGED, GIT_REVIEW,
    HELP_HOTKEYS,
    PROJECT_FIND, PROJECT_OPEN, PROJECT_REPLACE, PROJECT_TREE_ACTION,
    TARGET_RUN, TARGET_TEST, TERMINAL_CLAUDE, TERMINAL_NEW,
    WINDOW_CLOSE, WINDOW_CLOSE_ALL,
    WINDOW_ROTATE_NEXT, WINDOW_ROTATE_PREV,
    synth_key_action,
)
from .events import (
    KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_UP, MOD_ALT, MOD_CTRL, MOD_META,
    MOD_SHIFT,
)
from .menu import Menu, MenuItem


# Host action: open a new Desktop window (Desktop returns it unclaimed).
comptime NEW_WINDOW = String("app.new_window")
# Host action: toggle the native "Floating panels" feature for this window.
# The host owns the windowing (it creates/destroys the separate panel
# window) and then calls ``tk_desktop_set_panels_detached`` to update the
# Desktop flag that drives the View-menu checkmark. See docs/floating-panels.md.
comptime TOGGLE_FLOATING_PANELS = String("app.toggle_floating_panels")


def _mk_menu(var label: String, *items: Tuple[String, String]) -> Menu:
    var list = List[MenuItem]()
    for it in items:
        list.append(MenuItem(it[0], it[1]))
    return Menu(label^, list^)


def build_edit_items(has_extra_carets: Bool) -> List[MenuItem]:
    var e = List[MenuItem]()
    e.append(MenuItem(String("Undo"),  EDITOR_UNDO))
    e.append(MenuItem(String("Redo"),  EDITOR_REDO))
    e.append(MenuItem.separator())
    e.append(MenuItem(String("Cut"),   EDITOR_CUT))
    e.append(MenuItem(String("Copy"),  EDITOR_COPY))
    e.append(MenuItem(String("Paste"), EDITOR_PASTE))
    e.append(MenuItem(String("Select All"), EDITOR_SELECT_ALL))
    e.append(MenuItem(String("Compare selection with clipboard"), EDITOR_COMPARE_CLIPBOARD))
    if has_extra_carets:
        e.append(MenuItem(String("Fill..."), EDITOR_FILL))
    e.append(MenuItem.separator())
    e.append(MenuItem(String("Find..."),               EDITOR_FIND))
    e.append(MenuItem(String("Find Next"),             EDITOR_FIND_NEXT))
    e.append(MenuItem(String("Find Previous"),         EDITOR_FIND_PREV))
    e.append(MenuItem(String("Replace..."),            EDITOR_REPLACE))
    e.append(MenuItem(String("Find in project..."),    PROJECT_FIND))
    e.append(MenuItem(String("Replace in project..."), PROJECT_REPLACE))
    e.append(MenuItem(String("Go to Line..."),         EDITOR_GOTO))
    e.append(MenuItem(String("Go to Symbol..."),       EDITOR_GOTO_SYMBOL))
    e.append(MenuItem(String("Go to Type Definition"), EDITOR_GOTO_TYPE_DEF))
    e.append(MenuItem(String("Go to Implementation"),  EDITOR_GOTO_IMPL))
    e.append(MenuItem(String("Go to Declaration"),     EDITOR_GOTO_DECL))
    e.append(MenuItem(String("Rename Symbol..."),      EDITOR_RENAME_SYMBOL))
    e.append(MenuItem(String("Format Document"),       EDITOR_FORMAT_DOCUMENT))
    e.append(MenuItem(String("Format Selection"),      EDITOR_FORMAT_SELECTION))
    e.append(MenuItem(String("Look up in docs..."),    EDITOR_LOOKUP_DOCS))
    e.append(MenuItem(String("Toggle Comment"),        EDITOR_TOGGLE_COMMENT))
    e.append(MenuItem(String("Toggle Case"),           EDITOR_TOGGLE_CASE))
    e.append(MenuItem(String("Sort Lines"),            EDITOR_SORT_LINES))
    return e^


def build_menus(mut d: Desktop, native: Bool):
    """Populate ``d.menu_bar`` with the application menus. The single
    definition both frontends use — the terminal paints it in-grid, the
    macOS host mirrors it as an NSMenu — so a menu change shows up in both.
    ``native`` adds the items only a windowing host can act on (New
    window, Floating panels)."""
    var ham = List[MenuItem]()
    ham.append(MenuItem(String("Settings"), APP_SETTINGS))
    ham.append(MenuItem.separator())
    ham.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    d.menu_bar.add(Menu(String("≡"), ham^, is_system=True))
    d.menu_bar.add(_mk_menu(String("File"),
        (String("New"), EDITOR_NEW),
        (String("New terminal pane"), TERMINAL_NEW),
        (String("New Claude pane"), TERMINAL_CLAUDE),
        (String("Open..."), EDITOR_OPEN),
        (String("Open project..."), PROJECT_OPEN),
        (String("Quick open..."), EDITOR_QUICK_OPEN),
        (String("Open recent..."), EDITOR_OPEN_RECENT),
        (String("Close"), WINDOW_CLOSE),
        (String("Close all"), WINDOW_CLOSE_ALL),
        (String("Save"), EDITOR_SAVE),
        (String("Save as..."), EDITOR_SAVE_AS),
    ))
    if native:
        # After "New": the host opens another Desktop window.
        d.menu_bar.menus[len(d.menu_bar.menus) - 1].items.insert(
            1, MenuItem(String("New window"), NEW_WINDOW),
        )
    d.menu_bar.add(Menu(String("Edit"), build_edit_items(False)))
    var v = List[MenuItem]()
    v.append(MenuItem(String("Line Numbers"), EDITOR_TOGGLE_LINE_NUMBERS, checkable=True))
    v.append(MenuItem(String("Git Changes"), EDITOR_TOGGLE_GIT_CHANGES, checkable=True))
    v.append(MenuItem(String("Tab Bar"), EDITOR_TOGGLE_TAB_BAR, checkable=True))
    v.append(MenuItem(String("Minimap"), EDITOR_TOGGLE_MINIMAP, checkable=True))
    v.append(MenuItem(
        String("Sticky Scroll"), EDITOR_TOGGLE_STICKY_SCROLL, checkable=True,
    ))
    v.append(MenuItem(
        String("Compress Keyword Args"), EDITOR_TOGGLE_COMPRESS_KWARGS,
        checkable=True,
    ))
    v.append(MenuItem.separator())
    # Three-way cycle (hidden → right → left); the label is re-stamped
    # from the live state every paint by ``_apply_view_config``, so this
    # initial text only has to match the no-tree default.
    v.append(MenuItem(String("File tree: hidden"), PROJECT_TREE_ACTION))
    v.append(MenuItem(String("Show in file tree"), FILE_TREE_REVEAL))
    if native:
        # Float the tool panels (terminal / debug / test) into a separate
        # window — needs a host that owns windows.
        v.append(MenuItem(
            String("Floating panels"), TOGGLE_FLOATING_PANELS, checkable=True,
        ))
    d.menu_bar.add(Menu(String("View"), v^))
    # Navigation — surfaces the cursor / window / symbol navigation hotkeys.
    # Items backed by a real action (Go to Line, Navigate Back, …) dispatch
    # directly; the editor-movement chords (Word Left, Grow Selection, …) use
    # ``synth_key_action`` so clicking them re-injects the chord into the
    # focused editor. Shortcut text auto-populates from ``_hotkeys`` via
    # ``_refresh_shortcuts``. Every item here matches a registered hotkey, so
    # the Keyboard Shortcuts page and this menu can't drift apart.
    var nav = List[MenuItem]()
    nav.append(MenuItem(String("Go to Line..."),    EDITOR_GOTO))
    nav.append(MenuItem(String("Go to Symbol..."),  EDITOR_GOTO_SYMBOL))
    nav.append(MenuItem(String("Find Symbol..."),   EDITOR_FIND_SYMBOL))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Find Next"),        EDITOR_FIND_NEXT))
    nav.append(MenuItem(String("Find Previous"),    EDITOR_FIND_PREV))
    nav.append(MenuItem(String("Navigate Back"),    EDITOR_NAV_BACK))
    nav.append(MenuItem(String("Navigate Forward"), EDITOR_NAV_FORWARD))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Word Left"),
        synth_key_action(KEY_LEFT, MOD_ALT)))
    nav.append(MenuItem(String("Word Right"),
        synth_key_action(KEY_RIGHT, MOD_ALT)))
    nav.append(MenuItem(String("Line Start"),
        synth_key_action(KEY_LEFT, MOD_META)))
    nav.append(MenuItem(String("Line End"),
        synth_key_action(KEY_RIGHT, MOD_META)))
    nav.append(MenuItem(String("Grow Selection"),
        synth_key_action(KEY_UP, MOD_META)))
    nav.append(MenuItem(String("Shrink Selection"),
        synth_key_action(KEY_DOWN, MOD_META)))
    nav.append(MenuItem(String("Add Caret Above"),
        synth_key_action(KEY_UP, MOD_CTRL | MOD_ALT)))
    nav.append(MenuItem(String("Add Caret Below"),
        synth_key_action(KEY_DOWN, MOD_CTRL | MOD_ALT)))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Previous Change"),
        synth_key_action(KEY_UP, MOD_CTRL | MOD_SHIFT)))
    nav.append(MenuItem(String("Next Change"),
        synth_key_action(KEY_DOWN, MOD_CTRL | MOD_SHIFT)))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Previous Window"), WINDOW_ROTATE_PREV))
    nav.append(MenuItem(String("Next Window"),     WINDOW_ROTATE_NEXT))
    nav.append(MenuItem(String("Focus File Tree"), FILE_TREE_FOCUS))
    nav.append(MenuItem(String("Focus Debug Pane"), DEBUG_FOCUS_PANE))
    d.menu_bar.add(Menu(String("Navigation"), nav^))
    d.menu_bar.add(_mk_menu(String("Git"),
        (String("Toggle Blame"), EDITOR_TOGGLE_BLAME),
        (String("Show diff viewer"), GIT_LOCAL_CHANGES),
        (String("Review changes…"), GIT_REVIEW),
        (String("Show History for Selection"), GIT_HISTORY_SELECTION),
        (String("Show History for File…"), GIT_HISTORY_FILE),
        (String("Open all with changes"), GIT_OPEN_ALL_CHANGED),
    ))
    var dbg = List[MenuItem]()
    dbg.append(MenuItem(String("Run"), TARGET_RUN))
    dbg.append(MenuItem(String("Test"), TARGET_TEST))
    dbg.append(MenuItem.separator())
    dbg.append(MenuItem(String("Start / Continue"), DEBUG_START_OR_CONTINUE))
    dbg.append(MenuItem(String("Stop"), DEBUG_STOP))
    dbg.append(MenuItem(String("Toggle Breakpoint"), DEBUG_TOGGLE_BREAKPOINT))
    dbg.append(MenuItem(String("Conditional Breakpoint..."), DEBUG_CONDITIONAL_BP))
    dbg.append(MenuItem(String("Step Over"), DEBUG_STEP_OVER))
    dbg.append(MenuItem(String("Step Into"), DEBUG_STEP_IN))
    dbg.append(MenuItem(String("Step Out"), DEBUG_STEP_OUT))
    dbg.append(MenuItem(String("Add Watch..."), DEBUG_ADD_WATCH))
    dbg.append(MenuItem(String("Toggle Break on Raised"), DEBUG_TOGGLE_RAISED))
    d.menu_bar.add(Menu(String("Debug"), dbg^))
    # Help — rank 100, so it lands rightmost (see ``_menu_rank``). The
    # native frontend turns a menu titled "Help" into the standard macOS
    # Help menu (with the built-in menu-search field); see ``installMenu``
    # in TurboKod.swift. "Keyboard Shortcuts" opens the read-only
    # reference covering every binding, including the editor-level chords
    # (Cmd+Up/Down, …) that have no menu item of their own.
    d.menu_bar.add(_mk_menu(String("Help"),
        (String("Keyboard Shortcuts"), HELP_HOTKEYS),
    ))


def refresh_menu_visibility(mut d: Desktop):
    """Per-tick menu upkeep shared by both frontends: show Edit / View /
    Git only where they apply, keep the Floating-panels checkmark in step,
    and add or drop Edit ▸ Fill... as the focused editor gains or loses
    extra carets."""
    # While a session restore is pending, the editor windows don't exist
    # yet — they're created in the first ``paint``/``_restore_session``,
    # which runs *after* this tick. Computing visibility now would see
    # ``focused_is_editor() == False`` and hide the Edit menu for one
    # frame, then the next tick re-shows it: a visible menu-bar flicker
    # right after the project window appears. Leave the menu in its built
    # default (Edit visible) until restore has run; the next tick computes
    # real visibility against the now-restored editor.
    if d._pending_restore:
        return
    var is_editor = d.windows.focused_is_editor()
    d.menu_bar.set_visible_by_label(String("Edit"), is_editor)
    # View stays reachable whenever a project is open (even with no
    # editor focused) — the file-tree cycle lives there now.
    var view_visible = is_editor
    if not view_visible and d.project:
        view_visible = True
    d.menu_bar.set_visible_by_label(String("View"), view_visible)
    # Keep the Floating-panels checkmark in lockstep with the live state.
    # The Desktop owns the flag, the host owns the window; this is the one
    # per-tick place both are reachable for the native menu snapshot.
    d.menu_bar.set_item_checked(TOGGLE_FLOATING_PANELS, d.panels_detached)
    var git_visible = is_editor
    if not git_visible and d.project:
        git_visible = True
    d.menu_bar.set_visible_by_label(String("Git"), git_visible)
    if not d.menu_bar.is_open():
        var has_extras = d.focused_editor_has_extra_carets()
        for i in range(len(d.menu_bar.menus)):
            if d.menu_bar.menus[i].label == String("Edit"):
                # Only rebuild when the Fill item's presence actually
                # changes. Swapping in fresh items every tick would drop
                # the shortcut text ``_refresh_shortcuts`` stamped on the
                # previous pass — and that stamper short-circuits when the
                # action set is unchanged, so it never re-applies them.
                var has_fill = False
                for it in range(len(d.menu_bar.menus[i].items)):
                    if d.menu_bar.menus[i].items[it].action == EDITOR_FILL:
                        has_fill = True
                        break
                if has_fill != has_extras:
                    d.menu_bar.menus[i].items = build_edit_items(has_extras)
                break
