"""The full turbokod Desktop in native macOS windows — with multiple windows.

Each window hosts its own independent ``Desktop`` (its own windows, tabs,
project, editors). The File menu's **New window** item — and Cmd+N — open a
fresh Desktop in a new native window. Closing a window (its close button, or
the File ▸ Quit / Ctrl+Q action) closes just that Desktop; the program exits
when the last window is gone.

Events from the shared event loop are tagged with the window they came from
and routed to that window's Desktop, so typing/clicking in one window never
touches another.

Run with::

    ./run_native.sh examples/desktop_native.mojo
    ./run_native.sh examples/desktop_native.mojo path/to/file.txt
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.memory import ArcPointer
from std.sys import argv

from turbokod.file_io import read_file, write_file, join_path
from turbokod.posix import getenv_value

from turbokod import (
    APP_QUIT_ACTION, APP_SETTINGS,
    Canvas,
    DEBUG_ADD_WATCH, DEBUG_CONDITIONAL_BP,
    DEBUG_START_OR_CONTINUE,
    DEBUG_STEP_IN, DEBUG_STEP_OUT, DEBUG_STEP_OVER, DEBUG_STOP,
    DEBUG_TOGGLE_BREAKPOINT, DEBUG_TOGGLE_RAISED,
    Desktop, Event, FileDialog, Menu, MenuItem, Rect,
    EDITOR_COMPARE_CLIPBOARD,
    EDITOR_COPY, EDITOR_CUT, EDITOR_FILL, EDITOR_FIND, EDITOR_FIND_NEXT,
    EDITOR_FIND_PREV, EDITOR_GOTO,
    EDITOR_GOTO_SYMBOL, EDITOR_LOOKUP_DOCS,
    EDITOR_NEW, EDITOR_OPEN, EDITOR_OPEN_RECENT,
    EDITOR_PASTE,
    EDITOR_QUICK_OPEN, EDITOR_REDO, EDITOR_REPLACE, EDITOR_SAVE,
    EDITOR_SAVE_AS, EDITOR_TOGGLE_BLAME, EDITOR_TOGGLE_CASE,
    EDITOR_TOGGLE_COMMENT,
    EDITOR_TOGGLE_GIT_CHANGES,
    EDITOR_TOGGLE_LINE_NUMBERS,
    EDITOR_TOGGLE_MINIMAP,
    EDITOR_TOGGLE_SOFT_WRAP,
    EDITOR_TOGGLE_TAB_BAR,
    EDITOR_UNDO,
    EVENT_KEY, EVENT_MOUSE, EVENT_OPEN_PATH, EVENT_QUIT, EVENT_RESIZE,
    GIT_LOCAL_CHANGES, GIT_OPEN_ALL_CHANGED,
    MOD_META,
    PROJECT_FIND, PROJECT_OPEN, PROJECT_REPLACE,
    TARGET_RUN, TERMINAL_NEW,
    WINDOW_CLOSE, WINDOW_CLOSE_ALL,
    default_attr, stat_file,
)
from turbokod.native_window import NativeApp, NativeWindow


# Custom host action: open a new Desktop window. The Desktop doesn't claim
# it, so handle_event returns it to us (see Desktop.handle_event docstring).
comptime NEW_WINDOW = String("app.new_window")


def _mk_menu(var label: String, *items: Tuple[String, String]) -> Menu:
    var list = List[MenuItem]()
    for it in items:
        list.append(MenuItem(it[0], it[1]))
    return Menu(label^, list^)


def _build_edit_items(has_extra_carets: Bool) -> List[MenuItem]:
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Undo"),  EDITOR_UNDO))
    edit_items.append(MenuItem(String("Redo"),  EDITOR_REDO))
    edit_items.append(MenuItem.separator())
    edit_items.append(MenuItem(String("Cut"),   EDITOR_CUT))
    edit_items.append(MenuItem(String("Copy"),  EDITOR_COPY))
    edit_items.append(MenuItem(String("Paste"), EDITOR_PASTE))
    edit_items.append(MenuItem(
        String("Compare selection with clipboard"), EDITOR_COMPARE_CLIPBOARD))
    if has_extra_carets:
        edit_items.append(MenuItem(String("Fill..."), EDITOR_FILL))
    edit_items.append(MenuItem.separator())
    edit_items.append(MenuItem(String("Find..."),               EDITOR_FIND))
    edit_items.append(MenuItem(String("Find Next"),             EDITOR_FIND_NEXT))
    edit_items.append(MenuItem(String("Find Previous"),         EDITOR_FIND_PREV))
    edit_items.append(MenuItem(String("Replace..."),            EDITOR_REPLACE))
    edit_items.append(MenuItem(String("Find in project..."),    PROJECT_FIND))
    edit_items.append(MenuItem(String("Replace in project..."), PROJECT_REPLACE))
    edit_items.append(MenuItem(String("Go to Line..."),         EDITOR_GOTO))
    edit_items.append(MenuItem(String("Go to Symbol..."),       EDITOR_GOTO_SYMBOL))
    edit_items.append(MenuItem(String("Look up in docs..."),    EDITOR_LOOKUP_DOCS))
    edit_items.append(MenuItem(String("Toggle Comment"),        EDITOR_TOGGLE_COMMENT))
    edit_items.append(MenuItem(String("Toggle Case"),           EDITOR_TOGGLE_CASE))
    return edit_items^


def _refresh_edit_menu_items(mut desktop: Desktop):
    if desktop.menu_bar.is_open():
        return
    var has_extras = desktop.focused_editor_has_extra_carets()
    for i in range(len(desktop.menu_bar.menus)):
        if desktop.menu_bar.menus[i].label == String("Edit"):
            desktop.menu_bar.menus[i].items = _build_edit_items(has_extras)
            return


def _build_menus(mut desktop: Desktop):
    var hamburger_items = List[MenuItem]()
    hamburger_items.append(MenuItem(String("Settings"), APP_SETTINGS))
    hamburger_items.append(MenuItem.separator())
    hamburger_items.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    desktop.menu_bar.add(Menu(String("≡"), hamburger_items^, is_system=True))
    desktop.menu_bar.add(_mk_menu(String("File"),
        (String("New"), EDITOR_NEW),
        (String("New window"), NEW_WINDOW),
        (String("New terminal pane"), TERMINAL_NEW),
        (String("Open..."), EDITOR_OPEN),
        (String("Open project..."), PROJECT_OPEN),
        (String("Quick open..."), EDITOR_QUICK_OPEN),
        (String("Open recent..."), EDITOR_OPEN_RECENT),
        (String("Close"), WINDOW_CLOSE),
        (String("Close all"), WINDOW_CLOSE_ALL),
        (String("Save"), EDITOR_SAVE),
        (String("Save as..."), EDITOR_SAVE_AS),
    ))
    desktop.menu_bar.add(Menu(String("Edit"), _build_edit_items(False)))
    var view_items = List[MenuItem]()
    view_items.append(MenuItem(String("Line Numbers"), EDITOR_TOGGLE_LINE_NUMBERS, checkable=True))
    view_items.append(MenuItem(String("Soft Wrap"), EDITOR_TOGGLE_SOFT_WRAP, checkable=True))
    view_items.append(MenuItem(String("Git Changes"), EDITOR_TOGGLE_GIT_CHANGES, checkable=True))
    view_items.append(MenuItem(String("Tab Bar"), EDITOR_TOGGLE_TAB_BAR, checkable=True))
    view_items.append(MenuItem(String("Minimap"), EDITOR_TOGGLE_MINIMAP, checkable=True))
    desktop.menu_bar.add(Menu(String("View"), view_items^))
    desktop.menu_bar.add(_mk_menu(String("Git"),
        (String("Toggle Blame"),       EDITOR_TOGGLE_BLAME),
        (String("Show diff viewer"), GIT_LOCAL_CHANGES),
        (String("Open all with changes"), GIT_OPEN_ALL_CHANGED),
    ))
    var debug_items = List[MenuItem]()
    debug_items.append(MenuItem(String("Run"), TARGET_RUN))
    debug_items.append(MenuItem.separator())
    debug_items.append(MenuItem(String("Start / Continue"),       DEBUG_START_OR_CONTINUE))
    debug_items.append(MenuItem(String("Stop"),                   DEBUG_STOP))
    debug_items.append(MenuItem(String("Toggle Breakpoint"),      DEBUG_TOGGLE_BREAKPOINT))
    debug_items.append(MenuItem(String("Conditional Breakpoint..."), DEBUG_CONDITIONAL_BP))
    debug_items.append(MenuItem(String("Step Over"),              DEBUG_STEP_OVER))
    debug_items.append(MenuItem(String("Step Into"),              DEBUG_STEP_IN))
    debug_items.append(MenuItem(String("Step Out"),               DEBUG_STEP_OUT))
    debug_items.append(MenuItem(String("Add Watch..."),           DEBUG_ADD_WATCH))
    debug_items.append(MenuItem(String("Toggle Break on Raised"), DEBUG_TOGGLE_RAISED))
    desktop.menu_bar.add(Menu(String("Debug"), debug_items^))


def _make_desktop() raises -> Desktop:
    var d = Desktop()
    d.load_config_from_disk()
    _build_menus(d)
    return d^


struct Pane(Copyable, Movable):
    """One native window + the Desktop it hosts + its file dialog. Panes live
    in a ``List``, which requires Copyable elements — ``Desktop`` and
    ``FileDialog`` are move-only, so they're boxed in ``ArcPointer`` (a
    Copyable heap box). The back canvas is rebuilt fresh each frame, so it
    isn't stored. Events route to a pane by matching ``win.id``."""
    var win: NativeWindow
    var desktop: ArcPointer[Desktop]
    var dialog: ArcPointer[FileDialog]
    var alive: Bool

    def __init__(out self, var win: NativeWindow, var desktop: Desktop):
        self.win = win^
        self.desktop = ArcPointer(desktop^)
        self.dialog = ArcPointer(FileDialog())
        self.alive = True


