"""Popup menu that opens when the user right-clicks a diagnostic
(LSP inspection error/warning/info/hint) squiggle in the editor's
text area, or hits Alt+Enter while the cursor is on one.

The first row is always ``Copy message`` (push the diagnostic text to
the clipboard — useful for pasting into a search / chat / bug tracker).
The host can then attach LSP code-action quickfixes as additional rows
once they arrive from the server: ``set_actions(titles)``. While the
host is still waiting for a ``textDocument/codeAction`` response, it
can call ``set_loading_fixes(True)`` to show a single disabled
``Loading fixes…`` row beneath ``Copy message`` so the user has a
visible signal that more options are on the way.

Modeled on ``GitGutterMenu`` and ``SpellMenu`` so the look and event
protocol match: the host (Desktop) is responsible for opening the menu
in response to ``Editor.consume_diagnostic_menu_request`` and for
routing keyboard / mouse events to it before any other widget.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas
from .painter import Painter
from .colors import (
    Attr, BLACK, DARK_GRAY, GREEN, LIGHT_GRAY, WHITE,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_UP,
    MENU_HIT_INSIDE, MENU_HIT_NONE, MENU_HIT_OUTSIDE,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .lsp_dispatch import Diagnostic
from .string_utils import display_columns
from .view import RowCursor
from .anchored_menu import anchored_menu_rect, paint_anchored_chrome


def _row_y(rect: Rect) -> Int:
    var cursor = RowCursor(rect.a.y + 1)
    return cursor.place()


# ``DiagnosticMenu.handle_mouse`` returns the shared ``MENU_HIT_*`` codes
# (``events.mojo``).


comptime DIAG_MENU_ACTION_NONE      = 0
comptime DIAG_MENU_ACTION_COPY      = 1
comptime DIAG_MENU_ACTION_APPLY_FIX = 2
"""User picked one of the LSP code-action quickfix rows. The host reads
``selected_fix_index`` to find which one (0-based into the list passed
to ``set_actions``)."""


comptime _LABEL_COPY    = String("Copy message")
comptime _LABEL_LOADING = String("Loading fixes…")


@fieldwise_init
struct DiagnosticMenuRequest(ImplicitlyCopyable, Movable):
    """Payload emitted when the user opens the diagnostic menu —
    right-click on a squiggle in the text area or Alt+Enter while the
    cursor sits on one.

    ``message`` is the formatted ``[source] text`` label the menu copies
    on the Copy row. ``anchor_x``/``anchor_y`` are the container_bounds cell the
    menu should open against (immediately below the underlined span,
    left-aligned to its leftmost cell). ``diag`` is the underlying LSP
    diagnostic — the host forwards its range + severity + message in
    the ``textDocument/codeAction`` request so servers like ty / pyright
    can return quickfixes keyed to that specific diagnostic."""
    var message: String
    var anchor_x: Int
    var anchor_y: Int
    var diag: Diagnostic


struct DiagnosticMenu(Movable):
    """Modal-ish popup menu anchored to a diagnostic squiggle."""

    var active: Bool
    var submitted: Bool
    var action: Int
    var selected_fix_index: Int
    """Index into ``fix_titles`` of the chosen quickfix when ``action ==
    DIAG_MENU_ACTION_APPLY_FIX``. -1 when no fix is selected."""

    var message: String
    """The diagnostic text — captured at open time so the host can
    push it to the clipboard on submit without re-resolving which
    diagnostic was clicked."""

    var anchor_x: Int
    var anchor_y: Int
    var selected: Int
    var tracking: Bool
    """True between a captured left-press inside the menu and its
    matching release. Like a button, the action only fires on
    release; a release that arrives without a prior tracked press
    is ignored so the release of the right-click that opened the
    menu can never auto-trigger an action."""

    var loading_fixes: Bool
    """While True the menu paints a disabled ``Loading fixes…`` row at
    the top. Set after the host fires the LSP ``textDocument/codeAction``
    request; cleared by ``set_actions`` when the response lands.
    Independent of ``fix_titles`` so a server that returns zero actions
    cleanly transitions to "just Copy" rather than leaving the loading
    row up forever."""

    var fix_titles: List[String]
    """Titles of the LSP quickfix actions to show as the top rows.
    Empty when no actions are available (or none have arrived yet).
    Set by the host via ``set_actions``."""

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = DIAG_MENU_ACTION_NONE
        self.selected_fix_index = -1
        self.message = String("")
        self.anchor_x = 0
        self.anchor_y = 0
        self.selected = 0
        self.tracking = False
        self.loading_fixes = False
        self.fix_titles = List[String]()

    def open(mut self, var message: String, anchor: Point):
        self.message = message^
        self.anchor_x = anchor.x
        self.anchor_y = anchor.y
        self.active = True
        self.submitted = False
        self.action = DIAG_MENU_ACTION_NONE
        self.selected_fix_index = -1
        # No fixes yet, no loading flag yet — only the Copy row exists
        # so the default selection lands there. ``set_loading_fixes`` /
        # ``set_actions`` will move it as state arrives.
        self.selected = 0
        self.tracking = False
        self.loading_fixes = False
        self.fix_titles = List[String]()

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = DIAG_MENU_ACTION_NONE
        self.selected_fix_index = -1
        self.message = String("")
        self.tracking = False
        self.loading_fixes = False
        self.fix_titles = List[String]()

    def set_loading_fixes(mut self, loading: Bool):
        """Host calls this with True right after firing a code-action
        request and with False if it decides not to (e.g. LSP not ready).
        Calling ``set_actions`` clears the loading flag implicitly.

        While loading, the selection lands on the Copy row (the only
        actionable one) so an immediate Enter does something sensible
        rather than no-oping against the disabled loading row."""
        var was_loading = self.loading_fixes
        self.loading_fixes = loading
        if loading and not was_loading:
            # Loading is the new row 0; bump selection to the Copy row.
            self.selected = self._copy_row()

    def set_actions(mut self, var titles: List[String]):
        """Replace the dynamic action rows with ``titles`` and clear the
        loading flag. Pass an empty list when the server returned no
        actions — the loading row goes away and the menu collapses back
        to just ``Copy message``.

        Selection jumps to the first fix row when at least one fix
        arrived — that's why the user opened the menu — falling back
        to the Copy row when there are no fixes."""
        self.fix_titles = titles^
        self.loading_fixes = False
        if len(self.fix_titles) > 0:
            self.selected = 0
        else:
            self.selected = self._copy_row()

    def _row_count(self) -> Int:
        # Layout (top → bottom): [fix rows…] [loading row if loading]
        # [Copy row]. The loading row only appears while we're waiting
        # for a response and there are no fixes yet — once
        # ``set_actions`` arrives it's replaced by the actual fix rows.
        var n = len(self.fix_titles)
        if self.loading_fixes:
            n += 1
        return n + 1

    def _copy_row(self) -> Int:
        """Index of the Copy row — always the last one."""
        return self._row_count() - 1

    def _is_loading_row(self, row: Int) -> Bool:
        if not self.loading_fixes:
            return False
        return row == len(self.fix_titles)

    def _is_fix_row(self, row: Int) -> Bool:
        return row >= 0 and row < len(self.fix_titles)

    def _is_copy_row(self, row: Int) -> Bool:
        return row == self._copy_row()

    def _step(mut self, delta: Int):
        var n = self._row_count()
        if n == 0:
            return
        var i = self.selected + delta
        if i < 0:
            i = n - 1
        elif i >= n:
            i = 0
        # Skip the disabled loading row in either direction.
        if self._is_loading_row(i):
            i = i + delta
            if i < 0:
                i = n - 1
            elif i >= n:
                i = 0
            if self._is_loading_row(i):
                # n == 2 (loading + Copy); pin to Copy.
                i = self._copy_row()
        self.selected = i

    def _resolve(mut self, action: Int):
        self.action = action
        self.submitted = True

    def _label_width(self) -> Int:
        var w = display_columns(_LABEL_COPY)
        if self.loading_fixes and display_columns(_LABEL_LOADING) > w:
            w = display_columns(_LABEL_LOADING)
        for i in range(len(self.fix_titles)):
            var lw = display_columns(self.fix_titles[i])
            if lw > w:
                w = lw
        return w

    def _rect(self, container_bounds: Rect) -> Rect:
        return anchored_menu_rect(
            self.anchor_x, self.anchor_y,
            self._label_width() + 4, self._row_count() + 2,
            container_bounds, False,
        )

    def paint(self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var rect = self._rect(container_bounds)
        var attr = Attr(BLACK, LIGHT_GRAY)
        var sel_attr = Attr(BLACK, GREEN)
        var disabled_attr = Attr(DARK_GRAY, LIGHT_GRAY)
        paint_anchored_chrome(canvas, rect, attr)
        var painter = Painter(rect)
        var y0 = _row_y(rect)
        var rows = self._row_count()
        for row in range(rows):
            var y = y0 + row
            var is_sel = (self.selected == row)
            var row_attr: Attr
            var label: String
            if self._is_fix_row(row):
                label = self.fix_titles[row]
                row_attr = sel_attr if is_sel else attr
            elif self._is_loading_row(row):
                label = _LABEL_LOADING
                row_attr = disabled_attr
            else:
                # Copy row — always last.
                label = _LABEL_COPY
                row_attr = sel_attr if is_sel else attr
            if is_sel and not self._is_loading_row(row):
                painter.fill(
                    canvas, Rect(rect.a.x + 1, y, rect.b.x - 1, y + 1),
                    String(" "), row_attr,
                )
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, y), label, row_attr,
            )

    def _resolve_selected(mut self):
        var row = self.selected
        if self._is_loading_row(row):
            # Disabled — keep the menu open so the user can wait or
            # arrow to the Copy row.
            return
        if self._is_fix_row(row):
            self.selected_fix_index = row
            self._resolve(DIAG_MENU_ACTION_APPLY_FIX)
            return
        if self._is_copy_row(row):
            self._resolve(DIAG_MENU_ACTION_COPY)

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self._resolve(DIAG_MENU_ACTION_NONE)
            return True
        if k == KEY_UP:
            self._step(-1)
            return True
        if k == KEY_DOWN:
            self._step(1)
            return True
        if k == KEY_ENTER:
            self._resolve_selected()
            return True
        return True

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Int:
        """Button-like press / release model. A press inside an
        actionable row arms tracking and highlights; the action only
        fires when the matching release lands inside the menu (drag
        off-and-release cancels, like ``ShadowButton``). Press outside
        dismisses immediately. Releases without a prior tracked press
        are non-events — that's what stops the right-click that opened
        the menu from auto-firing on its trailing release."""
        if not self.active:
            return MENU_HIT_NONE
        if event.kind != EVENT_MOUSE:
            return MENU_HIT_NONE
        if event.button != MOUSE_BUTTON_LEFT or event.motion:
            return MENU_HIT_NONE
        var rect = self._rect(container_bounds)
        var inside = rect.contains(event.pos)
        if event.pressed:
            if not inside:
                self._resolve(DIAG_MENU_ACTION_NONE)
                return MENU_HIT_OUTSIDE
            var row = event.pos.y - _row_y(rect)
            if row < 0 or row >= self._row_count():
                return MENU_HIT_INSIDE
            if self._is_loading_row(row):
                return MENU_HIT_INSIDE
            self.selected = row
            self.tracking = True
            return MENU_HIT_INSIDE
        # Release.
        if not self.tracking:
            return MENU_HIT_NONE
        self.tracking = False
        if not inside:
            self._resolve(DIAG_MENU_ACTION_NONE)
            return MENU_HIT_OUTSIDE
        var row = event.pos.y - _row_y(rect)
        if row < 0 or row >= self._row_count():
            return MENU_HIT_INSIDE
        if self._is_loading_row(row):
            return MENU_HIT_INSIDE
        self.selected = row
        self._resolve_selected()
        return MENU_HIT_INSIDE
