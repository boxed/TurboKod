"""Desktop: combines menu bar, window manager, status bar, hatched background,
modal prompt, and a project file tree — wired together so the host app only
has to deal with app-policy actions (quit / open file / focus a window).

Idiomatic usage::

    while app.running:
        desktop.paint(app.back, app.screen())
        var ev = app.next_event(50)
        if ev:
            var action = desktop.handle_event(ev.value(), app.screen())
            if action:
                ... dispatch app-specific actions (quit, file:open, ...)

The Desktop intercepts the standard editor / project actions itself — see the
``EDITOR_*`` / ``PROJECT_*`` action constants below. The app menu just lists
items with those action strings and the dispatch is automatic. Anything the
Desktop doesn't recognize is returned for the caller to handle.

Project state (the directory containing the most recently opened file's
nearest ``.git`` ancestor) lives here too. The first call to
``detect_project_from(path)`` after startup wins; subsequent file opens
don't re-detect. Closing the project (via the right-aligned project menu)
clears the state and makes the next file open eligible to set it again.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .colors import (
    Attr, BLACK, BLUE, LIGHT_GRAY, LIGHT_RED, RED, YELLOW,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6,
    KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    KEY_HOME, KEY_INSERT, KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_CTRL, MOD_NONE, MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .file_io import basename, find_git_project, join_path, stat_file
from .posix import realpath
from .file_tree import FileTree
from .geometry import Rect
from .highlight import DefinitionRequest, extension_of
from .language_config import (
    LanguageSpec, built_in_servers, find_language_for_extension,
)
from .lsp_dispatch import DefinitionResolved, LspManager
from .dap_dispatch import DapManager, DapStackFrame, DapVariable
from .debug_pane import DebugPane, PANE_ROW_WATCH
from .debugger_config import (
    DebuggerSpec, built_in_debuggers, find_debugger_for_language,
)
from .menu import Menu, MenuBar, MenuItem
from .posix import monotonic_ms, which
from .project import replace_in_project
from .project_find import ProjectFind
from .prompt import Prompt
from .quick_open import QuickOpen
from .save_as_dialog import SaveAsDialog
from .status import StatusBar
from .symbol_pick import SymbolPick
from .window import MIN_WIN_H, MIN_WIN_W, Window, WindowManager


# --- Public action strings --------------------------------------------------
# The Desktop intercepts these; menu items wired to them work without any
# additional code on the application side.

comptime EDITOR_NEW           = String("file:new")
comptime EDITOR_SAVE          = String("file:save")
comptime EDITOR_SAVE_AS       = String("file:save_as")
comptime EDITOR_QUICK_OPEN    = String("file:quick_open")
comptime EDITOR_FIND          = String("edit:find")
comptime EDITOR_REPLACE       = String("edit:replace")
comptime EDITOR_GOTO          = String("edit:goto")
comptime EDITOR_GOTO_SYMBOL   = String("edit:goto_symbol")
comptime EDITOR_TOGGLE_COMMENT = String("edit:comment")
comptime EDITOR_TOGGLE_CASE   = String("edit:case")
comptime EDITOR_CUT           = String("edit:cut")
comptime EDITOR_COPY          = String("edit:copy")
comptime EDITOR_PASTE         = String("edit:paste")
comptime EDITOR_UNDO          = String("edit:undo")
comptime EDITOR_REDO          = String("edit:redo")
comptime PROJECT_FIND         = String("edit:project_find")
comptime PROJECT_REPLACE      = String("edit:project_replace")
comptime PROJECT_CLOSE_ACTION = String("project:close")
comptime PROJECT_TREE_ACTION  = String("project:tree:toggle")
# Debugger actions. ``DEBUG_START_OR_CONTINUE`` is a single F5-style
# binding: starts the session if none is active, continues if stopped.
comptime DEBUG_START_OR_CONTINUE = String("debug:start_or_continue")
comptime DEBUG_TOGGLE_BREAKPOINT = String("debug:toggle_bp")
comptime DEBUG_CONDITIONAL_BP    = String("debug:conditional_bp")
comptime DEBUG_STEP_OVER         = String("debug:step_over")
comptime DEBUG_STEP_IN           = String("debug:step_in")
comptime DEBUG_STEP_OUT          = String("debug:step_out")
comptime DEBUG_STOP              = String("debug:stop")
comptime DEBUG_ADD_WATCH         = String("debug:add_watch")
comptime DEBUG_TOGGLE_RAISED     = String("debug:toggle_raised_exceptions")
comptime DEBUG_FOCUS_PANE        = String("debug:focus_pane")
comptime FILE_TREE_FOCUS         = String("file_tree:focus")
# Dynamic Window menu actions. Focus actions encode the index inline so the
# items can be rebuilt every frame without any separate lookup table.
comptime WINDOW_FOCUS_PREFIX  = String("window:focus:")
comptime WINDOW_MAXIMIZE_ALL  = String("window:maximize_all")
comptime WINDOW_RESTORE_ALL   = String("window:restore_all")
comptime WINDOW_CLOSE         = String("window:close")
comptime _WINDOW_MENU_LABEL   = String("Window")

# When ESC fires at the top level (no menu open, no prompt active), the
# Desktop returns this so the app can decide whether to quit, ignore, etc.
comptime APP_QUIT_ACTION      = String("quit")

comptime _SHOW_TREE_LABEL = String("Show file tree")
comptime _HIDE_TREE_LABEL = String("Hide file tree")

# Internal pending-action values for two-step prompts (find → replace).
comptime _PA_REPLACE_FIND        = String("__pa_replace_find")
comptime _PA_REPLACE_DO          = String("__pa_replace_do")
comptime _PA_PROJECT_REPLACE_FIND = String("__pa_project_replace_find")
comptime _PA_PROJECT_REPLACE_DO  = String("__pa_project_replace_do")
comptime _PA_BP_CONDITION        = String("__pa_bp_condition")
comptime _PA_ADD_WATCH           = String("__pa_add_watch")


fn ctrl_key(letter: String) -> UInt32:
    """Return the control-character codepoint for ``Ctrl+letter``.

    Most terminals report ``Ctrl+letter`` as a single control byte (e.g.,
    ``Ctrl+Q`` → ``0x11``) rather than the printable letter with the
    ``MOD_CTRL`` flag. This helper does the conversion so hotkey
    registrations read naturally: ``ctrl_key("q")`` → ``0x11``.
    """
    var b = letter.as_bytes()
    if len(b) == 0:
        return UInt32(0)
    var c = Int(b[0])
    if 0x41 <= c and c <= 0x5A:
        return UInt32(c - 0x40)
    if 0x61 <= c and c <= 0x7A:
        return UInt32(c - 0x60)
    return UInt32(0)


@fieldwise_init
struct Hotkey(ImplicitlyCopyable, Movable):
    """Binding from a (key, modifier) pair to an action string.

    Hotkeys are matched on ``event.key == key and event.mods == mods``;
    the action is then sent through ``Desktop.dispatch_action``.
    """
    var key: UInt32
    var mods: UInt8
    var action: String


fn format_hotkey(key: UInt32, mods: UInt8) -> String:
    """Render a ``(key, mods)`` pair as a human-readable label.

    Used for the right-aligned shortcut text on menu items. The
    control-character form (``mods == MOD_NONE`` and ``0x01..0x1A``) is
    rendered as ``Ctrl+<letter>``, which is what most terminals send for
    the bare ``Ctrl+letter`` combination — the shortcut shown to the user
    matches what they have to press, even though the underlying event
    looks superficially un-modified.
    """
    var k = Int(key)
    if mods == MOD_NONE and 0x01 <= k and k <= 0x1A:
        return String("Ctrl+") + chr(k + 0x40)
    var prefix = String("")
    if (mods & MOD_CTRL) != 0:
        prefix = prefix + String("Ctrl+")
    if (mods & MOD_ALT) != 0:
        prefix = prefix + String("Alt+")
    if (mods & MOD_SHIFT) != 0:
        prefix = prefix + String("Shift+")
    if 0x21 <= k and k <= 0x7E:
        var c = k
        if 0x61 <= c and c <= 0x7A:
            c = c - 0x20  # display uppercase for letters
        return prefix + chr(c)
    if k == Int(KEY_F1):  return prefix + String("F1")
    if k == Int(KEY_F2):  return prefix + String("F2")
    if k == Int(KEY_F3):  return prefix + String("F3")
    if k == Int(KEY_F4):  return prefix + String("F4")
    if k == Int(KEY_F5):  return prefix + String("F5")
    if k == Int(KEY_F6):  return prefix + String("F6")
    if k == Int(KEY_F7):  return prefix + String("F7")
    if k == Int(KEY_F8):  return prefix + String("F8")
    if k == Int(KEY_F9):  return prefix + String("F9")
    if k == Int(KEY_F10): return prefix + String("F10")
    if k == Int(KEY_F11): return prefix + String("F11")
    if k == Int(KEY_F12): return prefix + String("F12")
    if k == Int(KEY_UP):       return prefix + String("Up")
    if k == Int(KEY_DOWN):     return prefix + String("Down")
    if k == Int(KEY_LEFT):     return prefix + String("Left")
    if k == Int(KEY_RIGHT):    return prefix + String("Right")
    if k == Int(KEY_HOME):     return prefix + String("Home")
    if k == Int(KEY_END):      return prefix + String("End")
    if k == Int(KEY_PAGEUP):   return prefix + String("PgUp")
    if k == Int(KEY_PAGEDOWN): return prefix + String("PgDn")
    if k == Int(KEY_TAB):       return prefix + String("Tab")
    if k == Int(KEY_ENTER):     return prefix + String("Enter")
    if k == Int(KEY_BACKSPACE): return prefix + String("BkSp")
    if k == Int(KEY_DELETE):    return prefix + String("Del")
    if k == Int(KEY_INSERT):    return prefix + String("Ins")
    if k == Int(KEY_ESC):       return prefix + String("Esc")
    if k == Int(KEY_SPACE):     return prefix + String("Space")
    return prefix + String("?")


struct Desktop(Movable):
    var menu_bar: MenuBar
    var windows: WindowManager
    var status_bar: StatusBar
    var file_tree: FileTree
    var prompt: Prompt
    var quick_open: QuickOpen
    var save_as_dialog: SaveAsDialog
    var symbol_pick: SymbolPick
    var project_find: ProjectFind
    var bg_pattern: String
    var bg_attr: Attr
    var project: Optional[String]
    var _project_menu_idx: Int       # index into menu_bar.menus, or -1
    var _window_menu_idx: Int        # framework-managed Window menu, or -1
    var _pending_action: String      # what to do on next prompt submit
    var _pending_arg: String         # accumulator for two-step prompts
    var _open_count: Int             # cascade counter for Desktop.open_file
    var _untitled_count: Int         # bumped per ``new_file`` for unique titles
    var _hotkeys: List[Hotkey]       # global key bindings, scanned in order
    var _esc_armed: Bool             # next keystroke is Alt+<letter> (mnemonic)
    # Spawned LSP managers, one per language id, kept in parallel
    # arrays so we can index either by language id or insertion order.
    # Populated lazily by ``_ensure_lsp_for_extension`` — no LSP cost
    # for languages the user never touches. ``lsp_specs`` is the
    # registry the host can extend (today: built-in catalog only); the
    # mapping from extension → spec is independent of which binary we
    # actually end up spawning, so adding a new IDE-bundled server is
    # just a registry edit.
    var lsp_specs: List[LanguageSpec]
    var lsp_managers: List[LspManager]
    var lsp_languages: List[String]
    # Debugger state. One ``DapManager`` per Desktop (single concurrent
    # session) — multi-session debugging would need a list keyed by
    # something (language? session id?), and we don't have a use case
    # for that yet. ``dap_specs`` is the registry the host can read /
    # extend; selection happens in ``dispatch_action`` when the user
    # hits F5 or the Debug menu item.
    var dap: DapManager
    var dap_specs: List[DebuggerSpec]
    var debug_pane: DebugPane
    # Latched current-execution location. Painted as ``▶`` in the gutter
    # of whichever editor has a matching ``file_path``. Cleared on
    # ``continued`` / ``terminated`` events.
    var _dap_exec_path: String
    var _dap_exec_line: Int
    # Frame chosen as "current" for variables fetch — top of stack until
    # the user clicks elsewhere. Stored so the scope/variables responses
    # know which frame they belong to even after the pane has been
    # repainted with a different selection.
    var _dap_current_frame_id: Int
    # Label of the scope whose variables are in flight. Used to render
    # ``Locals:`` / ``Globals:`` in the pane when the response lands.
    var _dap_pending_scope_label: String
    # When ``request_variables`` lands, the response goes to one of two
    # destinations: either the initial scope load (replace top of pane)
    # or a tree expansion (splice into existing rows). These fields
    # track which one the next ``has_variables`` should fold into.
    var _dap_var_target_kind: UInt8     # 0=scope_initial, 1=expand
    var _dap_var_target_row: Int
    var _dap_var_target_depth: Int
    # Cached inspect inputs so we can rebuild the pane when only one
    # of (stack, locals, watches) changes.
    var _dap_stack_cache: List[DapStackFrame]
    var _dap_watch_exprs: List[String]
    var _dap_watch_values: List[String]   # parallel to exprs (last result)

    fn __init__(out self):
        self.menu_bar = MenuBar()
        self.windows = WindowManager()
        self.status_bar = StatusBar()
        self.file_tree = FileTree()
        self.prompt = Prompt()
        self.quick_open = QuickOpen()
        self.save_as_dialog = SaveAsDialog()
        self.symbol_pick = SymbolPick()
        self.project_find = ProjectFind()
        self.bg_pattern = String("▒")
        self.bg_attr = Attr(LIGHT_GRAY, BLUE)
        self.project = Optional[String]()
        self._project_menu_idx = -1
        self._window_menu_idx = -1
        self._pending_action = String("")
        self._pending_arg = String("")
        self._open_count = 0
        self._untitled_count = 0
        self._hotkeys = List[Hotkey]()
        self._esc_armed = False
        self.lsp_specs = built_in_servers()
        self.lsp_managers = List[LspManager]()
        self.lsp_languages = List[String]()
        self.dap = DapManager()
        self.dap_specs = built_in_debuggers()
        self.debug_pane = DebugPane()
        self._dap_exec_path = String("")
        self._dap_exec_line = -1
        self._dap_current_frame_id = -1
        self._dap_pending_scope_label = String("")
        self._dap_var_target_kind = UInt8(0)
        self._dap_var_target_row = -1
        self._dap_var_target_depth = 0
        self._dap_stack_cache = List[DapStackFrame]()
        self._dap_watch_exprs = List[String]()
        self._dap_watch_values = List[String]()
        # Add the framework's dynamic Window menu up-front so it renders in
        # the natural position (left-aligned, after whatever the host adds).
        # ``_rebuild_window_menu`` repopulates its items every paint.
        self.menu_bar.add(Menu(_WINDOW_MENU_LABEL, List[MenuItem]()))
        self._window_menu_idx = len(self.menu_bar.menus) - 1
        # Default hotkeys. ``Ctrl+letter`` arrives as a control character on
        # almost every terminal, so the bindings are stored as the raw
        # control codepoint with ``MOD_NONE``. ``Ctrl+Shift+letter`` requires
        # a terminal that reports modifiers for letter keys (CSI u or
        # modifyOtherKeys=2 — limited support today); the bindings are still
        # registered so they work as soon as parser support lands.
        self._hotkeys.append(Hotkey(ctrl_key("q"), MOD_NONE, APP_QUIT_ACTION))
        self._hotkeys.append(Hotkey(ctrl_key("w"), MOD_NONE, WINDOW_CLOSE))
        self._hotkeys.append(Hotkey(ctrl_key("n"), MOD_NONE, EDITOR_NEW))
        self._hotkeys.append(Hotkey(ctrl_key("o"), MOD_NONE, EDITOR_QUICK_OPEN))
        self._hotkeys.append(Hotkey(ctrl_key("s"), MOD_NONE, EDITOR_SAVE))
        self._hotkeys.append(Hotkey(ctrl_key("f"), MOD_NONE, EDITOR_FIND))
        self._hotkeys.append(Hotkey(ctrl_key("r"), MOD_NONE, EDITOR_REPLACE))
        self._hotkeys.append(Hotkey(ctrl_key("g"), MOD_NONE, EDITOR_GOTO))
        self._hotkeys.append(Hotkey(ctrl_key("t"), MOD_NONE, EDITOR_GOTO_SYMBOL))
        # Clipboard + undo/redo. Registering Ctrl+X/C/V at the desktop layer
        # serves two purposes: the menu items get auto-populated shortcut
        # text via ``_shortcut_for_action``, and the dispatch path is
        # uniform whether the user clicks a menu or hits the key. Ctrl+Z /
        # Ctrl+Y use the de-facto-standard binding.
        self._hotkeys.append(Hotkey(ctrl_key("x"), MOD_NONE, EDITOR_CUT))
        self._hotkeys.append(Hotkey(ctrl_key("c"), MOD_NONE, EDITOR_COPY))
        self._hotkeys.append(Hotkey(ctrl_key("v"), MOD_NONE, EDITOR_PASTE))
        self._hotkeys.append(Hotkey(ctrl_key("z"), MOD_NONE, EDITOR_UNDO))
        self._hotkeys.append(Hotkey(ctrl_key("y"), MOD_NONE, EDITOR_REDO))
        self._hotkeys.append(Hotkey(
            UInt32(ord("f")), MOD_CTRL | MOD_SHIFT, PROJECT_FIND,
        ))
        self._hotkeys.append(Hotkey(
            UInt32(ord("r")), MOD_CTRL | MOD_SHIFT, PROJECT_REPLACE,
        ))
        # Window switching: Ctrl+1 .. Ctrl+9 focus the first nine windows by
        # the same number shown in the top-right of each window's chrome.
        # Each binding's action carries the target index, so the dynamic
        # Window menu's items get matching ``Ctrl+N`` shortcut text via
        # ``_refresh_shortcuts`` without any extra wiring.
        for n in range(9):
            self._hotkeys.append(Hotkey(
                UInt32(ord("1") + n),
                MOD_CTRL,
                WINDOW_FOCUS_PREFIX + String(n),
            ))
        # Side-panel focus: Ctrl+0 → file tree, Ctrl+9 → debug pane.
        # These match the ``0`` / ``9`` glyphs each panel paints in
        # its top-right corner. Registered after the Ctrl+1..9 loop
        # so the Ctrl+9 binding here wins over the (rare) 9th window
        # — the lookup walks newest-first, and a debug pane is far
        # more commonly reached than a 9th open window.
        self._hotkeys.append(Hotkey(
            UInt32(ord("0")), MOD_CTRL, FILE_TREE_FOCUS,
        ))
        self._hotkeys.append(Hotkey(
            UInt32(ord("9")), MOD_CTRL, DEBUG_FOCUS_PANE,
        ))
        # Debugger bindings: F5 / F9 / F10 / F11 / Shift+F11 / Shift+F5 —
        # the de facto standard set across VS Code, JetBrains, and most
        # other IDEs. Registered after the Ctrl-letter set so any user
        # override registered later still wins (the lookup walks
        # newest-first).
        self._hotkeys.append(Hotkey(
            KEY_F5, MOD_NONE, DEBUG_START_OR_CONTINUE,
        ))
        self._hotkeys.append(Hotkey(KEY_F5, MOD_SHIFT, DEBUG_STOP))
        self._hotkeys.append(Hotkey(
            KEY_F9, MOD_NONE, DEBUG_TOGGLE_BREAKPOINT,
        ))
        self._hotkeys.append(Hotkey(
            KEY_F9, MOD_SHIFT, DEBUG_CONDITIONAL_BP,
        ))
        self._hotkeys.append(Hotkey(KEY_F10, MOD_NONE, DEBUG_STEP_OVER))
        self._hotkeys.append(Hotkey(KEY_F11, MOD_NONE, DEBUG_STEP_IN))
        self._hotkeys.append(Hotkey(KEY_F11, MOD_SHIFT, DEBUG_STEP_OUT))
        # F8: toggle debug pane focus. Workaround until pane-mouse
        # works; arrow keys then scroll the stack list while the
        # pane is focused.
        self._hotkeys.append(Hotkey(KEY_F8, MOD_NONE, DEBUG_FOCUS_PANE))

    fn workspace_rect(self, screen: Rect) -> Rect:
        """Floating-window area: between menu bar, status bar, and any docked
        widgets. The file tree, when visible, eats space on the right; the
        debug pane, when active, eats space at the bottom."""
        var right = screen.b.x
        if self.file_tree.visible:
            right -= self.file_tree.width
            if right < 0:
                right = 0
        var bottom = screen.b.y - 1
        if self.debug_pane.visible:
            bottom -= self.debug_pane.preferred_height
            if bottom < 1:
                bottom = 1
        return Rect(0, 1, right, bottom)

    fn debug_pane_rect(self, screen: Rect) -> Rect:
        """Where the bottom-docked debug pane lives — above the status
        bar (which is always one row tall at ``screen.b.y - 1``)."""
        if not self.debug_pane.visible:
            return Rect.empty()
        var top = screen.b.y - 1 - self.debug_pane.preferred_height
        if top < 1:
            top = 1
        return Rect(0, top, screen.b.x, screen.b.y - 1)

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        # Drive any per-frame timers before drawing — the project-find
        # widget runs its 200 ms debounce off this clock.
        self.project_find.tick(monotonic_ms())
        # Refit windows to the current workspace before painting. Cheap
        # (idempotent for already-fitting windows) and covers both file
        # tree toggles and terminal resizes uniformly.
        self.windows.fit_into(self.workspace_rect(screen))
        # Rebuild the Window menu from current state so it always reflects
        # what's actually open. (Cheap; one short item list.)
        self._rebuild_window_menu()
        # Stamp the right-aligned shortcut text onto each menu item so it
        # picks up user-registered hotkey overrides automatically.
        self._refresh_shortcuts()
        canvas.fill(self.workspace_rect(screen), self.bg_pattern, self.bg_attr)
        self.windows.paint(canvas)
        self.file_tree.paint(canvas, screen)
        self.debug_pane.paint(canvas, self.debug_pane_rect(screen))
        self.menu_bar.paint(canvas, screen)
        self.status_bar.paint(canvas, screen)
        # Modal layers float above everything else. Only one is ever active
        # at a time (open_quick_open won't fire while a prompt is up, etc.),
        # so paint order doesn't matter for correctness.
        self.prompt.paint(canvas, screen)
        self.quick_open.paint(canvas, screen)
        self.save_as_dialog.paint(canvas, screen)
        self.symbol_pick.paint(canvas, screen)
        self.project_find.paint(canvas, screen)

    fn _shortcut_for_action(self, action: String) -> String:
        """Reverse-lookup the most recently registered hotkey for ``action``
        (matching the dispatch order — newest wins). Empty string if none."""
        if len(action.as_bytes()) == 0:
            return String("")
        var i = len(self._hotkeys) - 1
        while i >= 0:
            if self._hotkeys[i].action == action:
                return format_hotkey(self._hotkeys[i].key, self._hotkeys[i].mods)
            i -= 1
        return String("")

    fn _refresh_shortcuts(mut self):
        for m in range(len(self.menu_bar.menus)):
            for it in range(len(self.menu_bar.menus[m].items)):
                if self.menu_bar.menus[m].items[it].is_separator:
                    continue
                var action = self.menu_bar.menus[m].items[it].action
                self.menu_bar.menus[m].items[it].shortcut = \
                    self._shortcut_for_action(action)

    # --- opening files -----------------------------------------------------

    fn open_file(mut self, path: String, screen: Rect) raises:
        """Open ``path`` as an editor window using framework defaults.

        Sizing: 80% of the current workspace, clamped to the workspace and
        to ``MIN_WIN_*``. Position: cascaded down-and-right by ``+1, +1``
        each call (mod-wraps when it would otherwise walk off-screen).
        Maximization: if the frontmost window is currently maximized, the
        new window starts maximized too — the underlying ``_restore_rect``
        is the 80% rect, so toggling maximize off lands on the cascade slot.
        Project: ``detect_project_from(path)`` runs first so the project
        menu reflects the new file's repo on the same frame.

        If the file is a Mojo source file, the LSP server is spawned (once)
        and notified about the new document so cmd+click goto-definition
        works without any extra wiring on the host side.

        If a window for the same file is already open, focus is moved
        to that window and a second copy is **not** created — re-opening
        is a no-op rather than a way to multiply windows on the same
        path. Path comparison uses ``realpath`` so symlink + canonical
        spellings are treated as the same file.
        """
        var existing = self._find_window_for_path(path)
        if existing >= 0:
            self.windows.focus_by_index(existing)
            return
        self.detect_project_from(path)
        var workspace = self.workspace_rect(screen)
        var rect = self._default_window_rect(workspace)
        var was_max = self._frontmost_maximized()
        var w = Window.from_file(basename(path), rect, path)
        self.windows.add(w^)
        self._open_count += 1
        if was_max:
            var idx = len(self.windows.windows) - 1
            self.windows.windows[idx].toggle_maximize(workspace)
        self._maybe_lsp_open(len(self.windows.windows) - 1)

    fn new_file(mut self, screen: Rect):
        """Open a fresh, file-less editor window using the same placement
        rules as ``open_file``. The first window is titled ``Untitled``;
        subsequent ones get a numeric suffix so the dynamic Window menu
        and per-window save prompts stay distinguishable.
        """
        self._untitled_count += 1
        var title = String("Untitled")
        if self._untitled_count > 1:
            title = title + String(" ") + String(self._untitled_count)
        var workspace = self.workspace_rect(screen)
        var rect = self._default_window_rect(workspace)
        var was_max = self._frontmost_maximized()
        self.windows.add(Window.editor_window(title^, rect, String("")))
        self._open_count += 1
        if was_max:
            var idx = len(self.windows.windows) - 1
            self.windows.windows[idx].toggle_maximize(workspace)

    fn _maybe_lsp_open(mut self, idx: Int):
        """If the window at ``idx`` is an editor for a recognized source
        file type, ensure the matching LSP server is started and inform
        it of this document. Languages without an installed server are
        a silent no-op."""
        if idx < 0 or idx >= len(self.windows.windows):
            return
        if not self.windows.windows[idx].is_editor:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            return
        var lsp_idx = self._ensure_lsp_for_extension(extension_of(path))
        if lsp_idx < 0:
            return
        var text = self.windows.windows[idx].editor.text_snapshot()
        self.lsp_managers[lsp_idx].notify_opened(path, text^)

    fn _ensure_lsp_for_extension(mut self, ext: String) -> Int:
        """Spawn (or look up) an LSP manager for files with extension
        ``ext``. Returns the index into ``lsp_managers`` of the manager,
        or ``-1`` for unsupported file types or when no candidate
        binary is installed. Idempotent — re-calling for an already-
        spawned language returns the existing index.

        ``ext`` is matched against the registry's ``file_types``; the
        matching ``LanguageSpec`` then drives binary selection. The
        first candidate in ``spec.candidates`` whose binary exists on
        ``$PATH`` (per ``which()``) wins. Mojo gets special-cased to
        thread ``-I`` include flags through the LSP argv.
        """
        var spec_idx = find_language_for_extension(self.lsp_specs, ext)
        if spec_idx < 0:
            return -1
        var lang = self.lsp_specs[spec_idx].language_id
        for i in range(len(self.lsp_languages)):
            if self.lsp_languages[i] == lang:
                return i
        # Pick the first installed candidate.
        var argv = List[String]()
        var argv_found = False
        var spec = self.lsp_specs[spec_idx]
        for c in range(len(spec.candidates)):
            var cand = spec.candidates[c]
            if len(cand.argv) == 0:
                continue
            if len(which(cand.argv[0]).as_bytes()) > 0:
                for k in range(len(cand.argv)):
                    argv.append(cand.argv[k])
                argv_found = True
                break
        if not argv_found:
            return -1
        var root = String("")
        if self.project:
            root = self.project.value()
        # Mojo wants ``-I <root> -I <root>/src`` injected so the server
        # can resolve project imports. Other languages take their argv
        # straight from the registry.
        if lang == String("mojo"):
            var includes = _mojo_include_dirs(root)
            for i in range(len(includes)):
                argv.append(String("-I"))
                argv.append(includes[i])
        var manager = LspManager()
        manager.start_with(lang, argv, root)
        self.lsp_managers.append(manager^)
        self.lsp_languages.append(lang)
        return len(self.lsp_managers) - 1

    fn _lsp_for_path(self, path: String) -> Int:
        """Index into ``lsp_managers`` of the (already-spawned) server
        handling ``path``, or ``-1`` if none has been spawned for that
        file's extension yet."""
        if len(path.as_bytes()) == 0:
            return -1
        var spec_idx = find_language_for_extension(
            self.lsp_specs, extension_of(path),
        )
        if spec_idx < 0:
            return -1
        var lang = self.lsp_specs[spec_idx].language_id
        for i in range(len(self.lsp_languages)):
            if self.lsp_languages[i] == lang:
                return i
        return -1

    fn _default_window_rect(self, workspace: Rect) -> Rect:
        var w80 = (workspace.width() * 80) // 100
        var h80 = (workspace.height() * 80) // 100
        if w80 < MIN_WIN_W:
            w80 = MIN_WIN_W
        if h80 < MIN_WIN_H:
            h80 = MIN_WIN_H
        if w80 > workspace.width():
            w80 = workspace.width()
        if h80 > workspace.height():
            h80 = workspace.height()
        var slack_x = workspace.width() - w80
        var slack_y = workspace.height() - h80
        var dx = 0
        var dy = 0
        if slack_x > 0:
            dx = self._open_count % (slack_x + 1)
        if slack_y > 0:
            dy = self._open_count % (slack_y + 1)
        var ax = workspace.a.x + dx
        var ay = workspace.a.y + dy
        return Rect(ax, ay, ax + w80, ay + h80)

    fn _frontmost_maximized(self) -> Bool:
        if self.windows.focused < 0 \
                or self.windows.focused >= len(self.windows.windows):
            return False
        return self.windows.windows[self.windows.focused].is_maximized

    # --- dynamic Window menu -----------------------------------------------

    fn _rebuild_window_menu(mut self):
        """Replace the Window menu's items with the current window list +
        a separator + Maximize all + Restore all."""
        if self._window_menu_idx < 0:
            return
        var items = List[MenuItem]()
        for i in range(len(self.windows.windows)):
            items.append(MenuItem(
                self.windows.windows[i].title,
                WINDOW_FOCUS_PREFIX + String(i),
            ))
        if len(self.windows.windows) > 0:
            items.append(MenuItem.separator())
        items.append(MenuItem(String("Maximize all"), WINDOW_MAXIMIZE_ALL))
        items.append(MenuItem(String("Restore all"), WINDOW_RESTORE_ALL))
        self.menu_bar.menus[self._window_menu_idx].items = items^

    # --- project state -----------------------------------------------------

    fn detect_project_from(mut self, path: String):
        """Set the project to the ``.git`` ancestor of ``path``, if any.

        No-op if a project is already set — the user closes it explicitly
        before a new one can be auto-detected.
        """
        if self.project:
            return
        var found = find_git_project(path)
        if found:
            self._set_project(found.value())

    fn close_project(mut self):
        self.project = Optional[String]()
        self.file_tree.close()
        if self._project_menu_idx >= 0:
            self.menu_bar.menus[self._project_menu_idx].visible = False
            if self.menu_bar.open_idx == self._project_menu_idx:
                self.menu_bar.open_idx = -1
            # Reset the tree-toggle label for the next project.
            self.menu_bar.menus[self._project_menu_idx].items[0].label = _SHOW_TREE_LABEL

    fn _set_project(mut self, path: String):
        self.project = Optional[String](path)
        var label = basename(path)
        if self._project_menu_idx < 0:
            var items = List[MenuItem]()
            items.append(MenuItem(_SHOW_TREE_LABEL, PROJECT_TREE_ACTION))
            items.append(MenuItem(String("Close project"), PROJECT_CLOSE_ACTION))
            self.menu_bar.add(Menu(label, items^, right_aligned=True))
            self._project_menu_idx = len(self.menu_bar.menus) - 1
        else:
            self.menu_bar.menus[self._project_menu_idx].label = label
            self.menu_bar.menus[self._project_menu_idx].visible = True

    fn _toggle_file_tree(mut self):
        if self._project_menu_idx < 0 or not self.project:
            return
        if self.file_tree.visible:
            self.file_tree.close()
            self.menu_bar.menus[self._project_menu_idx].items[0].label = \
                _SHOW_TREE_LABEL
        else:
            self.file_tree.open(self.project.value())
            self.menu_bar.menus[self._project_menu_idx].items[0].label = \
                _HIDE_TREE_LABEL

    # --- events ------------------------------------------------------------

    fn handle_event(mut self, event: Event, screen: Rect) -> Optional[String]:
        """Single entry point for every event the app receives.

        The Desktop handles the prompt-modal lifecycle, mouse routing, and
        all editor / project actions internally. ESC closes whichever modal
        layer is currently active (prompt → quick open → menu) and is
        otherwise dropped — apps that want a quit binding should register
        one explicitly (the default ``Ctrl+Q`` hotkey already does). Any
        action the Desktop doesn't claim is returned verbatim for the
        caller to dispatch.
        """
        if self.prompt.active:
            if event.kind == EVENT_KEY:
                _ = self.prompt.handle_key(event)
                if self.prompt.submitted:
                    return self._on_prompt_submit()
            return Optional[String]()
        if self.save_as_dialog.active:
            if event.kind == EVENT_KEY:
                _ = self.save_as_dialog.handle_key(event)
            else:
                _ = self.save_as_dialog.handle_mouse(event, screen)
            if self.save_as_dialog.submitted:
                var path = self.save_as_dialog.selected_path
                self.save_as_dialog.close()
                var idx = self._focused_editor_idx()
                if idx >= 0:
                    try:
                        _ = self.windows.windows[idx].editor.save_as(path)
                    except:
                        pass
            return Optional[String]()
        if self.quick_open.active:
            if event.kind == EVENT_KEY:
                _ = self.quick_open.handle_key(event)
            else:
                _ = self.quick_open.handle_mouse(event, screen)
            if self.quick_open.submitted:
                var path = self.quick_open.selected_path
                self.quick_open.close()
                try:
                    self.open_file(path, screen)
                except:
                    pass
            return Optional[String]()
        if self.symbol_pick.active:
            if event.kind == EVENT_KEY:
                _ = self.symbol_pick.handle_key(event)
            else:
                _ = self.symbol_pick.handle_mouse(event, screen)
            if self.symbol_pick.submitted:
                var line = self.symbol_pick.selected_line
                var character = self.symbol_pick.selected_character
                var path = self.symbol_pick.path
                self.symbol_pick.close()
                self._jump_to(
                    DefinitionResolved(path, line, character), screen,
                )
            return Optional[String]()
        if self.project_find.active:
            if event.kind == EVENT_KEY:
                _ = self.project_find.handle_key(event, monotonic_ms())
            else:
                _ = self.project_find.handle_mouse(event, screen)
            if self.project_find.submitted:
                var path = self.project_find.selected_path
                var line_no = self.project_find.selected_line
                self.project_find.close()
                # Open (or focus) the file, then move the cursor to the
                # 1-based line number reported by ``find_in_project``.
                self._jump_to(
                    DefinitionResolved(path, line_no - 1, 0), screen,
                )
            return Optional[String]()
        if event.kind == EVENT_KEY:
            # Side panels absorb arrow / Enter / Esc when focused;
            # if neither claims the key, fall through to the regular
            # dispatch (menu mnemonics, hotkeys, focused window).
            if self.debug_pane.handle_key(event):
                return Optional[String]()
            if self.file_tree.handle_key(event):
                return Optional[String]()
            return self._handle_key(event, screen)
        # Mouse events (and everything else): route through menu → pane → tree → windows.
        var result = self.menu_bar.handle_event(event, screen.b.x)
        if result.action:
            return self.dispatch_action(result.action.value(), screen)
        if result.consumed:
            return Optional[String]()
        if self.debug_pane.handle_mouse(event, self.debug_pane_rect(screen)):
            return Optional[String]()
        if self.file_tree.handle_mouse(event, screen):
            return Optional[String]()
        _ = self.windows.handle_mouse(event, self.workspace_rect(screen))
        return Optional[String]()

    fn _handle_key(mut self, event: Event, screen: Rect) -> Optional[String]:
        # Capture and reset the one-shot ESC-prefix flag so this keystroke
        # gets at most one chance to act as a mnemonic via that path.
        var was_armed = self._esc_armed
        self._esc_armed = False
        if event.key == KEY_ESC:
            # ESC only closes whatever modal layer is open; it never quits
            # the app on its own. Quit is reserved for explicit bindings
            # like the default Ctrl+Q hotkey. When no modal is up, ESC
            # arms the prefix path so the next keystroke can act as a
            # menu mnemonic — useful on macOS terminals that don't deliver
            # Option+F as ``ESC f`` by default.
            if self.menu_bar.is_open():
                self.menu_bar.close()
            else:
                self._esc_armed = True
            return Optional[String]()
        # When a menu is open, it captures keyboard focus: arrow keys
        # navigate, Enter activates. Mnemonic switching (Alt+<letter>)
        # still works as a fall-through if the menu doesn't consume.
        if self.menu_bar.is_open():
            var mr = self.menu_bar.handle_key(event)
            if mr.action:
                var action = mr.action.value()
                return self.dispatch_action(action, screen)
            if mr.consumed:
                return Optional[String]()
            if event.mods == MOD_ALT and self._open_menu_by_mnemonic(event.key):
                return Optional[String]()
            # Anything else is swallowed — typing into windows while a menu
            # is open would be surprising.
            return Optional[String]()
        # ESC-prefix menu mnemonic: if the previous keystroke armed us and
        # this one is a letter, treat as Alt+<letter>.
        if was_armed and event.mods == MOD_NONE \
                and self._open_menu_by_mnemonic(event.key):
            return Optional[String]()
        # Hotkey lookup: walk registrations newest-first so user-supplied
        # bindings can override the defaults. Hotkeys take priority over
        # forwarding to the focused window — without that priority, ``Ctrl+F``
        # would land in the editor as an unknown 0x06 character instead of
        # opening the find prompt.
        var i = len(self._hotkeys) - 1
        while i >= 0:
            if self._hotkeys[i].key == event.key \
                    and self._hotkeys[i].mods == event.mods:
                # Copy out before calling dispatch_action — the call may
                # mutate self, which would alias the borrowed string.
                var action = self._hotkeys[i].action
                return self.dispatch_action(action, screen)
            i -= 1
        # Direct Alt+<letter> mnemonic: works on terminals that send
        # Option+F as the literal ``ESC f`` byte pair (Linux defaults,
        # macOS terminals with "Use Option as Meta key" enabled).
        if event.mods == MOD_ALT and self._open_menu_by_mnemonic(event.key):
            return Optional[String]()
        _ = self.windows.handle_key(event)
        return Optional[String]()

    fn _open_menu_by_mnemonic(mut self, key: UInt32) -> Bool:
        var k = Int(key)
        if 0x41 <= k and k <= 0x5A:
            k = k + 0x20
        if not (0x61 <= k and k <= 0x7A):
            return False
        for mi in range(len(self.menu_bar.menus)):
            if not self.menu_bar.menus[mi].visible:
                continue
            var lb = self.menu_bar.menus[mi].label.as_bytes()
            if len(lb) == 0:
                continue
            var first = Int(lb[0])
            if 0x41 <= first and first <= 0x5A:
                first = first + 0x20
            if first == k:
                self.menu_bar.open_menu(mi)
                return True
        return False

    fn register_hotkey(
        mut self, key: UInt32, mods: UInt8, action: String,
    ):
        """Bind ``(key, mods)`` to ``action``.

        User registrations win over the framework's defaults — the lookup
        scans newest-first. Use ``ctrl_key("x")`` to encode a ``Ctrl+letter``
        binding (most terminals deliver those as control characters with
        ``MOD_NONE``).
        """
        self._hotkeys.append(Hotkey(key, mods, action))

    fn dispatch_action(
        mut self, action: String, screen: Rect,
    ) -> Optional[String]:
        """Execute a framework-recognized action; pass anything else back.

        Apps can call this to bind keyboard shortcuts to action strings
        without going through the menu bar. ``screen`` is needed for the
        maximize-related actions; pass the same rect you use for paint.
        """
        if action == PROJECT_CLOSE_ACTION:
            self.close_project()
            return Optional[String]()
        if action == PROJECT_TREE_ACTION:
            self._toggle_file_tree()
            return Optional[String]()
        if action == EDITOR_NEW:
            self.new_file(screen)
            return Optional[String]()
        if action == EDITOR_SAVE:
            self._do_save()
            return Optional[String]()
        if action == EDITOR_SAVE_AS:
            self._open_save_as_dialog()
            return Optional[String]()
        if action == EDITOR_QUICK_OPEN:
            # Project-aware: only meaningful when a project is set. Without
            # one, bubble the action up so the host can fall back to its
            # own "Open..." UI (typically a file dialog).
            if self.project:
                self.quick_open.open(self.project.value())
                return Optional[String]()
            return Optional[String](action)
        if action == EDITOR_FIND:
            self._pending_action = EDITOR_FIND
            self.prompt.open(String("Find: "))
            return Optional[String]()
        if action == EDITOR_REPLACE:
            self._pending_action = _PA_REPLACE_FIND
            self.prompt.open(String("Replace — find: "))
            return Optional[String]()
        if action == EDITOR_GOTO:
            self._pending_action = EDITOR_GOTO
            self.prompt.open(String("Go to line: "))
            return Optional[String]()
        if action == EDITOR_GOTO_SYMBOL:
            self._open_symbol_pick()
            return Optional[String]()
        if action == EDITOR_TOGGLE_COMMENT:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.toggle_comment()
            return Optional[String]()
        if action == EDITOR_TOGGLE_CASE:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.toggle_case()
            return Optional[String]()
        if action == EDITOR_CUT:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.cut_to_clipboard()
            return Optional[String]()
        if action == EDITOR_COPY:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                self.windows.windows[self.windows.focused].editor.copy_to_clipboard()
            return Optional[String]()
        if action == EDITOR_PASTE:
            # Paste, undo, and redo can land the cursor anywhere in the
            # buffer — ``reveal_cursor`` brings it back into view since
            # the per-keystroke ``_scroll_to_cursor`` in editor.handle_key
            # is bypassed when the action arrives via a desktop hotkey or
            # menu click.
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                var idx = self.windows.focused
                self.windows.windows[idx].editor.paste_from_clipboard()
                self.windows.windows[idx].editor.reveal_cursor(
                    self.windows.windows[idx].interior(),
                )
            return Optional[String]()
        if action == EDITOR_UNDO:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                var idx = self.windows.focused
                if self.windows.windows[idx].editor.undo():
                    self.windows.windows[idx].editor.reveal_cursor(
                        self.windows.windows[idx].interior(),
                    )
            return Optional[String]()
        if action == EDITOR_REDO:
            if self.windows.focused >= 0 \
                    and self.windows.windows[self.windows.focused].is_editor:
                var idx = self.windows.focused
                if self.windows.windows[idx].editor.redo():
                    self.windows.windows[idx].editor.reveal_cursor(
                        self.windows.windows[idx].interior(),
                    )
            return Optional[String]()
        if action == PROJECT_FIND:
            if self.project:
                self.project_find.open(self.project.value())
            return Optional[String]()
        if action == PROJECT_REPLACE:
            if self.project:
                self._pending_action = _PA_PROJECT_REPLACE_FIND
                self.prompt.open(String("Replace in project — find: "))
            return Optional[String]()
        if action == WINDOW_MAXIMIZE_ALL:
            self.windows.maximize_all(self.workspace_rect(screen))
            return Optional[String]()
        if action == WINDOW_RESTORE_ALL:
            self.windows.restore_all()
            return Optional[String]()
        if action == WINDOW_CLOSE:
            _ = self.windows.close_focused()
            return Optional[String]()
        if _starts_with(action, WINDOW_FOCUS_PREFIX):
            var idx = _parse_int(action, len(WINDOW_FOCUS_PREFIX.as_bytes()))
            self.windows.focus_by_index(idx)
            # Switching to a window means leaving the side panels —
            # otherwise their handle_key keeps swallowing arrows
            # when the user expects them at the editor cursor.
            self.debug_pane.focused = False
            self.file_tree.focused = False
            return Optional[String]()
        if action == DEBUG_TOGGLE_BREAKPOINT:
            self._debug_toggle_breakpoint()
            return Optional[String]()
        if action == DEBUG_CONDITIONAL_BP:
            self._debug_open_condition_prompt()
            return Optional[String]()
        if action == DEBUG_START_OR_CONTINUE:
            self._debug_start_or_continue()
            return Optional[String]()
        if action == DEBUG_STEP_OVER:
            _ = self.dap.next()
            return Optional[String]()
        if action == DEBUG_STEP_IN:
            _ = self.dap.step_in()
            return Optional[String]()
        if action == DEBUG_STEP_OUT:
            _ = self.dap.step_out()
            return Optional[String]()
        if action == DEBUG_STOP:
            self.dap.shutdown()
            self._dap_exec_path = String("")
            self._dap_exec_line = -1
            return Optional[String]()
        if action == DEBUG_ADD_WATCH:
            self._pending_action = _PA_ADD_WATCH
            self.prompt.open(String("Watch expression: "))
            return Optional[String]()
        if action == DEBUG_TOGGLE_RAISED:
            self._toggle_raised_exceptions()
            return Optional[String]()
        if action == DEBUG_FOCUS_PANE:
            # Ctrl+9 from anywhere should *focus* the pane, not
            # toggle blindly — toggling-off would land the user
            # nowhere predictable. Force-on, and steal focus from
            # the file tree so only one side panel is keyboard-live
            # at a time.
            self.debug_pane.focused = True
            self.file_tree.focused = False
            return Optional[String]()
        if action == FILE_TREE_FOCUS:
            self.file_tree.focused = True
            self.debug_pane.focused = False
            return Optional[String]()
        return Optional[String](action)

    # --- LSP tick ---------------------------------------------------------

    fn lsp_tick(mut self, screen: Rect):
        """Drain editor → LSP → editor for the focused frame.

        Step 1: if the focused editor has a pending Cmd+click definition
                request, forward it to the LSP server matching that
                file's language (with the latest buffer text so the
                server's view is up to date).
        Step 2: tick every spawned server so responses keep flowing,
                and jump on any that comes back with a concrete location.
        Step 3: refresh the right-aligned LSP indicator on the status bar.
        """
        var idx = self._focused_editor_idx()
        if idx >= 0:
            var req_opt = self.windows.windows[idx].editor.consume_definition_request()
            if req_opt:
                self._dispatch_definition_request(idx, req_opt.value())
        # Drain every spawned manager every frame so responses on any
        # language server make progress regardless of which file is
        # focused.
        for i in range(len(self.lsp_managers)):
            var resolved = self.lsp_managers[i].tick()
            if resolved:
                self._jump_to(resolved.value(), screen)
            if self.symbol_pick.active and self.symbol_pick.loading \
                    and self.lsp_managers[i].has_pending_symbols():
                self.symbol_pick.set_entries(
                    self.lsp_managers[i].take_symbols(),
                )
        self._refresh_lsp_status()

    fn _dispatch_definition_request(
        mut self, win_idx: Int, var req: DefinitionRequest,
    ):
        """Forward a Cmd+click definition request to the right server,
        with status-bar messaging for the common failure modes."""
        var path = self.windows.windows[win_idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("LSP: file has no path"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var lsp_idx = self._lsp_for_path(path)
        if lsp_idx < 0:
            self.status_bar.set_message(
                String("LSP: not started for this file type"),
                Attr(RED, LIGHT_GRAY),
            )
            return
        if self.lsp_managers[lsp_idx].is_failed():
            return
        if not self.lsp_managers[lsp_idx].is_active():
            self.status_bar.set_message(
                String("LSP: not started for this file type"),
                Attr(RED, LIGHT_GRAY),
            )
            return
        var text = self.windows.windows[win_idx].editor.text_snapshot()
        # Read primitive fields first; ``word`` is moved last so it's
        # the only ownership transfer out of ``req``. Reseat afterwards
        # so Mojo's auto-destructor sees a valid String.
        var row = req.row
        var col = req.col
        var word = req.word^
        req.word = String("")
        var ok = self.lsp_managers[lsp_idx].request_definition(
            path, row, col, word^, text^,
        )
        if not ok:
            self.status_bar.set_message(
                String("LSP: still starting up — try again"),
                Attr(YELLOW, LIGHT_GRAY),
            )

    fn _refresh_lsp_status(mut self):
        """Show the focused editor's language-server state on the right
        side of the status bar. The prefix carries the language id so
        the user can tell whether a slow response is from mojo-lsp or
        pyright; flipping focus between a ``.mojo`` and a ``.py`` window
        flips the indicator. Files with no associated server (or no
        server installed) leave the existing message alone.
        """
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        var lsp_idx = self._lsp_for_path(path)
        if lsp_idx < 0:
            return
        var prefix = String("LSP[") + self.lsp_languages[lsp_idx] \
            + String("]: ")
        _refresh_status_for(
            self.status_bar, prefix, self.lsp_managers[lsp_idx],
        )

    # --- DAP wiring ------------------------------------------------------

    fn dap_tick(mut self, screen: Rect):
        """Drive the DAP session forward and reflect its state in the UI.

        Called once per frame by the host (just like ``lsp_tick``).
        Steps:

        1. ``self.dap.tick()`` drains incoming messages, advancing the
           handshake and parking events.
        2. On a fresh ``stopped`` event, request a single-frame stack
           trace so we can paint the ``▶`` arrow on the right line.
        3. When the trace lands, latch ``_dap_exec_*`` and auto-jump the
           workspace to that location (opening the file if needed).
        4. ``terminated`` clears the latched arrow and the breakpoint
           gutter so the editor returns to a quiescent state.
        5. Push the per-file breakpoint slice + exec arrow onto every
           editor window's gutter fields, sized to 2 columns when
           anything debugger-related applies to that file.
        6. Refresh the right-aligned status indicator.
        """
        self.dap.tick()
        var stopped = self.dap.take_stopped()
        if stopped:
            # Fetch a deeper trace so the pane can show context, not
            # just the top frame. 64 frames is plenty for typical
            # stacks and trivial in payload size.
            _ = self.dap.request_stack_trace(stopped.value().thread_id, 64)
        # Frame click from the pane: re-fetch scopes for the chosen frame.
        var fclick = self.debug_pane.consume_frame_click()
        if fclick[0] != -1:
            self._dap_current_frame_id = fclick[0]
            self._dap_var_target_kind = UInt8(0)
            _ = self.dap.request_scopes(fclick[0])
            self._refresh_watches()
        # Variable expand click: request children for the row's ref.
        var eclick = self.debug_pane.consume_expand()
        if eclick[0] != -1:
            self._dap_var_target_kind = UInt8(1)
            self._dap_var_target_row = eclick[1]
            self._dap_var_target_depth = eclick[2]
            _ = self.dap.request_variables(eclick[0])
        # Collapse click: purely local, no DAP traffic.
        var cclick = self.debug_pane.consume_collapse()
        if cclick != -1:
            self.debug_pane.collapse_at(cclick)
        if self.dap.has_stack():
            var frames = self.dap.take_stack()
            if len(frames) > 0:
                self._dap_exec_path = frames[0].path
                self._dap_exec_line = frames[0].line
                self._dap_current_frame_id = frames[0].id
                if len(frames[0].path.as_bytes()) > 0:
                    self._jump_to(
                        DefinitionResolved(
                            frames[0].path, frames[0].line, 0,
                        ),
                        screen,
                    )
                # Cache the stack so subsequent variable arrivals can
                # rebuild the pane's inspect rows around the same frames.
                self._dap_stack_cache = frames.copy()
                # Kick off the chain: scopes → variables → pane fill.
                var top_id = frames[0].id
                self._dap_var_target_kind = UInt8(0)
                _ = self.dap.request_scopes(top_id)
                # Initial pane render: stack + empty locals + watches
                # (so the user sees the stack while variables fetch).
                self._rebuild_pane_inspect(List[DapVariable]())
                # Re-evaluate watch expressions on the new frame.
                self._refresh_watches()
        if self.dap.has_scopes():
            var scopes = self.dap.take_scopes()
            var pick = -1
            for i in range(len(scopes)):
                if not scopes[i].expensive:
                    pick = i
                    break
            if pick < 0 and len(scopes) > 0:
                pick = 0
            if pick >= 0:
                _ = self.dap.request_variables(
                    scopes[pick].variables_reference,
                )
                self._dap_pending_scope_label = scopes[pick].name
        if self.dap.has_variables():
            var vars = self.dap.take_variables()
            if self._dap_var_target_kind == UInt8(1):
                # Expand path: splice children after the parent row.
                self.debug_pane.splice_children_at(
                    self._dap_var_target_row,
                    self._dap_var_target_depth,
                    vars^,
                )
                self._dap_var_target_kind = UInt8(0)
                self._dap_var_target_row = -1
            else:
                # Initial scope load: rebuild the inspect rows around
                # the current stack + new locals.
                self._rebuild_pane_inspect(vars^)
        # Drain evaluate responses (watches). May arrive in batches.
        if self.dap.has_evaluations():
            self._fold_watch_results()
        # Output events get appended to the pane log.
        var outs = self.dap.take_outputs()
        for k in range(len(outs)):
            var cat = _category_to_pane(outs[k].category)
            self.debug_pane.append_output(outs[k].text, cat)
        # Adapter stderr — separate channel from DAP ``output`` events.
        # debugpy / lldb-dap log import failures and crash tracebacks
        # here. Without surfacing this, a crashed adapter looks
        # identical to a slow one — state stays INITIALIZING forever
        # because no response ever lands.
        var err = self.dap.drain_stderr()
        if len(err.as_bytes()) > 0:
            self.debug_pane.append_output(err, UInt8(1))  # PANE_OUT_STDERR
        if self.dap.consume_terminated():
            self._dap_exec_path = String("")
            self._dap_exec_line = -1
            self._dap_current_frame_id = -1
            self._dap_stack_cache = List[DapStackFrame]()
            self.debug_pane.clear()
        # Push gutter state to every editor window. We do this every
        # frame (cheap — small lists, simple equality checks) so the
        # gutter stays in sync after window churn (open / close / focus).
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            var path = self.windows.windows[i].editor.file_path
            if len(path.as_bytes()) == 0:
                self.windows.windows[i].editor.gutter_width = 0
                self.windows.windows[i].editor.exec_line = -1
                continue
            var bps = self.dap.breakpoints_for(path)
            var has_session = self.dap.is_active()
            var has_bps = len(bps) > 0
            if has_session or has_bps:
                self.windows.windows[i].editor.gutter_width = 2
            else:
                self.windows.windows[i].editor.gutter_width = 0
            self.windows.windows[i].editor.breakpoint_lines = bps^
            if _same_file(path, self._dap_exec_path):
                self.windows.windows[i].editor.exec_line = \
                    self._dap_exec_line
            else:
                self.windows.windows[i].editor.exec_line = -1
        # Pane visibility + status. Pane is shown the entire time the
        # session is alive (initialize → terminated) so the user sees
        # the spawn happen in real time. ``set_status`` mirrors the
        # right-aligned status-bar indicator so the same words are
        # always visible whether the user is looking up or down.
        self.debug_pane.visible = self.dap.is_active()
        if self.debug_pane.visible:
            self.debug_pane.set_status(self.dap.status_summary())
        elif self.dap.is_failed():
            # Surface the failure once even though we hide the pane —
            # status-bar message is more discoverable than nothing.
            pass
        self._refresh_dap_status()
        # End-of-tick marker — only emitted when the session is
        # actively running so we don't flood the log with one line per
        # 50 ms during idle. A missing marker right after a request
        # narrows a crash to the post-tick paint / next_event path.
        if self.dap.is_running() or self.dap.is_stopped():
            self.dap.client.process.trace(String("dap_tick done"))

    fn _rebuild_pane_inspect(mut self, var locals: List[DapVariable]):
        """Rebuild the inspect rows from the cached stack + given locals
        + cached watch results. Called whenever any one of those three
        inputs changes; the others are pulled from cached state so the
        pane stays consistent."""
        var watch_lines = List[String]()
        for k in range(len(self._dap_watch_exprs)):
            var v = String("")
            if k < len(self._dap_watch_values):
                v = self._dap_watch_values[k]
            watch_lines.append(
                self._dap_watch_exprs[k] + String(" = ") + v,
            )
        var stack_copy = self._dap_stack_cache.copy()
        self.debug_pane.rebuild_inspect(
            stack_copy^,
            String("Locals"),
            locals^,
            String("Watches"),
            watch_lines^,
            0,  # current frame index — top of stack on initial render
        )

    fn _refresh_watches(mut self):
        """Fire ``evaluate`` for every watch expression against the
        current frame. Results land asynchronously and are folded back
        in via ``_fold_watch_results``."""
        if not self.dap.is_stopped():
            return
        for k in range(len(self._dap_watch_exprs)):
            _ = self.dap.request_evaluate(
                self._dap_watch_exprs[k],
                self._dap_current_frame_id,
                String("watch"),
            )

    fn _fold_watch_results(mut self):
        """Drain DAP evaluate responses, splice them into the parallel
        ``_dap_watch_values`` list, and rebuild the pane so the new
        values show up. Watch results identify themselves by the
        original expression string — we don't keep an explicit seq map
        on the Desktop side because the DAP layer already does that."""
        var batch = self.dap.take_evaluations()
        # ``types`` is returned but the pane currently shows just value.
        for i in range(len(batch.expressions)):
            var e = batch.expressions[i]
            for k in range(len(self._dap_watch_exprs)):
                if self._dap_watch_exprs[k] == e:
                    if k < len(self._dap_watch_values):
                        self._dap_watch_values[k] = batch.values[i]
                    else:
                        self._dap_watch_values.append(batch.values[i])
                    break
        # Pane rebuild needs current locals — we don't have them cached
        # so reuse the existing pane row set by extracting locals from
        # it. Simpler: only rebuild watches' display, which is part of
        # the inspect rows. The cleanest path is to ask for a fresh
        # variables dump on the current frame; cheap because the
        # adapter usually serves these from cache. Skipping that here:
        # when the pane is next rebuilt (next stop, next frame click),
        # the new watch values will be picked up.
        # We can also force an immediate refresh by reusing the last
        # stack with empty locals — but that flickers. The compromise
        # below: just rebuild rows with watch-only update by writing
        # straight into the row text for ``PANE_ROW_WATCH`` rows.
        self._patch_pane_watches()

    fn _patch_pane_watches(mut self):
        """In-place update of the watch rows' text in the pane.
        Avoids a full rebuild (which would collapse any expanded
        variable rows). Called after watch values change."""
        var k = 0
        var i = 0
        while i < len(self.debug_pane.rows) \
                and k < len(self._dap_watch_exprs):
            if self.debug_pane.rows[i].kind == PANE_ROW_WATCH:
                var v = String("")
                if k < len(self._dap_watch_values):
                    v = self._dap_watch_values[k]
                var row = self.debug_pane.rows[i]
                row.text = self._dap_watch_exprs[k] + String(" = ") + v
                self.debug_pane.rows[i] = row
                k += 1
            i += 1

    fn add_watch(mut self, var expression: String):
        """Add a watch expression. Evaluates immediately if the session
        is stopped. Can be called from menu actions / hotkey handlers."""
        self._dap_watch_exprs.append(expression^)
        self._dap_watch_values.append(String("(pending)"))
        if self.dap.is_stopped():
            _ = self.dap.request_evaluate(
                self._dap_watch_exprs[len(self._dap_watch_exprs) - 1],
                self._dap_current_frame_id,
                String("watch"),
            )
        # Force a rebuild so the new watch row appears immediately.
        self._rebuild_pane_inspect(List[DapVariable]())
        self._refresh_watches()

    fn remove_watch(mut self, expression: String):
        var new_exprs = List[String]()
        var new_values = List[String]()
        for k in range(len(self._dap_watch_exprs)):
            if self._dap_watch_exprs[k] == expression:
                continue
            new_exprs.append(self._dap_watch_exprs[k])
            if k < len(self._dap_watch_values):
                new_values.append(self._dap_watch_values[k])
        self._dap_watch_exprs = new_exprs^
        self._dap_watch_values = new_values^

    fn _refresh_dap_status(mut self):
        """When a debug session is active, surface its state on the right
        side of the status bar (sharing space with the LSP indicator —
        whichever was set most recently wins, which is fine since both
        are ambient state and they never matter at exactly the same
        instant)."""
        if self.dap.is_active() or self.dap.is_failed():
            var attr = Attr(BLACK, LIGHT_GRAY)
            if self.dap.is_failed():
                attr = Attr(LIGHT_RED, LIGHT_GRAY)
            elif self.dap.is_stopped():
                attr = Attr(YELLOW, LIGHT_GRAY)
            self.status_bar.set_message(self.dap.status_summary(), attr)

    fn _debug_open_condition_prompt(mut self):
        """Shift+F9: prompt for a breakpoint condition on the focused
        editor's cursor row. Pre-fills with any existing condition so
        users can edit rather than re-type. Path + line are stashed in
        ``_pending_arg`` as ``path|line`` so the submit handler can
        recover them."""
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: file has no path — save it first"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var line = self.windows.windows[idx].editor.cursor_row
        self._pending_arg = path + String("|") + String(line)
        self._pending_action = _PA_BP_CONDITION
        var existing = self.dap.breakpoint_condition(path, line)
        var label = String("Break when (line ") + String(line + 1) + String("): ")
        self.prompt.open(label, existing)

    fn _toggle_raised_exceptions(mut self):
        """Add or remove the ``raised`` exception filter. The
        ``uncaught`` filter is left as-is — that's the always-on
        default, while ``raised`` is the noisier opt-in."""
        var current = self.dap.exception_filters()
        var has_raised = False
        for k in range(len(current)):
            if current[k] == String("raised"):
                has_raised = True
                break
        var new_filters = List[String]()
        for k in range(len(current)):
            if current[k] != String("raised"):
                new_filters.append(current[k])
        if not has_raised:
            new_filters.append(String("raised"))
        self.dap.set_exception_filters(new_filters^)

    fn _debug_toggle_breakpoint(mut self):
        """F9: toggle a breakpoint at the focused editor's cursor row.

        Local list mutates immediately; the manager will resend the
        ``setBreakpoints`` payload to the adapter on the next eligible
        state. No-op when nothing is focused / the focused window isn't
        an editor with a backing file.
        """
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: file has no path — save it first"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var line = self.windows.windows[idx].editor.cursor_row
        self.dap.toggle_breakpoint(path, line)

    fn _debug_start_or_continue(mut self):
        """F5: start a session if none is active, otherwise resume.

        Picks the debugger spec from the focused editor's file
        extension → language id → registry. If no debugger is registered
        for that language (or the binary isn't on $PATH), surfaces a
        descriptive status message rather than failing silently.
        """
        if self.dap.is_running():
            return  # already running, nothing to do
        if self.dap.is_stopped():
            _ = self.dap.cont()
            return
        if self.dap.is_active():
            return  # mid-handshake, ignore
        # Fresh start. Need: program path + language → spec.
        var idx = self._focused_editor_idx()
        if idx < 0:
            self.status_bar.set_message(
                String("debug: focus a source file first"),
                Attr(YELLOW, LIGHT_GRAY),
            )
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("debug: save the file first"),
                Attr(YELLOW, LIGHT_GRAY),
            )
            return
        var ext = extension_of(path)
        var lang_idx = find_language_for_extension(self.lsp_specs, ext)
        if lang_idx < 0:
            self.status_bar.set_message(
                String("debug: unknown language for ") + ext,
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var lang_id = self.lsp_specs[lang_idx].language_id
        var deb_idx = find_debugger_for_language(self.dap_specs, lang_id)
        if deb_idx < 0:
            self.status_bar.set_message(
                String("debug: no adapter registered for ")
                + lang_id,
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        # If the manager is already TERMINATED / FAILED from a prior
        # session, return it to NOT_STARTED so ``start`` will run.
        # ``reset_for_restart`` is preferred over replacing ``self.dap``
        # because it preserves the user's breakpoints + exception
        # filter selection — wholesale replacement would silently drop
        # both, so the second F5 would launch with no breakpoints set
        # and the program would run straight through.
        if self.dap.is_failed() or self.dap.is_terminated():
            self.dap.reset_for_restart()
        var cwd = self.project.value() if self.project else String(".")
        self.dap.start(
            self.dap_specs[deb_idx], path, cwd, List[String](),
        )
        # Surface the resolved spawn line to the pane log immediately.
        # Pre-stderr-drain debugging this was guesswork ("did it pick
        # debugpy-adapter or python -m debugpy.adapter?"); a single
        # console-category line removes the ambiguity. Also visible
        # before the first event arrives, which matters when the
        # adapter crashes silently.
        if len(self.dap.spawn_argv) > 0:
            var line = String("$ ")
            for k in range(len(self.dap.spawn_argv)):
                if k > 0:
                    line = line + String(" ")
                line = line + self.dap.spawn_argv[k]
            self.debug_pane.append_output(line, UInt8(2))   # PANE_OUT_CONSOLE
            self.debug_pane.visible = True

    fn _jump_to(mut self, target: DefinitionResolved, screen: Rect):
        """Focus the window for ``target.path`` (opening it if needed) and
        move the cursor to ``(line, character)``."""
        var existing = self._find_window_for_path(target.path)
        if existing < 0:
            try:
                self.open_file(target.path, screen)
            except:
                return
            existing = len(self.windows.windows) - 1
        else:
            self.windows.focus_by_index(existing)
        if existing < 0 or existing >= len(self.windows.windows):
            return
        if not self.windows.windows[existing].is_editor:
            return
        self.windows.windows[existing].editor.move_to(
            target.line, target.character, False, True,
        )
        self.windows.windows[existing].editor.reveal_cursor(
            self.windows.windows[existing].interior(),
        )

    fn _find_window_for_path(self, path: String) -> Int:
        """Return the index of an existing editor window whose file_path
        matches ``path`` (raw or canonicalized), or -1."""
        var canon = realpath(path)
        for i in range(len(self.windows.windows)):
            if not self.windows.windows[i].is_editor:
                continue
            var fp = self.windows.windows[i].editor.file_path
            if fp == path:
                return i
            if len(canon.as_bytes()) > 0 and realpath(fp) == canon:
                return i
        return -1

    # --- editor-action helpers --------------------------------------------

    fn _focused_editor_idx(self) -> Int:
        if self.windows.focused < 0 or self.windows.focused >= len(self.windows.windows):
            return -1
        if not self.windows.windows[self.windows.focused].is_editor:
            return -1
        return self.windows.focused

    fn _do_save(mut self):
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var has_path = len(self.windows.windows[idx].editor.file_path.as_bytes()) > 0
        if has_path:
            try:
                _ = self.windows.windows[idx].editor.save()
            except:
                pass
            return
        # No backing file — escalate to Save As.
        self._open_save_as_dialog()

    fn _open_symbol_pick(mut self):
        """Open the Go-to-Symbol picker for the focused editor and kick
        off a ``textDocument/documentSymbol`` request to its language
        server. Picker shows "Loading…" until the response lands."""
        var idx = self._focused_editor_idx()
        if idx < 0:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            self.status_bar.set_message(
                String("LSP: file has no path"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        var lsp_idx = self._lsp_for_path(path)
        if lsp_idx < 0:
            self.status_bar.set_message(
                String("LSP: not started for this file type"),
                Attr(RED, LIGHT_GRAY),
            )
            return
        if self.lsp_managers[lsp_idx].is_failed():
            return
        if not self.lsp_managers[lsp_idx].is_ready():
            self.status_bar.set_message(
                String("LSP: still starting up — try again"),
                Attr(YELLOW, LIGHT_GRAY),
            )
            return
        var text = self.windows.windows[idx].editor.text_snapshot()
        var ok = self.lsp_managers[lsp_idx].request_document_symbols(
            path, text^,
        )
        if ok:
            self.symbol_pick.open(path)

    fn _open_save_as_dialog(mut self):
        """Open the modal save-as picker, seeded from the focused editor's
        current path (or the project root for an untitled buffer). The
        dialog reuses ``DirBrowser`` for the folder listing — see
        ``SaveAsDialog`` for the keyboard model.
        """
        var idx = self._focused_editor_idx()
        var seed = String("")
        if idx >= 0:
            seed = self.windows.windows[idx].editor.file_path
        if len(seed.as_bytes()) == 0 and self.project:
            seed = self.project.value()
        self.save_as_dialog.open(seed^)

    fn _on_prompt_submit(mut self) -> Optional[String]:
        var text = self.prompt.input
        self.prompt.close()
        var pa = self._pending_action
        self._pending_action = String("")
        if pa == EDITOR_FIND:
            var idx = self._focused_editor_idx()
            if idx >= 0:
                _ = self.windows.windows[idx].editor.find_next(text)
            return Optional[String]()
        if pa == EDITOR_GOTO:
            var idx = self._focused_editor_idx()
            if idx >= 0:
                var n = 0
                if len(text.as_bytes()) > 0:
                    try:
                        n = Int(atol(text))
                    except:
                        n = 0
                self.windows.windows[idx].editor.goto_line(n)
            return Optional[String]()
        if pa == _PA_REPLACE_FIND:
            self._pending_arg = text
            self._pending_action = _PA_REPLACE_DO
            self.prompt.open(String("Replace with: "))
            return Optional[String]()
        if pa == _PA_REPLACE_DO:
            var find = self._pending_arg
            self._pending_arg = String("")
            var idx = self._focused_editor_idx()
            if idx >= 0:
                _ = self.windows.windows[idx].editor.replace_all(find, text)
            return Optional[String]()
        if pa == _PA_PROJECT_REPLACE_FIND:
            self._pending_arg = text
            self._pending_action = _PA_PROJECT_REPLACE_DO
            self.prompt.open(String("Replace in project with: "))
            return Optional[String]()
        if pa == _PA_PROJECT_REPLACE_DO:
            var find = self._pending_arg
            self._pending_arg = String("")
            if self.project:
                try:
                    var summary = replace_in_project(
                        self.project.value(), find, text,
                    )
                    self.windows.add(_summary_window(
                        find, text, summary[0], summary[1],
                    ))
                except:
                    pass
            return Optional[String]()
        if pa == _PA_BP_CONDITION:
            # ``_pending_arg`` carries ``path|line`` from when the
            # prompt was opened. Empty input clears any existing
            # condition (the breakpoint stays).
            var arg = self._pending_arg
            self._pending_arg = String("")
            var sep = -1
            var ab = arg.as_bytes()
            for k in range(len(ab)):
                if ab[k] == 0x7C:  # '|'
                    sep = k
                    break
            if sep > 0:
                var path = String(StringSlice(
                    ptr=ab.unsafe_ptr(), length=sep,
                ))
                var line_str = String(StringSlice(
                    ptr=ab.unsafe_ptr() + sep + 1, length=len(ab) - sep - 1,
                ))
                var line = 0
                try:
                    line = Int(atol(line_str))
                except:
                    pass
                self.dap.set_breakpoint_condition(path, line, text)
            return Optional[String]()
        if pa == _PA_ADD_WATCH:
            if len(text.as_bytes()) > 0:
                self.add_watch(text)
            return Optional[String]()
        return Optional[String]()


# --- Small helpers ----------------------------------------------------------


fn _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


fn _category_to_pane(category: String) -> UInt8:
    """Map a DAP ``output`` event's category string to the pane's
    output-attr enum. ``stderr`` lights the row red; ``console`` (and
    ``important``) get a dim color so the user can tell adapter chatter
    apart from program output. Anything unknown defaults to stdout."""
    if category == String("stderr"):
        return UInt8(1)   # PANE_OUT_STDERR
    if category == String("console") or category == String("important"):
        return UInt8(2)   # PANE_OUT_CONSOLE
    return UInt8(0)       # PANE_OUT_STDOUT


fn _same_file(a: String, b: String) -> Bool:
    """True if ``a`` and ``b`` resolve to the same on-disk file. Used to
    match a DAP stack-frame source path against editor file paths even
    when one is a symlink and the other is canonical."""
    if a == b:
        return True
    if len(a.as_bytes()) == 0 or len(b.as_bytes()) == 0:
        return False
    var ra = realpath(a)
    var rb = realpath(b)
    return len(ra.as_bytes()) > 0 and ra == rb


fn _parse_int(s: String, start: Int) -> Int:
    """Parse decimal digits from ``start`` onward; ``-1`` if no digits."""
    var sb = s.as_bytes()
    var i = start
    var n = 0
    var any = False
    while i < len(sb) and sb[i] >= 0x30 and sb[i] <= 0x39:
        n = n * 10 + Int(sb[i]) - 0x30
        any = True
        i += 1
    if not any:
        return -1
    return n


fn _mojo_include_dirs(root: String) -> List[String]:
    """``-I`` paths for ``mojo-lsp-server``: the project root, plus
    ``<root>/src`` if it exists.

    Without these the server can resolve ``from sys import ...`` but not
    ``from <project> import ...`` — every Cmd+click on a project symbol
    comes back empty. The ``src/`` subdirectory is a near-universal Mojo
    project convention (matches ``mojo run -I src ...`` in this repo's
    own ``run.sh``); covering it plus the root keeps both flat and
    src-style layouts working without any per-project configuration.
    """
    var dirs = List[String]()
    if len(root.as_bytes()) == 0:
        return dirs^
    dirs.append(root)
    var src = join_path(root, String("src"))
    var info = stat_file(src)
    if info.ok and info.is_dir():
        dirs.append(src)
    return dirs^


# --- Result / summary windows for project search ----------------------------


fn _refresh_status_for(
    mut sb: StatusBar, prefix: String, m: LspManager,
):
    """Free function so the caller can pass ``self.status_bar`` and one
    of ``self.lsp_*`` without tripping Mojo's exclusivity check (a
    method receiver implicitly aliases the whole struct, which conflicts
    with passing one of its fields as a separate argument)."""
    if m.is_failed():
        sb.set_message(
            prefix + m.failure_reason,
            Attr(LIGHT_RED, LIGHT_GRAY),
        )
        return
    if m.is_initializing():
        sb.set_message(
            prefix + String("starting..."),
            Attr(YELLOW, LIGHT_GRAY),
        )
        return
    if m.is_ready():
        var word = m.inflight_word()
        if len(word.as_bytes()) > 0:
            sb.set_message(
                prefix + String("looking up ") + word + String("..."),
                Attr(BLACK, LIGHT_GRAY),
            )
            return
        if m.last_empty():
            sb.set_message(
                prefix + String("no definition found"),
                Attr(LIGHT_RED, LIGHT_GRAY),
            )
            return
        sb.set_message(
            prefix + String("ready"),
            Attr(BLACK, LIGHT_GRAY),
        )


fn _summary_window(
    find: String, replace: String, files_changed: Int, total: Int,
) -> Window:
    var content = List[String]()
    content.append(String("Find:    ") + find)
    content.append(String("Replace: ") + replace)
    content.append(String(""))
    content.append(
        String("Replaced ") + String(total)
        + String(" occurrence(s) in ")
        + String(files_changed) + String(" file(s)."),
    )
    return Window(String("Replace in project"), Rect(10, 6, 64, 14), content^)
