"""Popup that opens when the user clicks the blame gutter — the commit
details for that line: short SHA, author + mail, authored time, and the
commit message.

Purely informational, which is what makes it different from its neighbours
(``GitGutterMenu`` / ``TestGutterMenu``): there is no row to select and no
action to fire, so it has no ``submitted`` / ``action`` protocol. Any key or
any mouse press dismisses it, and while it's up it swallows input like the
other anchored popups so a stray keystroke can't land in the editor behind
it.

The host (Desktop) opens it from ``Editor.consume_blame_info_request``,
having filled in the full commit message with ``git_blame.commit_message``
(the porcelain blame stream only carries the subject line).
"""

from std.collections.list import List

from .canvas import Canvas, wrap_to_width
from .painter import Painter
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    MENU_HIT_INSIDE, MENU_HIT_NONE, MENU_HIT_OUTSIDE,
)
from .geometry import Point, Rect
from .git_blame import BlameLine, format_commit_time
from .git_changes import format_age
from .string_utils import display_columns, truncate_to_columns
from .anchored_menu import anchored_menu_rect, paint_anchored_chrome


# Message body is wrapped to this many columns; the popup sizes itself to
# the widest row it ends up with, so a one-line subject stays narrow. Header
# rows are truncated to the same budget.
comptime _MAX_BODY_COLS = 56

# A long-form commit message would otherwise make the popup taller than the
# window — ``anchored_menu_rect`` can only slide a box, not shrink it. Cap
# the body and mark the cut; the whole message is a git command away.
comptime _MAX_BODY_ROWS = 12

comptime _LABEL_UNCOMMITTED = String("Not committed yet")
comptime _LABEL_TRUNCATED = String("…")


struct BlamePopup(Movable):
    """Anchored, read-only commit-detail popup for one blamed line."""

    var active: Bool
    var anchor_x: Int
    var anchor_y: Int
    var head_rows: List[String]
    """SHA / author / timestamp lines — painted in the accent colours."""
    var body_rows: List[String]
    """Wrapped commit message, blank-separated from ``head_rows``. Empty
    when the commit has no message (or git couldn't be asked)."""

    def __init__(out self):
        self.active = False
        self.anchor_x = 0
        self.anchor_y = 0
        self.head_rows = List[String]()
        self.body_rows = List[String]()

    def open(
        mut self, bl: BlameLine, message: String, now_unix: Int, anchor: Point,
    ):
        """Build the rows for ``bl`` and show the popup at ``anchor``.

        ``message`` is the full commit message body; empty falls back to
        ``bl.summary`` (the porcelain subject line), so a failed or skipped
        ``git show`` still yields a useful popup. ``now_unix`` drives the
        relative age suffix — pass ``0`` to omit it.
        """
        self.head_rows = List[String]()
        self.body_rows = List[String]()
        if bl.is_uncommitted():
            # No object to describe: git's own placeholder author, and a
            # zero SHA / epoch timestamp that would only mislead.
            self.head_rows.append(_LABEL_UNCOMMITTED)
        else:
            self.head_rows.append(bl.commit)
            var who = bl.author
            if len(bl.author_mail.as_bytes()) > 0:
                who += String(" ") + bl.author_mail
            if len(who.as_bytes()) > 0:
                self.head_rows.append(truncate_to_columns(who, _MAX_BODY_COLS))
            var when = format_commit_time(bl.author_time, bl.author_tz)
            if len(when.as_bytes()) > 0:
                if now_unix > 0 and now_unix > bl.author_time:
                    when += String(" (") \
                        + format_age(now_unix - bl.author_time) \
                        + String(" ago)")
                self.head_rows.append(when^)
        var text = message
        if len(text.as_bytes()) == 0:
            text = bl.summary
        var wrapped = wrap_to_width(text, _MAX_BODY_COLS)
        for i in range(len(wrapped)):
            if i == _MAX_BODY_ROWS:
                self.body_rows.append(_LABEL_TRUNCATED)
                break
            self.body_rows.append(wrapped[i])
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True

    def close(mut self):
        self.active = False
        self.head_rows = List[String]()
        self.body_rows = List[String]()

    def _row_count(self) -> Int:
        """Head rows, then a blank spacer, then the message rows. No
        spacer when either half is empty."""
        var n = len(self.head_rows) + len(self.body_rows)
        if len(self.head_rows) > 0 and len(self.body_rows) > 0:
            n += 1
        return n

    def _body_width(self) -> Int:
        var w = 0
        for i in range(len(self.head_rows)):
            var hw = display_columns(self.head_rows[i])
            if hw > w:
                w = hw
        for i in range(len(self.body_rows)):
            var bw = display_columns(self.body_rows[i])
            if bw > w:
                w = bw
        return w

    def _rect(self, container_bounds: Rect) -> Rect:
        return anchored_menu_rect(
            self.anchor_x, self.anchor_y,
            self._body_width() + 4, self._row_count() + 2,
            container_bounds, False,
        )

    def paint(self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var rect = self._rect(container_bounds)
        var attr = Attr(BLACK, LIGHT_GRAY)
        # The SHA is the identity of the thing, so it gets the accent
        # colour dialogs use for a distinguished value; author, time and
        # message are all plain dialog text. (Deliberately *not*
        # ``DARK_GRAY`` for the metadata — on ``LIGHT_GRAY`` that pairing
        # means "disabled" everywhere else in this codebase.)
        var sha_attr = Attr(BLUE, LIGHT_GRAY)
        paint_anchored_chrome(canvas, rect, attr)
        var painter = Painter(rect)
        var x = rect.a.x + 2
        var y = rect.a.y + 1
        for i in range(len(self.head_rows)):
            var row_attr = sha_attr if i == 0 else attr
            _ = painter.put_text(
                canvas, Point(x, y), self.head_rows[i], row_attr,
            )
            y += 1
        if len(self.head_rows) > 0 and len(self.body_rows) > 0:
            y += 1
        for i in range(len(self.body_rows)):
            _ = painter.put_text(
                canvas, Point(x, y), self.body_rows[i], attr,
            )
            y += 1

    def handle_key(mut self, event: Event) -> Bool:
        """Any key dismisses — there is nothing here to navigate, and a
        keystroke while an info popup is up plainly means "go away". The
        key is consumed by the dismissal rather than reaching the editor."""
        if not self.active:
            return False
        if event.kind == EVENT_KEY:
            self.close()
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Int:
        """Any button press dismisses, inside or out. Reported as
        ``MENU_HIT_INSIDE`` / ``MENU_HIT_OUTSIDE`` so the host can tell
        whether the click was also meant for whatever is underneath."""
        if not self.active:
            return MENU_HIT_NONE
        if event.kind != EVENT_MOUSE or event.motion or not event.pressed:
            return MENU_HIT_NONE
        var inside = self._rect(container_bounds).contains(event.pos)
        self.close()
        return MENU_HIT_INSIDE if inside else MENU_HIT_OUTSIDE
