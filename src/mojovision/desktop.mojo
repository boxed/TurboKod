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
"""

from std.collections.optional import Optional

from .canvas import Canvas
from .colors import Attr, BLUE, LIGHT_GRAY
from .events import Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT
from .geometry import Rect
from .menu import MenuBar
from .status import StatusBar
from .window import WindowManager


struct Desktop(Movable):
    var menu_bar: MenuBar
    var windows: WindowManager
    var status_bar: StatusBar
    var bg_pattern: String
    var bg_attr: Attr

    fn __init__(out self):
        self.menu_bar = MenuBar()
        self.windows = WindowManager()
        self.status_bar = StatusBar()
        self.bg_pattern = String("▒")
        self.bg_attr = Attr(LIGHT_GRAY, BLUE)

    fn workspace_rect(self, screen: Rect) -> Rect:
        return Rect(0, 1, screen.b.x, screen.b.y - 1)

    fn paint(self, mut canvas: Canvas, screen: Rect):
        canvas.fill(self.workspace_rect(screen), self.bg_pattern, self.bg_attr)
        self.windows.paint(canvas)
        self.menu_bar.paint(canvas, screen)
        self.status_bar.paint(canvas, screen)

    fn handle_event(mut self, event: Event, screen: Rect) -> Optional[String]:
        """Returns the action string of any clicked menu item."""
        var result = self.menu_bar.handle_event(event)
        if result.action:
            return result.action
        if result.consumed:
            return Optional[String]()
        _ = self.windows.handle_mouse(event, self.workspace_rect(screen))
        return Optional[String]()