def _shutdown_desktop(mut d: Desktop):
    for i in range(len(d.lsp_managers)):
        d.lsp_managers[i].shutdown()
    d.dap.shutdown()
    d.run_session.terminate()


def _paint_pane(mut pane: Pane, mut error_log: List[String]):
    pane.win.sync_size()
    var screen = Rect(0, 0, pane.win.width, pane.win.height)
    ref desktop = pane.desktop[]
    try:
        desktop.process_external_changes(screen)
    except e:
        error_log.append(String("reload: ") + String(e))
    desktop.menu_bar.set_visible_by_label(
        String("Edit"), desktop.windows.focused_is_editor())
    desktop.menu_bar.set_visible_by_label(
        String("View"), desktop.windows.focused_is_editor())
    _refresh_edit_menu_items(desktop)
    var git_visible = desktop.windows.focused_is_editor()
    if not git_visible and desktop.project:
        git_visible = True
    desktop.menu_bar.set_visible_by_label(String("Git"), git_visible)

    var tree_open = desktop.file_tree.consume_open()
    if tree_open:
        var p = tree_open.value()
        try:
            desktop.open_file(p, screen)
        except e:
            error_log.append(String("open ") + p + String(": ") + String(e))

    var back = Canvas(pane.win.width, pane.win.height)
    back.clear(default_attr())
    desktop.paint(back, screen)
    pane.dialog[].paint(back, screen)
    pane.win.present(back)

    desktop.lsp_tick(screen)
    desktop.dap_tick(screen)
    desktop.terminal_tick()
    desktop.save_actions_tick()


