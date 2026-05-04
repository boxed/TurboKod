"""Bottom-docked debug pane: stack, locals tree, watches, output log.

Layout (when active, at the bottom of the workspace, above the status bar)::

    ─ Debug ────────────────────────────────────────────────
    DAP[debugpy]: stopped (breakpoint)
    Stack:              │ Locals:
      ▶ main  foo.py:42 │   x = 42 (int)
        handler foo.py:17│ ▼ obj = <Foo>
                        │     name = "alice" (str)
                        │     age = 30 (int)
                        │ Watches:
                        │   len(items) = 4 (int)
    ─ Output ────────────────────────────────────────────────
    starting up...
    request 1 received
    response 200

The pane is split horizontally: the top portion is the "inspect" view,
which is itself split vertically — Stack on the left, Locals + Watches
on the right. The bottom portion is the output log.
The two inspect columns and the output log scroll independently —
arrow keys / wheel when the pane is focused (focus is on click).
Output autoscrolls to the end whenever new lines arrive *unless* the
user has scrolled up manually.

State model: one flat ``rows`` list for inspect content, with a kind
tag per row (``PANE_ROW_*``) so paint and click-handling can dispatch
without checking type. Output keeps its own list (``output_lines``) and
attribute parallel array because its row population pattern (append
on every event) is structurally different from inspect's
(rebuilt-from-scratch on stop).

UI intents flow back to Desktop through ``pending_*`` fields the host
polls each frame:

* ``pending_frame_id`` — the user clicked a stack frame; refetch its
  scopes/variables.
* ``pending_expand_ref`` + ``pending_expand_row`` + ``pending_expand_depth``
  — the user clicked a variable's chevron; fetch its children and
  splice them after the row.

Pane fields that drive this back-and-forth are deliberately concrete
(``Int``, ``String``) rather than typed enums — Mojo's enum support is
thin enough that ``UInt8`` discriminants paired with ``comptime``
constants is the smoothest pattern available, and matches what
``LspIncoming``/``DapIncoming`` already do upstream.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, LIGHT_BLUE, LIGHT_GRAY, LIGHT_RED, LIGHT_YELLOW,
    STYLE_UNDERLINE, WHITE, YELLOW,
)
from .dap_dispatch import DapStackFrame, DapVariable
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ESC, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect


# --- row kinds ------------------------------------------------------------

comptime PANE_ROW_HEADER    = UInt8(0)
"""Section title (``Stack:``, ``Locals:``, ``Watches:``)."""
comptime PANE_ROW_FRAME     = UInt8(1)
"""One stack frame."""
comptime PANE_ROW_VARIABLE  = UInt8(2)
"""One variable (or struct field, or array element)."""
comptime PANE_ROW_WATCH     = UInt8(3)
"""One watch expression + its current value."""
comptime PANE_ROW_BLANK     = UInt8(4)
"""Visual spacer between sections."""

# Output category — kept as UInt8 to mirror DAP's category strings
# (``stdout``, ``stderr``, ``console``, ``important``) without dragging
# the strings into render hot paths.
comptime PANE_OUT_STDOUT     = UInt8(0)
comptime PANE_OUT_STDERR     = UInt8(1)
comptime PANE_OUT_CONSOLE    = UInt8(2)


# --- pane mode ------------------------------------------------------------
# DEBUG mode shows the full Stack / Locals / Watches inspect view above
# the Output log — the original ``Debug`` panel. RUN mode is the same
# pane reused for plain ``Cmd+R`` runs and for the post-run "exited" hold:
# stack / locals are always empty in those states, so we drop the inspect
# section entirely and let Output use the full content height. The title
# also flips ("Run" vs. "Debug") so the user can see at a glance which
# kind of session the pane is showing.

comptime PANE_MODE_DEBUG     = UInt8(0)
comptime PANE_MODE_RUN       = UInt8(1)


# --- pane window state ---------------------------------------------------
# NORMAL is the default — the pane sits at ``preferred_height`` and the
# user can drag its top border to resize. MINIMIZED collapses the pane
# to a single header row (title + window buttons stay visible so the
# user can restore). MAXIMIZED expands the pane to the full workspace
# height so the user can read long output. State transitions happen via
# the header buttons or via ESC (handled in ``handle_key``).

comptime PANE_STATE_NORMAL    = UInt8(0)
comptime PANE_STATE_MINIMIZED = UInt8(1)
comptime PANE_STATE_MAXIMIZED = UInt8(2)


@fieldwise_init
struct OutputLink(ImplicitlyCopyable, Movable):
    """One clickable file:line span painted into the Output log.

    Populated by ``paint`` whenever a recognized pattern (currently
    Python's ``File "<path>", line <N>``) appears in a visible output
    line, and consumed by ``handle_mouse`` to map a click back to a
    file-open intent. The rect is in absolute screen coordinates so
    the click test doesn't need to know about the pane's own origin.
    """
    var y: Int
    var x_start: Int
    var x_end: Int     # exclusive
    var path: String
    var line: Int      # 1-based; matches Python traceback convention


@fieldwise_init
struct PaneRow(ImplicitlyCopyable, Movable):
    """One renderable row in the inspect view.

    ``kind`` selects which fields actually mean something:
    * ``PANE_ROW_HEADER``: ``text`` is the title.
    * ``PANE_ROW_FRAME``: ``text`` is ``"name  file:line"``,
      ``ref`` is the DAP frame id, ``depth`` is the frame index
      (used to highlight the current frame).
    * ``PANE_ROW_VARIABLE``: ``text`` is ``"name = value (type)"``,
      ``ref`` is ``variables_reference`` (0 = leaf), ``depth`` is the
      tree indent level, ``expanded`` distinguishes ``▶ obj`` /
      ``▼ obj`` rendering.
    * ``PANE_ROW_WATCH``: ``text`` is ``"expression = value"``;
      ``ref`` is unused.
    * ``PANE_ROW_BLANK``: nothing — paint a blank line.
    """
    var kind: UInt8
    var text: String
    var ref_id: Int    # frame_id / variables_reference / 0
    var depth: Int     # frame_index / tree depth
    var expanded: Bool


# --- pane -----------------------------------------------------------------


comptime _MAX_OUTPUT_LINES = 500
"""Output backlog cap. ~500 lines covers most short debug runs without
becoming a memory liability for long-lived sessions; older lines drop
off the front. The pane only paints the last few anyway, but keeping
the backlog lets a future ``output:save`` action dump the full log."""


struct DebugPane(ImplicitlyCopyable, Movable):
    var visible: Bool
    var preferred_height: Int
    var status_text: String
    var mode: UInt8
    """``PANE_MODE_DEBUG`` (default) shows Stack/Locals/Watches +
    Output. ``PANE_MODE_RUN`` collapses the pane to Output-only and
    flips the title to "Run". Set by the host on every tick to match
    the active session (or the post-run hold)."""
    var state: UInt8
    """``PANE_STATE_NORMAL`` (default), ``PANE_STATE_MINIMIZED`` (header
    line only), or ``PANE_STATE_MAXIMIZED`` (full workspace). Toggled
    via the header buttons or ESC."""

    var rows: List[PaneRow]
    """Inspect-view rows (status not included). Sectioned via
    ``PANE_ROW_HEADER`` markers."""

    var current_frame_index: Int
    """Which frame is highlighted in the Stack section (the one whose
    locals are showing). Bound to a frame's ``depth`` field, so a
    single int is enough to identify it."""

    var output_lines: List[String]
    var output_categories: List[UInt8]   # parallel to output_lines

    var stack_scroll: Int
    """First left-column (Stack) row to paint. Bumped by wheel over
    the stack column or by arrow keys when no right-column rows
    exist."""
    var right_scroll: Int
    """First right-column (Locals/Watches) row to paint. Bumped by
    arrow keys / wheel over the right column."""
    var output_scroll: Int
    """First output line to paint (autoscrolled to keep the *last*
    line visible unless the user scrolled up manually)."""
    var output_autoscroll: Bool

    var focused: Bool
    """True when the pane has keyboard focus — the host sets this on
    click. Determines whether arrow keys reach the pane."""

    # --- pending intents -- consumed each frame by Desktop.dap_tick ---
    var pending_frame_id: Int           # -1 = none
    var pending_frame_index: Int        # depth of the clicked frame, for highlight
    var pending_expand_ref: Int         # -1 = none
    var pending_expand_row: Int         # row index of the parent variable
    var pending_expand_depth: Int       # children's indent level
    var pending_collapse_row: Int       # row index for a collapse (no DAP traffic needed)
    # Output-log link click. Empty string = none.
    var pending_open_path: String
    var pending_open_line: Int          # 1-based; 0 with empty path = none

    # --- mouse-mapping bookkeeping ------------------------------------
    var _last_inspect_y0: Int   # screen y of the first inspect row
    var _last_output_y0: Int
    var _last_divider_x: Int    # screen x of the column divider
    var _last_panel_top: Int    # screen y of the top-border / drag handle
    var _left_indices: List[Int]
    """Absolute ``rows`` indices that belong to the left (Stack)
    column, in paint order. Populated by ``paint`` and read by
    ``handle_mouse``."""
    var _right_indices: List[Int]
    """Absolute ``rows`` indices that belong to the right
    (Locals / Watches) column, in paint order."""
    var _resizing: Bool
    """True while the user holds the left button after pressing on
    the pane's top border. Mouse motion in this state updates
    ``preferred_height``; the next non-pressed event clears it."""
    var _last_min_btn_x: Int
    """Top-row x of the leftmost cell of the minimize button drawn by
    the last paint, or ``-1`` if not painted (panel too narrow)."""
    var _last_max_btn_x: Int
    """Top-row x of the leftmost cell of the maximize/restore button
    drawn by the last paint, or ``-1`` if not painted."""
    var _last_links: List[OutputLink]
    """Clickable file:line spans painted by the last ``paint`` call,
    in absolute screen coordinates. Rebuilt on every paint so the
    set always reflects what the user can currently see — scrolled-off
    lines drop out automatically."""

    fn __init__(out self):
        self.visible = False
        self.preferred_height = 14
        self.status_text = String("")
        self.mode = PANE_MODE_DEBUG
        self.state = PANE_STATE_NORMAL
        self.rows = List[PaneRow]()
        self.current_frame_index = 0
        self.output_lines = List[String]()
        self.output_categories = List[UInt8]()
        self.stack_scroll = 0
        self.right_scroll = 0
        self.output_scroll = 0
        self.output_autoscroll = True
        self.focused = False
        self.pending_frame_id = -1
        self.pending_frame_index = -1
        self.pending_expand_ref = -1
        self.pending_expand_row = -1
        self.pending_expand_depth = 0
        self.pending_collapse_row = -1
        self.pending_open_path = String("")
        self.pending_open_line = 0
        self._last_inspect_y0 = 0
        self._last_output_y0 = 0
        self._last_divider_x = 0
        self._last_panel_top = 0
        self._left_indices = List[Int]()
        self._right_indices = List[Int]()
        self._resizing = False
        self._last_links = List[OutputLink]()
        self._last_min_btn_x = -1
        self._last_max_btn_x = -1

    fn __copyinit__(out self, copy: Self):
        self.visible = copy.visible
        self.preferred_height = copy.preferred_height
        self.status_text = copy.status_text
        self.mode = copy.mode
        self.state = copy.state
        self.rows = copy.rows.copy()
        self.current_frame_index = copy.current_frame_index
        self.output_lines = copy.output_lines.copy()
        self.output_categories = copy.output_categories.copy()
        self.stack_scroll = copy.stack_scroll
        self.right_scroll = copy.right_scroll
        self.output_scroll = copy.output_scroll
        self.output_autoscroll = copy.output_autoscroll
        self.focused = copy.focused
        self.pending_frame_id = copy.pending_frame_id
        self.pending_frame_index = copy.pending_frame_index
        self.pending_expand_ref = copy.pending_expand_ref
        self.pending_expand_row = copy.pending_expand_row
        self.pending_expand_depth = copy.pending_expand_depth
        self.pending_collapse_row = copy.pending_collapse_row
        self.pending_open_path = copy.pending_open_path
        self.pending_open_line = copy.pending_open_line
        self._last_inspect_y0 = copy._last_inspect_y0
        self._last_output_y0 = copy._last_output_y0
        self._last_divider_x = copy._last_divider_x
        self._last_panel_top = copy._last_panel_top
        self._left_indices = copy._left_indices.copy()
        self._right_indices = copy._right_indices.copy()
        self._resizing = copy._resizing
        self._last_links = copy._last_links.copy()
        self._last_min_btn_x = copy._last_min_btn_x
        self._last_max_btn_x = copy._last_max_btn_x

    # --- setters (used by Desktop) ---------------------------------------

    fn set_status(mut self, var text: String):
        self.status_text = text^

    fn set_mode(mut self, mode: UInt8):
        self.mode = mode

    fn is_minimized(self) -> Bool:
        return self.state == PANE_STATE_MINIMIZED

    fn is_maximized(self) -> Bool:
        return self.state == PANE_STATE_MAXIMIZED

    fn set_state(mut self, state: UInt8):
        self.state = state
        # Resize-drag belongs to NORMAL only — the top border is just a
        # button strip in the other states, not a draggable handle.
        if state != PANE_STATE_NORMAL:
            self._resizing = False

    fn rebuild_inspect(
        mut self,
        var frames: List[DapStackFrame],
        var locals_label: String,
        var locals: List[DapVariable],
        var watches_label: String,
        var watch_lines: List[String],
        current_frame_index: Int,
    ):
        """Replace the entire inspect view from scratch.

        Called whenever the focus frame changes (initial stop, or user
        click). ``watches`` is passed as already-formatted strings since
        the watch evaluation lives in Desktop and the pane doesn't need
        to know how DAP ``evaluate`` results decode.
        """
        var out = List[PaneRow]()
        out.append(PaneRow(
            PANE_ROW_HEADER, String("Stack"), 0, 0, False,
        ))
        for i in range(len(frames)):
            var f = frames[i]
            var loc = String("")
            if len(f.path.as_bytes()) > 0:
                loc = _basename(f.path) + String(":") + String(f.line + 1)
            var name_pad = _pad_right(f.name, 18)
            out.append(PaneRow(
                PANE_ROW_FRAME,
                name_pad + String("  ") + loc,
                f.id, i, False,
            ))
        out.append(PaneRow(PANE_ROW_BLANK, String(""), 0, 0, False))
        out.append(PaneRow(
            PANE_ROW_HEADER, locals_label^, 0, 0, False,
        ))
        for i in range(len(locals)):
            var v = locals[i]
            out.append(PaneRow(
                PANE_ROW_VARIABLE,
                _format_variable(v.name, v.value, v.type_name),
                v.variables_reference, 0, False,
            ))
        if len(watch_lines) > 0:
            out.append(PaneRow(PANE_ROW_BLANK, String(""), 0, 0, False))
            out.append(PaneRow(
                PANE_ROW_HEADER, watches_label^, 0, 0, False,
            ))
            for i in range(len(watch_lines)):
                out.append(PaneRow(
                    PANE_ROW_WATCH, watch_lines[i], 0, 0, False,
                ))
        self.rows = out^
        self.current_frame_index = current_frame_index
        self.stack_scroll = 0
        self.right_scroll = 0

    fn splice_children_at(
        mut self, parent_row: Int, child_depth: Int,
        var children: List[DapVariable],
    ):
        """Insert ``children`` immediately after ``parent_row`` at indent
        level ``child_depth`` (= parent's depth + 1). Marks the parent
        ``expanded`` so subsequent paints render it with ``▼`` instead
        of ``▶``."""
        if parent_row < 0 or parent_row >= len(self.rows):
            return
        var p = self.rows[parent_row]
        p.expanded = True
        self.rows[parent_row] = p
        # Mojo's ``List`` lacks a mid-list ``insert`` on every version
        # we support, so rebuild instead.
        var out = List[PaneRow]()
        for i in range(len(self.rows)):
            out.append(self.rows[i])
            if i == parent_row:
                for k in range(len(children)):
                    var v = children[k]
                    out.append(PaneRow(
                        PANE_ROW_VARIABLE,
                        _format_variable(v.name, v.value, v.type_name),
                        v.variables_reference, child_depth, False,
                    ))
        self.rows = out^

    fn collapse_at(mut self, parent_row: Int):
        """Remove all children of ``parent_row`` (rows whose depth is
        greater than the parent's). Also clears ``expanded`` on the
        parent. Idempotent: collapsing an unexpanded row is a no-op."""
        if parent_row < 0 or parent_row >= len(self.rows):
            return
        var p = self.rows[parent_row]
        if p.kind != PANE_ROW_VARIABLE:
            return
        var parent_depth = p.depth
        p.expanded = False
        self.rows[parent_row] = p
        var out = List[PaneRow]()
        var i = 0
        while i < len(self.rows):
            out.append(self.rows[i])
            if i == parent_row:
                # Skip every following row whose depth > parent_depth
                # AND that's a variable. Stop at the first non-child
                # row (different section, or shallower variable).
                var j = i + 1
                while j < len(self.rows):
                    var r = self.rows[j]
                    if r.kind == PANE_ROW_VARIABLE and r.depth > parent_depth:
                        j += 1
                    else:
                        break
                i = j - 1   # ``i += 1`` below advances past the last skipped
            i += 1
        self.rows = out^

    fn append_output(
        mut self, var text: String, category: UInt8 = PANE_OUT_STDOUT,
    ):
        """Append a single output blob, splitting on ``\\n`` so a
        burst that arrives as one DAP event still shows row-by-row.
        Trims the backlog when it exceeds ``_MAX_OUTPUT_LINES``."""
        var b = text.as_bytes()
        var start = 0
        for i in range(len(b)):
            if b[i] == 0x0A:  # '\n'
                self._push_output_line(
                    String(StringSlice(
                        ptr=b.unsafe_ptr() + start, length=i - start,
                    )),
                    category,
                )
                start = i + 1
        if start < len(b):
            self._push_output_line(
                String(StringSlice(
                    ptr=b.unsafe_ptr() + start, length=len(b) - start,
                )),
                category,
            )
        var max_scroll = len(self.output_lines) - 1
        if max_scroll < 0:
            max_scroll = 0
        if self.output_autoscroll:
            self.output_scroll = max_scroll

    fn _push_output_line(mut self, var line: String, category: UInt8):
        self.output_lines.append(line^)
        self.output_categories.append(category)
        if len(self.output_lines) > _MAX_OUTPUT_LINES:
            # Trim the front. Cheap-ish — happens only when the cap
            # is hit, which is a rare event for typical sessions.
            var trimmed = List[String]()
            var tcat = List[UInt8]()
            for k in range(
                len(self.output_lines) - _MAX_OUTPUT_LINES,
                len(self.output_lines),
            ):
                trimmed.append(self.output_lines[k])
                tcat.append(self.output_categories[k])
            self.output_lines = trimmed^
            self.output_categories = tcat^
            if self.output_scroll > _MAX_OUTPUT_LINES:
                self.output_scroll = _MAX_OUTPUT_LINES - 1

    fn clear(mut self):
        """Wipe all session state. Called on terminate / failure.
        Output backlog is preserved by design — the user often wants to
        scroll back through the run after it ends to see what happened."""
        self.status_text = String("")
        self.rows = List[PaneRow]()
        self.current_frame_index = 0
        self.stack_scroll = 0
        self.right_scroll = 0
        self._left_indices = List[Int]()
        self._right_indices = List[Int]()

    # --- pending-intent accessors ----------------------------------------

    fn consume_frame_click(mut self) -> Tuple[Int, Int]:
        """Returns ``(frame_id, frame_index)`` if a frame was just
        clicked, ``(-1, -1)`` otherwise."""
        var fid = self.pending_frame_id
        var idx = self.pending_frame_index
        self.pending_frame_id = -1
        self.pending_frame_index = -1
        return (fid, idx)

    fn consume_expand(mut self) -> Tuple[Int, Int, Int]:
        """Returns ``(variables_reference, parent_row, child_depth)``
        for a freshly clicked expansion, or ``(-1, -1, 0)``."""
        var r = self.pending_expand_ref
        var row = self.pending_expand_row
        var depth = self.pending_expand_depth
        self.pending_expand_ref = -1
        self.pending_expand_row = -1
        self.pending_expand_depth = 0
        return (r, row, depth)

    fn consume_collapse(mut self) -> Int:
        var row = self.pending_collapse_row
        self.pending_collapse_row = -1
        return row

    fn consume_open_request(mut self) -> Tuple[String, Int]:
        """Returns ``(path, line)`` (1-based) for a freshly clicked
        output-log link, or ``("", 0)`` when nothing is pending. The
        host calls ``open_file_at`` with ``line - 1`` since
        ``open_file_at`` works in 0-based rows.
        """
        var path = self.pending_open_path
        var line = self.pending_open_line
        self.pending_open_path = String("")
        self.pending_open_line = 0
        return (path^, line)

    # --- paint -----------------------------------------------------------

    fn paint(mut self, mut canvas: Canvas, panel: Rect):
        """Paint inspect (top) + output (bottom) sections. Stamps the
        screen-y origins so ``handle_mouse`` can later map clicks back
        to row indices."""
        if not self.visible or panel.is_empty():
            return
        var bg = Attr(WHITE, BLACK)
        var border = Attr(LIGHT_GRAY, BLACK)
        var title = Attr(LIGHT_YELLOW, BLACK)
        var section = Attr(YELLOW, BLACK)
        var current = Attr(BLACK, LIGHT_YELLOW)
        var dim = Attr(LIGHT_GRAY, BLACK)
        var stderr_attr = Attr(LIGHT_RED, BLACK)
        var link_attr = Attr(LIGHT_BLUE, BLACK, STYLE_UNDERLINE)
        # Reset visible-link rects each paint — only what's currently
        # on screen counts for click hit-testing.
        self._last_links = List[OutputLink]()
        canvas.fill(panel, String(" "), bg)
        self._last_panel_top = panel.a.y
        # Top border with title. Focus is shown via line weight (single →
        # double), mirroring how normal windows render their frame.
        var top = panel.a.y
        var top_glyph = String("═") if self.focused else String("─")
        for x in range(panel.a.x, panel.b.x):
            canvas.set(x, top, Cell(top_glyph, border, 1))
        var title_text = String(" Run ") if self.mode == PANE_MODE_RUN \
            else String(" Debug ")
        _ = canvas.put_text(
            Point(panel.a.x + 2, top), title_text, title, panel.b.x,
        )
        # Top-right header: two window buttons + the keyboard-hint
        # number ("9", paired with ``Ctrl+9``). Buttons are 3 cells
        # each (``[X]``); we paint them in a fixed slot so hit-testing
        # in ``handle_mouse`` can read ``_last_min_btn_x`` /
        # ``_last_max_btn_x`` directly.
        self._last_min_btn_x = -1
        self._last_max_btn_x = -1
        var pane_w = panel.b.x - panel.a.x
        if pane_w >= 12:
            var min_x = panel.b.x - 9
            var max_x = panel.b.x - 6
            self._last_min_btn_x = min_x
            self._last_max_btn_x = max_x
            # Minimize: collapses to header row only. Glyph "▁"
            # (U+2581 lower one-eighth block) reads as "drop to the
            # bottom" — same convention TV editors and most modern
            # window chrome use for "minimize".
            var min_glyph: String
            if self.state == PANE_STATE_MINIMIZED:
                # Already minimized — show a "restore" glyph since this
                # button now restores instead of minimizes.
                min_glyph = String("□")
            else:
                min_glyph = String("▁")
            _paint_button(canvas, Point(min_x, top), border, min_glyph)
            # Maximize / restore. Glyph flips between "▣" (maximize)
            # and "□" (restore) so the button always shows what
            # clicking it would do next.
            var max_glyph: String
            if self.state == PANE_STATE_MAXIMIZED:
                max_glyph = String("□")
            else:
                max_glyph = String("▣")
            _paint_button(canvas, Point(max_x, top), border, max_glyph)
            _ = canvas.put_text(
                Point(panel.b.x - 3, top), String(" 9"), title,
            )
        elif pane_w >= 6:
            # Too narrow for buttons — fall back to just the focus
            # hint, same as before.
            _ = canvas.put_text(
                Point(panel.b.x - 3, top), String("9"), title,
            )
        # In MINIMIZED state we stop after the title bar — the rest of
        # the pane is hidden, the user reads the status in the
        # status-bar / window-tab strip until they restore.
        if self.state == PANE_STATE_MINIMIZED:
            self._last_inspect_y0 = top + 1
            self._last_output_y0 = top + 1
            self._last_divider_x = panel.a.x
            self._left_indices = List[Int]()
            self._right_indices = List[Int]()
            return
        # Status row (one line).
        var row_y = top + 1
        if row_y < panel.b.y and len(self.status_text.as_bytes()) > 0:
            _ = canvas.put_text(
                Point(panel.a.x + 2, row_y), self.status_text, dim,
                panel.b.x - 1,
            )
        # Compute the inspect/output split. In RUN mode the inspect
        # section would always be empty (no DAP stack frames to show),
        # so the pane collapses to Output-only and gives the full
        # content area to the log. In DEBUG mode we keep the original
        # 60% / 40% split with at least 2 output rows when the pane
        # is taller than 6.
        var content_top = top + 2
        var content_h = panel.b.y - content_top
        if content_h < 1:
            return
        var output_h: Int
        var inspect_h: Int
        if self.mode == PANE_MODE_RUN:
            output_h = content_h
            inspect_h = 0
        else:
            output_h = content_h * 4 // 10
            if output_h < 2 and content_h >= 6:
                output_h = 2
            if output_h > content_h - 2:
                output_h = content_h - 2
            if output_h < 0:
                output_h = 0
            inspect_h = content_h - output_h
        # Recompute the column membership from the row list each
        # paint — ``rows`` is rebuilt wholesale on stop, but expand /
        # collapse splices in place, so we can't rely on a stale
        # cache. Walks once, O(n).
        self._compute_columns()
        # Vertical divider — split panel width in two. Stack frames
        # tend to be shorter than locals, so 40/60 leaves more room
        # for variable trees.
        var pw = panel.b.x - panel.a.x
        var left_w = pw * 4 // 10
        if left_w < 14:
            left_w = 14 if pw >= 28 else pw // 2
        if left_w >= pw - 2:
            left_w = pw - 2
        if left_w < 0:
            left_w = 0
        var div_x = panel.a.x + left_w
        self._last_divider_x = div_x
        self._last_inspect_y0 = content_top
        # Vertical divider glyph for the inspect rows only (output
        # uses the full width).
        for y in range(content_top, content_top + inspect_h):
            if y < panel.b.y:
                canvas.set(div_x, y, Cell(String("│"), border, 1))
        var left_x_max = div_x
        var right_x0 = div_x + 1
        var right_x_max = panel.b.x
        # Left column (Stack).
        var left_visible = inspect_h
        if left_visible > len(self._left_indices) - self.stack_scroll:
            left_visible = len(self._left_indices) - self.stack_scroll
        if left_visible < 0:
            left_visible = 0
        for k in range(left_visible):
            var ridx = self._left_indices[self.stack_scroll + k]
            var r = self.rows[ridx]
            var y = content_top + k
            if r.kind == PANE_ROW_HEADER:
                _ = canvas.put_text(
                    Point(panel.a.x + 2, y), r.text + String(":"),
                    section, left_x_max,
                )
            elif r.kind == PANE_ROW_FRAME:
                var marker = String(" ")
                var attr = bg
                if r.depth == self.current_frame_index:
                    marker = String("▶")
                    attr = current
                _ = canvas.put_text(
                    Point(panel.a.x + 2, y),
                    String("  ") + marker + String(" ") + r.text,
                    attr, left_x_max,
                )
        # Right column (Locals + Watches).
        var right_visible = inspect_h
        if right_visible > len(self._right_indices) - self.right_scroll:
            right_visible = len(self._right_indices) - self.right_scroll
        if right_visible < 0:
            right_visible = 0
        for k in range(right_visible):
            var ridx = self._right_indices[self.right_scroll + k]
            var r = self.rows[ridx]
            var y = content_top + k
            if r.kind == PANE_ROW_HEADER:
                _ = canvas.put_text(
                    Point(right_x0 + 1, y), r.text + String(":"),
                    section, right_x_max,
                )
            elif r.kind == PANE_ROW_VARIABLE:
                var indent = String("")
                for _ in range(r.depth):
                    indent = indent + String("  ")
                var chev = String("  ")
                if r.ref_id != 0:
                    chev = String("▼ ") if r.expanded else String("▶ ")
                _ = canvas.put_text(
                    Point(right_x0 + 1, y),
                    indent + chev + r.text,
                    bg, right_x_max,
                )
            elif r.kind == PANE_ROW_WATCH:
                _ = canvas.put_text(
                    Point(right_x0 + 1, y),
                    String("  ") + r.text,
                    bg, right_x_max,
                )
            elif r.kind == PANE_ROW_BLANK:
                pass
        # Inspect / output divider — only meaningful in DEBUG mode.
        # In RUN mode there's no inspect section to divide off, and
        # the top title already says "Run", so the row is dropped and
        # output starts immediately under the status row.
        var out_top: Int
        if self.mode == PANE_MODE_RUN:
            out_top = content_top
        else:
            var div_y = content_top + inspect_h
            if div_y < panel.b.y and output_h > 0:
                for x in range(panel.a.x, panel.b.x):
                    canvas.set(x, div_y, Cell(String("─"), border, 1))
                _ = canvas.put_text(
                    Point(panel.a.x + 2, div_y), String(" Output "),
                    title, panel.b.x,
                )
            out_top = div_y + 1
        # Output lines (last visible window). Autoscroll places the
        # *most recent* line on the bottom row so eyes track new
        # output as it arrives.
        self._last_output_y0 = out_top
        var out_visible = panel.b.y - out_top
        if out_visible < 0:
            out_visible = 0
        var first = self.output_scroll - out_visible + 1
        if self.output_autoscroll:
            first = len(self.output_lines) - out_visible
        if first < 0:
            first = 0
        for k in range(out_visible):
            var idx = first + k
            if idx < 0 or idx >= len(self.output_lines):
                continue
            var line = self.output_lines[idx]
            var attr = bg
            if self.output_categories[idx] == PANE_OUT_STDERR:
                attr = stderr_attr
            elif self.output_categories[idx] == PANE_OUT_CONSOLE:
                attr = dim
            var line_x0 = panel.a.x + 2
            var line_y = out_top + k
            var line_x_max = panel.b.x - 1
            _ = canvas.put_text(
                Point(line_x0, line_y), line, attr, line_x_max,
            )
            # Overlay clickable file:line links — Python's
            # ``File "<path>", line N`` traceback frames. Done as a
            # post-pass via ``set_attr`` so the line keeps its glyphs
            # but the link cells get an underline + blue color the
            # eye reads as "this is clickable".
            var hits = _extract_python_traceback_links(line)
            for h in range(len(hits)):
                var hit = hits[h]
                var x0 = line_x0 + hit.cell_start
                var x1 = line_x0 + hit.cell_end
                if x0 >= line_x_max:
                    continue
                if x1 > line_x_max:
                    x1 = line_x_max
                if x1 <= x0:
                    continue
                for x in range(x0, x1):
                    canvas.set_attr(x, line_y, link_attr)
                self._last_links.append(OutputLink(
                    line_y, x0, x1, hit.path, hit.line,
                ))

    # --- input -----------------------------------------------------------

    fn is_on_resize_edge(self, pos: Point, panel: Rect) -> Bool:
        """Hit-test for the top-border row — the pane's drag handle.
        Used by the host to switch the mouse pointer to ``ns-resize``
        on hover. Resize is only available in NORMAL state, and the
        button cells (top-right) are excluded so the cursor stays as
        the default pointer over them."""
        if not self.visible or panel.is_empty():
            return False
        if self.state != PANE_STATE_NORMAL:
            return False
        if pos.y != panel.a.y:
            return False
        if pos.x < panel.a.x or pos.x >= panel.b.x:
            return False
        if self._on_button(pos):
            return False
        return True

    fn _on_button(self, pos: Point) -> Bool:
        """True iff ``pos`` falls on either of the title-row buttons
        drawn by the last ``paint`` call."""
        if self._last_min_btn_x >= 0 \
                and pos.x >= self._last_min_btn_x \
                and pos.x < self._last_min_btn_x + 3:
            return True
        if self._last_max_btn_x >= 0 \
                and pos.x >= self._last_max_btn_x \
                and pos.x < self._last_max_btn_x + 3:
            return True
        return False

    fn _on_min_button(self, pos: Point, panel_top: Int) -> Bool:
        return pos.y == panel_top \
            and self._last_min_btn_x >= 0 \
            and pos.x >= self._last_min_btn_x \
            and pos.x < self._last_min_btn_x + 3

    fn _on_max_button(self, pos: Point, panel_top: Int) -> Bool:
        return pos.y == panel_top \
            and self._last_max_btn_x >= 0 \
            and pos.x >= self._last_max_btn_x \
            and pos.x < self._last_max_btn_x + 3

    fn is_resizing(self) -> Bool:
        return self._resizing

    fn handle_mouse(mut self, event: Event, panel: Rect) -> Bool:
        """Return True if the click landed in the pane (consumed),
        False to let it fall through to the workspace."""
        if event.kind != EVENT_MOUSE:
            return False
        # Resize-drag: once started, every mouse event belongs to the
        # resize until the button is released — even when the cursor
        # leaves the original panel rect. Checked before the
        # contains() gate for that reason.
        if self._resizing:
            if event.button == MOUSE_BUTTON_LEFT and not event.pressed:
                self._resizing = False
                return True
            # ``panel.b.y`` is the fixed bottom anchor (one row above
            # the status bar); subtract the new top to get the desired
            # height. The pane refits next frame from the updated
            # ``preferred_height``.
            self.preferred_height = self._clamp_height(
                panel.b.y - event.pos.y, panel,
            )
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed and not event.motion:
            # Title-row buttons take priority over the resize-drag
            # handle. They sit on the same row as the drag edge but
            # have a finer hit area.
            if self._on_min_button(event.pos, panel.a.y):
                self.focused = True
                if self.state == PANE_STATE_MINIMIZED:
                    self.set_state(PANE_STATE_NORMAL)
                else:
                    self.set_state(PANE_STATE_MINIMIZED)
                return True
            if self._on_max_button(event.pos, panel.a.y):
                self.focused = True
                if self.state == PANE_STATE_MAXIMIZED:
                    self.set_state(PANE_STATE_NORMAL)
                else:
                    self.set_state(PANE_STATE_MAXIMIZED)
                return True
            # Drag-to-resize is only meaningful in NORMAL state. In
            # MINIMIZED / MAXIMIZED the height is dictated by state,
            # not by the user's preferred-height; the press just
            # focuses the pane.
            if self.state == PANE_STATE_NORMAL \
                    and event.pos.y == panel.a.y \
                    and event.pos.x >= panel.a.x and event.pos.x < panel.b.x:
                self._resizing = True
                return True
            if self.state != PANE_STATE_NORMAL \
                    and event.pos.y == panel.a.y \
                    and event.pos.x >= panel.a.x and event.pos.x < panel.b.x:
                # Click on the title row outside the buttons just
                # focuses the pane and is consumed.
                self.focused = True
                return True
        if not panel.contains(event.pos):
            # Bare hover under mouse-mode 1003 must not steal focus.
            if event.button != MOUSE_BUTTON_NONE and event.pressed and not event.motion:
                self.focused = False
            return False
        # Wheel routes to the section under the cursor — independent
        # scroll for the two inspect columns and the output is what
        # users expect.
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if event.pressed:
                var delta = -3 if event.button == MOUSE_WHEEL_UP else 3
                if event.pos.y >= self._last_output_y0:
                    self._scroll_output(delta)
                elif event.pos.x <= self._last_divider_x:
                    self._scroll_stack(delta)
                else:
                    self._scroll_right(delta)
            return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
            return True
        self.focused = True
        # Inspect-area click: map back to a row in the column the
        # click landed in.
        if event.pos.y >= self._last_inspect_y0 \
                and event.pos.y < self._last_output_y0 - 1:
            var col_offset = event.pos.y - self._last_inspect_y0
            if event.pos.x <= self._last_divider_x:
                var i = self.stack_scroll + col_offset
                if i >= 0 and i < len(self._left_indices):
                    self._on_row_click(self._left_indices[i])
            else:
                var i = self.right_scroll + col_offset
                if i >= 0 and i < len(self._right_indices):
                    self._on_row_click(self._right_indices[i])
        # Output-area click: stop autoscroll so the user can read
        # without lines sliding out from under them. Click again at
        # the bottom row to re-engage autoscroll.
        elif event.pos.y >= self._last_output_y0:
            # File:line link hit-test runs first — clicking on a
            # ``File "x", line N`` span should open the file rather
            # than toggle the autoscroll mode.
            for li in range(len(self._last_links)):
                var link = self._last_links[li]
                if event.pos.y == link.y \
                        and event.pos.x >= link.x_start \
                        and event.pos.x < link.x_end:
                    self.pending_open_path = link.path
                    self.pending_open_line = link.line
                    return True
            var visible = panel.b.y - self._last_output_y0
            var clicked = self.output_scroll - visible + 1 \
                + (event.pos.y - self._last_output_y0)
            if clicked >= len(self.output_lines) - 1:
                self.output_autoscroll = True
            else:
                self.output_autoscroll = False
                self.output_scroll = clicked
        return True

    fn handle_key(mut self, event: Event) -> Bool:
        """Arrow keys / PageUp / End scroll the focused pane.
        Returns True if the key was consumed."""
        if not self.focused:
            return False
        if event.kind != EVENT_KEY:
            return False
        # ESC walks the window-state ladder: maximized → normal →
        # minimized. Minimized is the terminal state — the pane has no
        # body to escape out of, and falling further (e.g. dismissing
        # the pane) belongs to the host's own ESC path, so we leave it
        # alone there.
        if event.key == KEY_ESC:
            if self.state == PANE_STATE_MAXIMIZED:
                self.set_state(PANE_STATE_NORMAL)
                return True
            if self.state == PANE_STATE_NORMAL:
                self.set_state(PANE_STATE_MINIMIZED)
                return True
            return False
        # Arrow keys drive the right column (locals + watches) since
        # that's where the deep / scrollable content lives. The stack
        # column rarely needs scrolling and reaches the user via
        # mouse wheel when it does.
        if event.key == KEY_UP:
            self._scroll_right(-1)
            return True
        if event.key == KEY_DOWN:
            self._scroll_right(1)
            return True
        if event.key == KEY_PAGEUP:
            self._scroll_right(-8)
            return True
        if event.key == KEY_PAGEDOWN:
            self._scroll_right(8)
            return True
        if event.key == KEY_HOME:
            self.stack_scroll = 0
            self.right_scroll = 0
            return True
        if event.key == KEY_END:
            self.output_autoscroll = True
            return True
        return False

    fn _clamp_height(self, want: Int, panel: Rect) -> Int:
        """Pin a proposed pane height to a usable range. Lower bound 4
        keeps the title bar, status row, and at least two content rows
        on screen; upper bound leaves at least 5 rows of workspace
        above the pane (menu bar + a couple of editor rows)."""
        var h = want
        var hi = panel.b.y - 5
        if h > hi:
            h = hi
        if h < 4:
            h = 4
        return h

    fn _on_row_click(mut self, row_idx: Int):
        var r = self.rows[row_idx]
        if r.kind == PANE_ROW_FRAME:
            self.pending_frame_id = r.ref_id
            self.pending_frame_index = r.depth
            self.current_frame_index = r.depth
        elif r.kind == PANE_ROW_VARIABLE and r.ref_id != 0:
            if r.expanded:
                self.pending_collapse_row = row_idx
            else:
                self.pending_expand_ref = r.ref_id
                self.pending_expand_row = row_idx
                self.pending_expand_depth = r.depth + 1

    fn _scroll_stack(mut self, delta: Int):
        var ns = self.stack_scroll + delta
        if ns < 0:
            ns = 0
        var max_s = len(self._left_indices) - 1
        if max_s < 0:
            max_s = 0
        if ns > max_s:
            ns = max_s
        self.stack_scroll = ns

    fn _scroll_right(mut self, delta: Int):
        var ns = self.right_scroll + delta
        if ns < 0:
            ns = 0
        var max_s = len(self._right_indices) - 1
        if max_s < 0:
            max_s = 0
        if ns > max_s:
            ns = max_s
        self.right_scroll = ns

    fn _compute_columns(mut self):
        """Partition ``rows`` into left (Stack) and right
        (Locals / Watches) absolute-index lists. The first HEADER row
        plus its trailing FRAME rows go left; everything else goes
        right. BLANK rows are skipped — column separation already
        delineates sections visually.
        """
        var left = List[Int]()
        var right = List[Int]()
        var seen_first_header = False
        var stack_section = True
        for i in range(len(self.rows)):
            var r = self.rows[i]
            if r.kind == PANE_ROW_BLANK:
                # Blanks separate sections in the linear layout; in
                # the column layout they're noise.
                continue
            if r.kind == PANE_ROW_HEADER:
                if not seen_first_header:
                    seen_first_header = True
                    left.append(i)
                else:
                    stack_section = False
                    right.append(i)
            elif r.kind == PANE_ROW_FRAME:
                if stack_section:
                    left.append(i)
                else:
                    right.append(i)
            else:
                stack_section = False
                right.append(i)
        self._left_indices = left^
        self._right_indices = right^

    fn _scroll_output(mut self, delta: Int):
        var ns = self.output_scroll + delta
        if ns < 0:
            ns = 0
        var max_s = len(self.output_lines) - 1
        if max_s < 0:
            max_s = 0
        if ns > max_s:
            ns = max_s
        # Manual scroll disengages autoscroll until the user releases
        # by hitting End or scrolling all the way down.
        self.output_autoscroll = (ns >= max_s)
        self.output_scroll = ns


# --- formatting helpers ---------------------------------------------------


fn _paint_button(
    mut canvas: Canvas, top_left: Point, border: Attr, glyph: String,
):
    """Three-cell window button — ``[X]`` — painted in the title row.
    Mirrors the close-button helper in ``window.mojo`` but with a
    caller-supplied glyph since the pane has multiple kinds of button
    (minimize / maximize / restore) sharing the same chrome."""
    var glyph_attr = Attr(LIGHT_YELLOW, border.bg, border.style)
    canvas.set(top_left.x, top_left.y, Cell(String("["), border, 1))
    canvas.set(top_left.x + 1, top_left.y, Cell(glyph, glyph_attr, 1))
    canvas.set(top_left.x + 2, top_left.y, Cell(String("]"), border, 1))


fn _format_variable(name: String, value: String, type_name: String) -> String:
    var type_str = String("")
    if len(type_name.as_bytes()) > 0:
        type_str = String(" (") + type_name + String(")")
    return name + String(" = ") + value + type_str


fn _basename(path: String) -> String:
    var b = path.as_bytes()
    var n = len(b)
    var i = n - 1
    while i >= 0:
        if b[i] == 0x2F:
            return String(StringSlice(
                ptr=b.unsafe_ptr() + i + 1, length=n - i - 1,
            ))
        i -= 1
    return path


fn _pad_right(s: String, width: Int) -> String:
    var n = len(s.as_bytes())
    if n >= width:
        if n > width:
            return String(StringSlice(
                ptr=s.as_bytes().unsafe_ptr(), length=width,
            ))
        return s
    var out = s
    for _ in range(width - n):
        out = out + String(" ")
    return out^


# --- output-link parser ---------------------------------------------------


@fieldwise_init
struct _LinkHit(ImplicitlyCopyable, Movable):
    """Bytes-resolved match for a single ``File "<path>", line N``
    occurrence. ``cell_start`` / ``cell_end`` are codepoint counts
    from the start of the line, matching how ``Canvas.put_text``
    advances columns — so callers can convert directly to screen X
    without redoing the UTF-8 walk."""
    var cell_start: Int
    var cell_end: Int    # exclusive
    var path: String
    var line: Int        # 1-based


fn _extract_python_traceback_links(line: String) -> List[_LinkHit]:
    """Find every ``File "<path>", line <N>`` span in ``line``.

    Matches Python's traceback format. The trailing ``, in <name>`` is
    optional — the link covers ``File "<path>", line <N>`` itself,
    leaving any ``in module`` suffix unhighlighted so the visual focus
    is on the navigable part. Quoted paths only (no shell-escape
    handling); a literal ``"`` in a path would terminate the match
    early, which is fine for ~all real-world paths.
    """
    var out = List[_LinkHit]()
    var bytes = line.as_bytes()
    var n = len(bytes)
    # Walk byte-by-byte, tracking the parallel codepoint count so we
    # can hand callers cell offsets directly. Continuation bytes
    # (10xx_xxxx) don't bump the cell counter.
    var i = 0
    var cell = 0
    while i < n:
        var b = Int(bytes[i])
        # Probe for the literal ``File "`` prefix on a codepoint
        # boundary. Always ASCII, so a byte compare is correct here.
        if b == 0x46 and i + 6 <= n \
                and bytes[i + 1] == 0x69 \
                and bytes[i + 2] == 0x6C \
                and bytes[i + 3] == 0x65 \
                and bytes[i + 4] == 0x20 \
                and bytes[i + 5] == 0x22:
            var match_start_cell = cell
            var p = i + 6
            var path_byte_start = p
            # Path runs until the next ``"``. Track cells alongside
            # bytes so the closing quote's cell offset is correct
            # even when the path contains multibyte characters.
            var path_cell_count = 0
            var found_quote = False
            while p < n:
                var pb = Int(bytes[p])
                if pb == 0x22:
                    found_quote = True
                    break
                if (pb & 0xC0) != 0x80:
                    path_cell_count += 1
                p += 1
            if not found_quote:
                # Drop out — no recognizable link starts here.
                cell += 1
                i += 1
                continue
            var path_byte_end = p
            # Past the closing quote.
            p += 1
            # Need exactly ``, line ``.
            if p + 7 > n \
                    or bytes[p] != 0x2C \
                    or bytes[p + 1] != 0x20 \
                    or bytes[p + 2] != 0x6C \
                    or bytes[p + 3] != 0x69 \
                    or bytes[p + 4] != 0x6E \
                    or bytes[p + 5] != 0x65 \
                    or bytes[p + 6] != 0x20:
                cell += 1
                i += 1
                continue
            p += 7
            # One or more ASCII digits — the line number.
            var digit_start = p
            var line_no = 0
            while p < n:
                var db = Int(bytes[p])
                if db >= 0x30 and db <= 0x39:
                    line_no = line_no * 10 + (db - 0x30)
                    p += 1
                else:
                    break
            if p == digit_start:
                cell += 1
                i += 1
                continue
            # Slice the path text out without re-decoding.
            var path = String(StringSlice(
                ptr=bytes.unsafe_ptr() + path_byte_start,
                length=path_byte_end - path_byte_start,
            ))
            # Cell offsets: prefix ``File "`` is 6 cells (all ASCII),
            # then the path, the closing ``"``, then ``, line `` (7
            # cells), then digit_count cells.
            var digit_count = p - digit_start
            var span_cells = 6 + path_cell_count + 1 + 7 + digit_count
            out.append(_LinkHit(
                match_start_cell, match_start_cell + span_cells,
                path, line_no,
            ))
            # Advance past the matched span. We've already moved ``p``
            # to the byte after the last digit; sync ``cell`` to the
            # span end (every byte we consumed in the suffix was ASCII
            # except the path body, whose cell count we tracked).
            cell = match_start_cell + span_cells
            i = p
            continue
        # Default codepoint advance: one cell per UTF-8 leader byte.
        if (b & 0xC0) != 0x80:
            cell += 1
        i += 1
    return out^


