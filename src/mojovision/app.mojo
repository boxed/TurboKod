"""Application: owns the terminal, runs the paint/poll/handle loop.

Idiomatic usage::

    var app = Application()
    app.start()
    try:
        while app.running:
            app.clear()
            # paint widgets into app.back ...
            app.present()
            var ev = app.next_event(50)
            if ev:
                # dispatch ...
    finally:
        app.stop()

`Application` doesn't impose a widget hierarchy — it just owns the terminal
and a back canvas, and lets the caller decide how to paint and dispatch.
This is significantly less prescriptive than C++ TurboVision's `TApplication`,
which is the root of the entire view tree.
"""

from std.collections import Optional

from .canvas import Canvas
from .colors import default_attr
from .events import Event, EVENT_KEY, EVENT_QUIT, KEY_ESC
from .geometry import Rect
from .terminal import Terminal


struct Application:
    var terminal: Terminal
    var back: Canvas
    var running: Bool

    fn __init__(out self) raises:
        self.terminal = Terminal()
        self.back = Canvas(self.terminal.width, self.terminal.height)
        self.running = True

    fn start(mut self) raises:
        self.terminal.start()
        # Terminal.start() may discover a more accurate size via the cursor
        # query that runs after raw mode is on. Sync the back canvas.
        if self.back.width != self.terminal.width or self.back.height != self.terminal.height:
            self.back.resize(self.terminal.width, self.terminal.height)

    fn stop(mut self) raises:
        self.terminal.stop()

    fn screen(self) -> Rect:
        return Rect(0, 0, self.back.width, self.back.height)

    fn quit(mut self):
        self.running = False

    fn clear(mut self):
        self.back.clear(default_attr())

    fn present(mut self) raises:
        self.terminal.present(self.back)

    fn next_event(mut self, timeout_ms: Int = 50) raises -> Optional[Event]:
        if self.terminal.refresh_size():
            self.back.resize(self.terminal.width, self.terminal.height)
            return Event.resize_event(self.terminal.width, self.terminal.height)
        return self.terminal.poll_event(timeout_ms)
