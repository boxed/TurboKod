"""Status bar with classic F-key shortcut display, plus a row of
tabs for the project's run/debug targets.

Layout (left to right): F-key shortcuts, then target tabs, then the
right-aligned diagnostic message. Tabs sit in the middle so they
remain visible on every project — even with a long LSP indicator on
the right and several shortcuts on the left, only the message gets
clipped first."""

from std.collections.list import List

from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, RED, WHITE, YELLOW
from .events import (
    Event, EVENT_MOUSE, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect


@fieldwise_init
struct StatusItem(ImplicitlyCopyable, Movable):
    var key: String
    var desc: String


@fieldwise_init
struct StatusTab(ImplicitlyCopyable, Movable):
    """One target tab. ``running`` and ``debugging`` flag the tab so
    the user gets a visible indicator that something is in flight for
    *this* target — different from "this is the active tab"."""
    var label: String
    var running: Bool
    var debugging: Bool


@fieldwise_init
struct _TabHit(ImplicitlyCopyable, Movable):
    """Cached hit-rect for one painted tab, captured during ``paint``
    so a subsequent click can route to the right tab without us
    re-deriving the layout. ``a_x`` / ``b_x`` are the inclusive /
    exclusive column bounds of the tab's painted glyphs."""
    var a_x: Int
    var b_x: Int
    var index: Int


struct StatusBar(Movable):
    var items: List[StatusItem]
    var tabs: List[StatusTab]
    var active_tab: Int          # index into ``tabs``, or -1
    var message: String          # right-aligned diagnostic / status text
    var message_attr: Attr       # color for the diagnostic; default = subtle
    var _tab_hits: List[_TabHit] # captured by ``paint`` for ``hit_test``

    fn __init__(out self):
        self.items = List[StatusItem]()
        self.tabs = List[StatusTab]()
        self.active_tab = -1
        self.message = String("")
        self.message_attr = Attr(BLACK, LIGHT_GRAY)
        self._tab_hits = List[_TabHit]()

    fn add(mut self, var key: String, var desc: String):
        self.items.append(StatusItem(key^, desc^))

    fn set_message(mut self, var text: String, attr: Attr):
        """Set the right-aligned status text (LSP state, errors, etc.)."""
        self.message = text^
        self.message_attr = attr

    fn set_tabs(
        mut self, var tabs: List[StatusTab], active_tab: Int,
    ):
        """Replace the target-tab strip. ``active_tab`` is the index
        of the user's currently selected target, or -1 when there is
        none. Out-of-range values are silently clamped to -1 so a
        caller can pass through an unvalidated index."""
        self.tabs = tabs^
        if active_tab < 0 or active_tab >= len(self.tabs):
            self.active_tab = -1
        else:
            self.active_tab = active_tab

    fn paint(mut self, mut canvas: Canvas, screen: Rect):
        # Same palette as the menu bar: dark text on light gray, hot keys in red.
        var bg = Attr(BLACK, LIGHT_GRAY)
        var key_attr = Attr(RED, LIGHT_GRAY)
        var desc_attr = Attr(BLACK, LIGHT_GRAY)
        var y = screen.b.y - 1
        canvas.fill(Rect(0, y, screen.b.x, screen.b.y), String(" "), bg)
        var x = 1
        for i in range(len(self.items)):
            var k = self.items[i].key
            var d = self.items[i].desc
            _ = canvas.put_text(Point(x, y), k, key_attr)
            x += len(k.as_bytes()) + 1
            _ = canvas.put_text(Point(x, y), d, desc_attr)
            x += len(d.as_bytes()) + 2
        # Target tabs: painted in the gap between F-key shortcuts and
        # the right-aligned status message. The active tab is
        # reverse-video so the user can see at a glance which target
        # Cmd+R will run. We capture per-tab bounds in ``_tab_hits`` so
        # the click handler can route hits without recomputing the
        # layout.
        self._tab_hits = List[_TabHit]()
        if len(self.tabs) > 0:
            x += 1
            for i in range(len(self.tabs)):
                if x >= screen.b.x - 1:
                    break
                var tab = self.tabs[i]
                var label = tab.label
                if tab.running:
                    label = String("● ") + label
                elif tab.debugging:
                    label = String("◆ ") + label
                var rendered = String(" ") + label + String(" ")
                var w = len(rendered.as_bytes())
                var attr: Attr
                if i == self.active_tab:
                    # Reverse: white-on-blue tells the eye "this is selected"
                    # at a glance, while non-active tabs sit in the same
                    # palette as everything else on the bar.
                    attr = Attr(WHITE, BLUE)
                else:
                    attr = Attr(BLACK, LIGHT_GRAY)
                var max_x = screen.b.x - 1
                _ = canvas.put_text(Point(x, y), rendered, attr, max_x)
                self._tab_hits.append(_TabHit(x, x + w, i))
                x += w + 1
        # Right-aligned status message — clamped so it never collides with
        # the F-key list on narrow terminals (left side wins).
        if len(self.message.as_bytes()) > 0:
            var msg_w = len(self.message.as_bytes())
            var mx = screen.b.x - msg_w - 1
            if mx < x + 1:
                return
            _ = canvas.put_text(Point(mx, y), self.message, self.message_attr)

    fn hit_test_tab(self, pos: Point, screen: Rect) -> Int:
        """Return the index of the tab clicked at ``pos``, or -1 if no
        tab was hit. Hit rects are populated by ``paint`` and the bar
        only occupies the bottom row, so callers don't need to gate
        on row before calling — we do."""
        if pos.y != screen.b.y - 1:
            return -1
        for i in range(len(self._tab_hits)):
            var h = self._tab_hits[i]
            if h.a_x <= pos.x and pos.x < h.b_x:
                return h.index
        return -1

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Int:
        """Route a mouse event onto the tab strip. Returns the index of
        the clicked tab on a left-button press, or -1 if the event
        didn't land on a tab.

        Match-on-press (rather than release) so the click feels
        responsive — the active tab updates the moment the button goes
        down, like every other widget in this codebase."""
        if event.kind != EVENT_MOUSE:
            return -1
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
            return -1
        if event.motion:
            return -1
        return self.hit_test_tab(event.pos, screen)
