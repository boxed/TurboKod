"""Desktop: combines menu bar, window manager, status bar, and a hatched background.

The high-level entry point most apps will use. Construct one ``Desktop``, add
menus / windows / status items, then in the loop:

    desktop.paint(app.back, app.screen())
    var ev = app.next_event(50)
    if ev:
        var action = desktop.handle_event(ev.value(), app.screen())
        if action:
            ... dispatch action ...

The Desktop owns event routing: menu bar gets first dibs (clicks on the top row
or in an open dropdown), and otherwise the event flows to the window manager.

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
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .file_io import basename, find_git_project
from .geometry import Rect
from .menu import Menu, MenuBar, MenuItem
from .status import StatusBar
from .window import WindowManager


comptime PROJECT_CLOSE_ACTION = String("project:close")


struct Desktop(Movable):
    var menu_bar: MenuBar
    var windows: WindowManager
    var status_bar: StatusBar
    var bg_pattern: String
    var bg_attr: Attr
    var project: Optional[String]
    var _project_menu_idx: Int       # index into menu_bar.menus, or -1

    fn __init__(out self):
        self.menu_bar = MenuBar()
        self.windows = WindowManager()
        self.status_bar = StatusBar()
        self.bg_pattern = String("▒")
        self.bg_attr = Attr(LIGHT_GRAY, BLUE)
        self.project = Optional[String]()
        self._project_menu_idx = -1

    fn workspace_rect(self, screen: Rect) -> Rect:
        return Rect(0, 1, screen.b.x, screen.b.y - 1)

    fn paint(self, mut canvas: Canvas, screen: Rect):
        canvas.fill(self.workspace_rect(screen), self.bg_pattern, self.bg_attr)
        self.windows.paint(canvas)
        self.menu_bar.paint(canvas, screen)
        self.status_bar.paint(canvas, screen)

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
        if self._project_menu_idx >= 0:
            self.menu_bar.menus[self._project_menu_idx].visible = False
            if self.menu_bar.open_idx == self._project_menu_idx:
                self.menu_bar.open_idx = -1

    fn _set_project(mut self, path: String):
        self.project = Optional[String](path)
        var label = basename(path)
        if self._project_menu_idx < 0:
            var items = List[MenuItem]()
            items.append(MenuItem(String("Close project"), PROJECT_CLOSE_ACTION))
            self.menu_bar.add(Menu(label, items^, right_aligned=True))
            self._project_menu_idx = len(self.menu_bar.menus) - 1
        else:
            self.menu_bar.menus[self._project_menu_idx].label = label
            self.menu_bar.menus[self._project_menu_idx].visible = True

    # --- events ------------------------------------------------------------

    fn handle_event(mut self, event: Event, screen: Rect) -> Optional[String]:
        """Returns the action string of any clicked menu item.

        ``project:close`` is intercepted here — the desktop owns project
        state, so the app loop doesn't need to handle it.
        """
        var result = self.menu_bar.handle_event(event, screen.b.x)
        if result.action:
            var action = result.action.value()
            if action == PROJECT_CLOSE_ACTION:
                self.close_project()
                return Optional[String]()
            return result.action
        if result.consumed:
            return Optional[String]()
        _ = self.windows.handle_mouse(event, self.workspace_rect(screen))
        return Optional[String]()