def _handle_pane(mut pane: Pane, ev: Event, mut error_log: List[String]) -> Bool:
    """Route one event to this pane. Returns True if a new window should be
    spawned (Cmd+N or File ▸ New window)."""
    var screen = Rect(0, 0, pane.win.width, pane.win.height)
    ref desktop = pane.desktop[]
    ref dialog = pane.dialog[]

    if ev.kind == EVENT_QUIT:
        _shutdown_desktop(desktop)
        pane.win.close()
        pane.alive = False
        return False
    if ev.kind == EVENT_RESIZE:
        return False  # back canvas re-syncs next frame
    # (Cmd+N / File ▸ New Window is handled in the main drain loop, above
    # per-pane routing, so a win-0 menu request isn't dropped here.)

    if ev.kind == EVENT_MOUSE and not dialog.active:
        pane.win.set_cursor(desktop.pointer_shape_at(ev.pos, screen))

    # Modal: file dialog eats events while open.
    if dialog.active:
        if ev.kind == EVENT_KEY:
            _ = dialog.handle_key(ev)
        else:
            _ = dialog.handle_mouse(ev, screen)
        if dialog.submitted:
            var path = dialog.selected_path
            var picks_project = dialog.dirs_only
            dialog.close()
            if picks_project:
                if desktop.project:
                    desktop.close_project()
                desktop.open_project(path)
            else:
                try:
                    desktop.open_file(path, screen)
                except:
                    pass
        return False

    var maybe_action = desktop.handle_event(ev, screen)
    if maybe_action:
        var action = maybe_action.value()
        if action == NEW_WINDOW:
            return True
        elif action == APP_QUIT_ACTION:
            _shutdown_desktop(desktop)
            pane.win.close()
            pane.alive = False
        elif action == EDITOR_OPEN or action == EDITOR_QUICK_OPEN:
            var start = desktop.project.value() if desktop.project else String(".")
            dialog.open(start)
            dialog.set_project(desktop.project)
        elif action == PROJECT_OPEN:
            var start = desktop.project.value() if desktop.project else String(".")
            dialog.open_directory(start)
            dialog.set_project(desktop.project)
    return False


