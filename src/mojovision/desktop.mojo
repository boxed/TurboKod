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
from .lsp_dispatch import DefinitionResolved, LspManager
from .menu import Menu, MenuBar, MenuItem
from .posix import monotonic_ms
from .project import replace_in_project
from .project_find import ProjectFind
from .prompt import Prompt
from .quick_open import QuickOpen
from .status import StatusBar
from .symbol_pick import SymbolPick
from .window import MIN_WIN_H, MIN_WIN_W, Window, WindowManager


# --- Public action strings --------------------------------------------------
# The Desktop intercepts these; menu items wired to them work without any
# additional code on the application side.

comptime EDITOR_SAVE          = String("file:save")
comptime EDITOR_SAVE_AS       = String("file:save_as")
comptime EDITOR_QUICK_OPEN    = String("file:quick_open")
comptime EDITOR_FIND          = String("edit:find")
comptime EDITOR_REPLACE       = String("edit:replace")
comptime EDITOR_GOTO          = String("edit:goto")
comptime EDITOR_GOTO_SYMBOL   = String("edit:goto_symbol")
comptime EDITOR_TOGGLE_COMMENT = String("edit:comment")
comptime EDITOR_TOGGLE_CASE   = String("edit:case")
comptime PROJECT_FIND         = String("edit:project_find")
comptime PROJECT_REPLACE      = String("edit:project_replace")
comptime PROJECT_CLOSE_ACTION = String("project:close")
comptime PROJECT_TREE_ACTION  = String("project:tree:toggle")
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
comptime _PA_SAVE_AS             = String("__pa_save_as")


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
    var _hotkeys: List[Hotkey]       # global key bindings, scanned in order
    var _esc_armed: Bool             # next keystroke is Alt+<letter> (mnemonic)
    # One ``LspManager`` per language id. Spawned lazily by
    # ``_ensure_lsp_for_extension`` when a file of that type is first
    # opened — there's no LSP cost for users who never touch one.
    # Separate fields rather than ``List[LspManager]`` because Mojo's
    # ``List`` requires ``Copyable`` and managers own non-copyable
    # process / pipe state.
    var lsp_mojo: LspManager
    var lsp_python: LspManager

    fn __init__(out self):
        self.menu_bar = MenuBar()
        self.windows = WindowManager()
        self.status_bar = StatusBar()
        self.file_tree = FileTree()
        self.prompt = Prompt()
        self.quick_open = QuickOpen()
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
        self._hotkeys = List[Hotkey]()
        self._esc_armed = False
        self.lsp_mojo = LspManager()
        self.lsp_python = LspManager()
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
        self._hotkeys.append(Hotkey(ctrl_key("o"), MOD_NONE, EDITOR_QUICK_OPEN))
        self._hotkeys.append(Hotkey(ctrl_key("s"), MOD_NONE, EDITOR_SAVE))
        self._hotkeys.append(Hotkey(ctrl_key("f"), MOD_NONE, EDITOR_FIND))
        self._hotkeys.append(Hotkey(ctrl_key("r"), MOD_NONE, EDITOR_REPLACE))
        self._hotkeys.append(Hotkey(ctrl_key("g"), MOD_NONE, EDITOR_GOTO))
        self._hotkeys.append(Hotkey(ctrl_key("t"), MOD_NONE, EDITOR_GOTO_SYMBOL))
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

    fn workspace_rect(self, screen: Rect) -> Rect:
        """Floating-window area: between menu bar, status bar, and any docked
        widgets. The file tree, when visible, eats space on the right."""
        var right = screen.b.x
        if self.file_tree.visible:
            right -= self.file_tree.width
            if right < 0:
                right = 0
        return Rect(0, 1, right, screen.b.y - 1)

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
        self.menu_bar.paint(canvas, screen)
        self.status_bar.paint(canvas, screen)
        # Modal layers float above everything else. Only one is ever active
        # at a time (open_quick_open won't fire while a prompt is up, etc.),
        # so paint order doesn't matter for correctness.
        self.prompt.paint(canvas, screen)
        self.quick_open.paint(canvas, screen)
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
        """
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

    fn _maybe_lsp_open(mut self, idx: Int):
        """If the window at ``idx`` is an editor for a recognized source
        file type, ensure the matching LSP server is started and inform
        it of this document. Languages without an installed server are
        a silent no-op (e.g. ``.py`` files when the user has neither
        pyright nor pylsp on PATH)."""
        if idx < 0 or idx >= len(self.windows.windows):
            return
        if not self.windows.windows[idx].is_editor:
            return
        var path = self.windows.windows[idx].editor.file_path
        if len(path.as_bytes()) == 0:
            return
        var lang = self._ensure_lsp_for_extension(extension_of(path))
        if lang == String(""):
            return
        var text = self.windows.windows[idx].editor.text_snapshot()
        if lang == String("mojo"):
            self.lsp_mojo.notify_opened(path, text^)
        elif lang == String("python"):
            self.lsp_python.notify_opened(path, text^)

    fn _lang_for_extension(self, ext: String) -> String:
        """Map a file extension to the language id its LSP manager (if
        any) registers under. Returns "" for languages we don't support."""
        if ext == String("mojo") or ext == String("🔥"):
            return String("mojo")
        if ext == String("py") or ext == String("pyi"):
            return String("python")
        return String("")

    fn _ensure_lsp_for_extension(mut self, ext: String) -> String:
        """Spawn the matching server on first use and return its language
        id. Returns "" for unsupported file types or when no server
        binary is installed (so the caller can quietly skip LSP wiring
        for that file). Idempotent — re-calling for an already-spawned
        language is a no-op.
        """
        var lang = self._lang_for_extension(ext)
        if lang == String(""):
            return String("")
        var root = String("")
        if self.project:
            root = self.project.value()
        if lang == String("mojo"):
            if self.lsp_mojo.is_not_started():
                self.lsp_mojo.start_mojo(root, _mojo_include_dirs(root))
            return lang
        if lang == String("python"):
            if self.lsp_python.is_not_started():
                if not self.lsp_python.start_python(root):
                    # No Python LSP on PATH; report that to the caller
                    # as "not supported" so we don't fake a starting state.
                    return String("")
            return lang
        return String("")

    fn _lsp_lang_for_path(self, path: String) -> String:
        """Language id of the spawned server handling ``path``, or "" if
        no server has been spawned for that file's extension."""
        if len(path.as_bytes()) == 0:
            return String("")
        var lang = self._lang_for_extension(extension_of(path))
        if lang == String("mojo") and not self.lsp_mojo.is_not_started():
            return lang
        if lang == String("python") and not self.lsp_python.is_not_started():
            return lang
        return String("")

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
            return self._handle_key(event, screen)
        # Mouse events (and everything else): route through menu → tree → windows.
        var result = self.menu_bar.handle_event(event, screen.b.x)
        if result.action:
            return self.dispatch_action(result.action.value(), screen)
        if result.consumed:
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
        if action == EDITOR_SAVE:
            self._do_save()
            return Optional[String]()
        if action == EDITOR_SAVE_AS:
            self._open_save_as_prompt()
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
        # focused. Each branch is independent — Mojo's auto-destructor
        # handles the partial-move pattern around ``take_symbols``.
        if not self.lsp_mojo.is_not_started():
            var resolved = self.lsp_mojo.tick()
            if resolved:
                self._jump_to(resolved.value(), screen)
            if self.symbol_pick.active and self.symbol_pick.loading \
                    and self.lsp_mojo.has_pending_symbols():
                self.symbol_pick.set_entries(self.lsp_mojo.take_symbols())
        if not self.lsp_python.is_not_started():
            var resolved = self.lsp_python.tick()
            if resolved:
                self._jump_to(resolved.value(), screen)
            if self.symbol_pick.active and self.symbol_pick.loading \
                    and self.lsp_python.has_pending_symbols():
                self.symbol_pick.set_entries(self.lsp_python.take_symbols())
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
        var lang = self._lsp_lang_for_path(path)
        if lang == String(""):
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
        var ok = False
        if lang == String("mojo"):
            if self.lsp_mojo.is_failed():
                return
            if not self.lsp_mojo.is_active():
                self.status_bar.set_message(
                    String("LSP: not started for this file type"),
                    Attr(RED, LIGHT_GRAY),
                )
                return
            ok = self.lsp_mojo.request_definition(
                path, row, col, word^, text^,
            )
        elif lang == String("python"):
            if self.lsp_python.is_failed():
                return
            if not self.lsp_python.is_active():
                self.status_bar.set_message(
                    String("LSP: not started for this file type"),
                    Attr(RED, LIGHT_GRAY),
                )
                return
            ok = self.lsp_python.request_definition(
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
        var lang = self._lsp_lang_for_path(path)
        if lang == String(""):
            return
        var prefix = String("LSP[") + lang + String("]: ")
        if lang == String("mojo"):
            _refresh_status_for(self.status_bar, prefix, self.lsp_mojo)
        elif lang == String("python"):
            _refresh_status_for(self.status_bar, prefix, self.lsp_python)

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
        self._open_save_as_prompt()

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
        var lang = self._lsp_lang_for_path(path)
        if lang == String(""):
            self.status_bar.set_message(
                String("LSP: not started for this file type"),
                Attr(RED, LIGHT_GRAY),
            )
            return
        var text = self.windows.windows[idx].editor.text_snapshot()
        var ok = False
        if lang == String("mojo"):
            if self.lsp_mojo.is_failed():
                return
            if not self.lsp_mojo.is_ready():
                self.status_bar.set_message(
                    String("LSP: still starting up — try again"),
                    Attr(YELLOW, LIGHT_GRAY),
                )
                return
            ok = self.lsp_mojo.request_document_symbols(path, text^)
        elif lang == String("python"):
            if self.lsp_python.is_failed():
                return
            if not self.lsp_python.is_ready():
                self.status_bar.set_message(
                    String("LSP: still starting up — try again"),
                    Attr(YELLOW, LIGHT_GRAY),
                )
                return
            ok = self.lsp_python.request_document_symbols(path, text^)
        if ok:
            self.symbol_pick.open(path)

    fn _open_save_as_prompt(mut self):
        var idx = self._focused_editor_idx()
        var prefill = String("")
        if idx >= 0:
            prefill = self.windows.windows[idx].editor.file_path
        self._pending_action = _PA_SAVE_AS
        self.prompt.open(String("Save as: "), prefill)

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
        if pa == _PA_SAVE_AS:
            var idx = self._focused_editor_idx()
            if idx >= 0:
                try:
                    _ = self.windows.windows[idx].editor.save_as(text)
                except:
                    pass
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
