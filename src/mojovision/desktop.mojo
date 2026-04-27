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
from .colors import Attr, BLUE, LIGHT_GRAY
from .events import Event, EVENT_KEY, EVENT_MOUSE, KEY_ESC, MOUSE_BUTTON_LEFT
from .file_io import basename, find_git_project
from .file_tree import FileTree
from .geometry import Rect
from .menu import Menu, MenuBar, MenuItem
from .project import ProjectMatch, find_in_project, replace_in_project
from .prompt import Prompt
from .status import StatusBar
from .window import Window, WindowManager


# --- Public action strings --------------------------------------------------
# The Desktop intercepts these; menu items wired to them work without any
# additional code on the application side.

comptime EDITOR_SAVE          = String("file:save")
comptime EDITOR_SAVE_AS       = String("file:save_as")
comptime EDITOR_FIND          = String("edit:find")
comptime EDITOR_REPLACE       = String("edit:replace")
comptime EDITOR_GOTO          = String("edit:goto")
comptime EDITOR_TOGGLE_COMMENT = String("edit:comment")
comptime EDITOR_TOGGLE_CASE   = String("edit:case")
comptime PROJECT_FIND         = String("edit:project_find")
comptime PROJECT_REPLACE      = String("edit:project_replace")
comptime PROJECT_CLOSE_ACTION = String("project:close")
comptime PROJECT_TREE_ACTION  = String("project:tree:toggle")

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


struct Desktop(Movable):
    var menu_bar: MenuBar
    var windows: WindowManager
    var status_bar: StatusBar
    var file_tree: FileTree
    var prompt: Prompt
    var bg_pattern: String
    var bg_attr: Attr
    var project: Optional[String]
    var _project_menu_idx: Int       # index into menu_bar.menus, or -1
    var _pending_action: String      # what to do on next prompt submit
    var _pending_arg: String         # accumulator for two-step prompts

    fn __init__(out self):
        self.menu_bar = MenuBar()
        self.windows = WindowManager()
        self.status_bar = StatusBar()
        self.file_tree = FileTree()
        self.prompt = Prompt()
        self.bg_pattern = String("▒")
        self.bg_attr = Attr(LIGHT_GRAY, BLUE)
        self.project = Optional[String]()
        self._project_menu_idx = -1
        self._pending_action = String("")
        self._pending_arg = String("")

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
        # Refit windows to the current workspace before painting. Cheap
        # (idempotent for already-fitting windows) and covers both file
        # tree toggles and terminal resizes uniformly.
        self.windows.fit_into(self.workspace_rect(screen))
        canvas.fill(self.workspace_rect(screen), self.bg_pattern, self.bg_attr)
        self.windows.paint(canvas)
        self.file_tree.paint(canvas, screen)
        self.menu_bar.paint(canvas, screen)
        self.status_bar.paint(canvas, screen)
        # Modal prompt floats above everything else.
        self.prompt.paint(canvas, screen)

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
        all editor / project actions internally. ESC at the top level (no
        menu / no prompt) returns ``APP_QUIT_ACTION`` so the app can choose
        whether to actually quit. Anything else the Desktop doesn't claim
        is returned verbatim for the caller to dispatch.
        """
        if self.prompt.active:
            if event.kind == EVENT_KEY:
                _ = self.prompt.handle_key(event)
                if self.prompt.submitted:
                    return self._on_prompt_submit()
            return Optional[String]()
        if event.kind == EVENT_KEY:
            return self._handle_key(event)
        # Mouse events (and everything else): route through menu → tree → windows.
        var result = self.menu_bar.handle_event(event, screen.b.x)
        if result.action:
            return self.dispatch_action(result.action.value())
        if result.consumed:
            return Optional[String]()
        if self.file_tree.handle_mouse(event, screen):
            return Optional[String]()
        _ = self.windows.handle_mouse(event, self.workspace_rect(screen))
        return Optional[String]()

    fn _handle_key(mut self, event: Event) -> Optional[String]:
        if event.key == KEY_ESC:
            if self.menu_bar.is_open():
                self.menu_bar.close()
                return Optional[String]()
            return Optional[String](APP_QUIT_ACTION)
        _ = self.windows.handle_key(event)
        return Optional[String]()

    fn dispatch_action(mut self, action: String) -> Optional[String]:
        """Execute a framework-recognized action; pass anything else back.

        Apps can call this to bind keyboard shortcuts to action strings
        without going through the menu bar.
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
                self._pending_action = PROJECT_FIND
                self.prompt.open(String("Find in project: "))
            return Optional[String]()
        if action == PROJECT_REPLACE:
            if self.project:
                self._pending_action = _PA_PROJECT_REPLACE_FIND
                self.prompt.open(String("Replace in project — find: "))
            return Optional[String]()
        return Optional[String](action)

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
        if pa == PROJECT_FIND:
            if self.project:
                try:
                    var matches = find_in_project(self.project.value(), text)
                    self.windows.add(_results_window(
                        String("Find: ") + text, matches,
                    ))
                except:
                    pass
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


# --- Result / summary windows for project search ----------------------------


fn _results_window(
    var title: String, matches: List[ProjectMatch],
) -> Window:
    var content = List[String]()
    if len(matches) == 0:
        content.append(String("(no matches)"))
    else:
        for i in range(len(matches)):
            content.append(
                matches[i].rel + String(":") + String(matches[i].line_no)
                + String(": ") + matches[i].line_text,
            )
    return Window(title^, Rect(8, 5, 76, 22), content^)


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