def _spawn_pane(mut app: NativeApp, mut panes: List[Pane], n: Int) raises:
    var win = app.open_window()
    win.set_title(String("TurboKod — window ") + String(n))
    var d = _make_desktop()
    panes.append(Pane(win^, d^))
    print("spawned window", n, "— open windows:", app.window_count())


# --- App-level session: which windows were open + each window's project ----
#
# Distinct from the per-project session (which restores a project's *editor*
# windows under <project>/.turbokod/...). This remembers, across launches,
# the set of OS windows and the project each had, so reopening the app brings
# the windows back; opening each project then triggers its own editor
# restore. Stored one project path per line at ~/.turbokod/native_session.txt
# (scratch windows with no project aren't persisted — they have nothing to
# restore).

comptime _NATIVE_SESSION_FILE = String("native_session.txt")


def _turbokod_home() -> String:
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        home = String(".")
    return join_path(home, String(".turbokod"))


def _native_session_path() -> String:
    return join_path(_turbokod_home(), _NATIVE_SESSION_FILE)


def _ensure_home_dir():
    var c = _turbokod_home() + String("\0")
    _ = external_call["mkdir", Int32](c.unsafe_ptr(), Int32(0o755))


def _load_native_session() -> List[String]:
    """Project paths to restore, one per saved window (non-empty lines)."""
    var out = List[String]()
    var path = _native_session_path()
    if not stat_file(path).ok:
        return out^
    try:
        var content = read_file(path)
        var b = content.as_bytes()
        var start = 0
        for i in range(len(b)):
            if b[i] == 0x0A:  # newline
                if i > start:
                    out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
                start = i + 1
        if start < len(b):
            out.append(String(StringSlice(unsafe_from_utf8=b[start:len(b)])))
    except:
        pass
    return out^


def _encode_native_session(projects: List[String]) -> String:
    var s = String("")
    for i in range(len(projects)):
        s += projects[i] + String("\n")
    return s


def _save_native_session_if_changed(projects: List[String], mut last: String):
    var encoded = _encode_native_session(projects)
    if encoded == last:
        return
    last = encoded
    _ensure_home_dir()
    _ = write_file(_native_session_path(), encoded)


def main() raises:
    var app = NativeApp()
    var error_log = List[String]()
    app.start()
    var panes = List[Pane]()
    var window_count = 0
    var last_session = String("")
    # Persist the window/project session except for a pure one-off file open
    # (so `turbokod notes.txt` doesn't wipe your saved multi-window session).
    var persist_session = True
    try:
        var args = argv()
        if len(args) > 1:
            # Explicit CLI args: one window, open the given files/projects.
            window_count += 1
            _spawn_pane(app, panes, window_count)
            var first_screen = Rect(0, 0, panes[0].win.width, panes[0].win.height)
            var opened_project = False
            for i in range(1, len(args)):
                var path = String(args[i])
                var info = stat_file(path)
                if info.ok and info.is_dir():
                    panes[0].desktop[].open_project(path)
                    opened_project = True
                    continue
                try:
                    panes[0].desktop[].open_file(path, first_screen)
                except e:
                    error_log.append(String("open ") + path + String(": ") + String(e))
            persist_session = opened_project
        else:
            # No args: restore the windows + projects from the last session.
            var saved = _load_native_session()
            if len(saved) == 0:
                window_count += 1
                _spawn_pane(app, panes, window_count)
            else:
                # Seed last_session so the first frame doesn't immediately
                # rewrite the identical file.
                last_session = _encode_native_session(saved)
                for i in range(len(saved)):
                    window_count += 1
                    _spawn_pane(app, panes, window_count)
                    var idx = len(panes) - 1
                    panes[idx].desktop[].open_project(saved[i])
                print("restored", len(saved), "window(s) from last session")

        while True:
            var alive = 0
            for i in range(len(panes)):
                if panes[i].alive:
                    alive += 1
            if alive == 0:
                break

            for i in range(len(panes)):
                if panes[i].alive:
                    _paint_pane(panes[i], error_log)

            app.pump(50)
            var spawn = 0
            var maybe = app.next_event()
            while maybe:
                var we = maybe.value()
                # New-window request: from the native File ▸ New Window menu
                # (which arrives as a win-0 synthesized Cmd+N) or ⌘N in any
                # window. Handled here, above per-pane routing, so it fires
                # regardless of which window (if any) it's tagged to.
                if we.ev.kind == EVENT_KEY and Int(we.ev.key) == ord("n") \
                        and (we.ev.mods & MOD_META) != 0:
                    spawn += 1
                    maybe = app.next_event()
                    continue
                for i in range(len(panes)):
                    if panes[i].alive and we.win == panes[i].win.id:
                        if _handle_pane(panes[i], we.ev, error_log):
                            spawn += 1
                        break
                maybe = app.next_event()

            for _ in range(spawn):
                window_count += 1
                _spawn_pane(app, panes, window_count)

            # Persist the app-level session (one project path per open
            # window) whenever it changes, so a relaunch restores it.
            if persist_session:
                var projects = List[String]()
                for i in range(len(panes)):
                    if panes[i].alive and panes[i].desktop[].project:
                        projects.append(panes[i].desktop[].project.value())
                _save_native_session_if_changed(projects, last_session)

        for i in range(len(panes)):
            _shutdown_desktop(panes[i].desktop[])
        app.stop()
        for i in range(len(error_log)):
            print(error_log[i])
        error_log = List[String]()
    finally:
        app.stop()
        for i in range(len(error_log)):
            print(error_log[i])
