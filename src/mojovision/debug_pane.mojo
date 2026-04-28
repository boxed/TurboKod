"""Bottom-docked debug pane: stack, locals tree, watches, output log.

Layout (when active, at the bottom of the workspace, above the status bar)::

    ─ Debug ────────────────────────────────────────────────
    DAP[debugpy]: stopped (breakpoint)
    Stack:
      ▶ main          foo.py:42
        handler       foo.py:17
    Locals:
      x = 42 (int)
    ▼ obj = <Foo>
        name = "alice" (str)
        age = 30 (int)
    Watches:
      len(items) = 4 (int)
    ─ Output ────────────────────────────────────────────────
    starting up...
    request 1 received
    response 200

The pane is split horizontally: the top portion is the "inspect" view
(stack + locals + watches), and the bottom portion is the output log.
Both are scrollable independently — arrow keys / wheel when the pane
is focused (focus is on click). Output autoscrolls to the end whenever
new lines arrive *unless* the user has scrolled up manually.

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
    Attr, BLACK, BLUE, CYAN, LIGHT_GRAY, LIGHT_RED, LIGHT_YELLOW,
    WHITE, YELLOW,
)
from .dap_dispatch import DapStackFrame, DapVariable
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
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

    var rows: List[PaneRow]
    """Inspect-view rows (status not included). Sectioned via
    ``PANE_ROW_HEADER`` markers."""

    var current_frame_index: Int
    """Which frame is highlighted in the Stack section (the one whose
    locals are showing). Bound to a frame's ``depth`` field, so a
    single int is enough to identify it."""

    var output_lines: List[String]
    var output_categories: List[UInt8]   # parallel to output_lines

    var inspect_scroll: Int
    """First inspect row to paint (within the inspect rect). Bumped by
    arrow keys / wheel."""
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

    # --- mouse-mapping bookkeeping ------------------------------------
    var _last_inspect_y0: Int   # screen y of inspect_rows[inspect_scroll]
    var _last_output_y0: Int

    fn __init__(out self):
        self.visible = False
        self.preferred_height = 14
        self.status_text = String("")
        self.rows = List[PaneRow]()
        self.current_frame_index = 0
        self.output_lines = List[String]()
        self.output_categories = List[UInt8]()
        self.inspect_scroll = 0
        self.output_scroll = 0
        self.output_autoscroll = True
        self.focused = False
        self.pending_frame_id = -1
        self.pending_frame_index = -1
        self.pending_expand_ref = -1
        self.pending_expand_row = -1
        self.pending_expand_depth = 0
        self.pending_collapse_row = -1
        self._last_inspect_y0 = 0
        self._last_output_y0 = 0

    fn __copyinit__(out self, copy: Self):
        self.visible = copy.visible
        self.preferred_height = copy.preferred_height
        self.status_text = copy.status_text
        self.rows = copy.rows.copy()
        self.current_frame_index = copy.current_frame_index
        self.output_lines = copy.output_lines.copy()
        self.output_categories = copy.output_categories.copy()
        self.inspect_scroll = copy.inspect_scroll
        self.output_scroll = copy.output_scroll
        self.output_autoscroll = copy.output_autoscroll
        self.focused = copy.focused
        self.pending_frame_id = copy.pending_frame_id
        self.pending_frame_index = copy.pending_frame_index
        self.pending_expand_ref = copy.pending_expand_ref
        self.pending_expand_row = copy.pending_expand_row
        self.pending_expand_depth = copy.pending_expand_depth
        self.pending_collapse_row = copy.pending_collapse_row
        self._last_inspect_y0 = copy._last_inspect_y0
        self._last_output_y0 = copy._last_output_y0

    # --- setters (used by Desktop) ---------------------------------------

    fn set_status(mut self, var text: String):
        self.status_text = text^

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
        self.inspect_scroll = 0

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
        self.inspect_scroll = 0

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
        canvas.fill(panel, String(" "), bg)
        # Top border with title.
        var top = panel.a.y
        for x in range(panel.a.x, panel.b.x):
            canvas.set(x, top, Cell(String("─"), border, 1))
        var title_text = String(" Debug ")
        if self.focused:
            title_text = String(" Debug (focused) ")
        _ = canvas.put_text(
            Point(panel.a.x + 2, top), title_text, title, panel.b.x,
        )
        # Status row (one line).
        var row_y = top + 1
        if row_y < panel.b.y and len(self.status_text.as_bytes()) > 0:
            _ = canvas.put_text(
                Point(panel.a.x + 2, row_y), self.status_text, dim,
                panel.b.x - 1,
            )
        # Compute the inspect/output split — 60% / 40%, with at least
        # 2 rows for output when the pane is taller than 6 rows.
        var content_top = top + 2
        var content_h = panel.b.y - content_top
        if content_h < 1:
            return
        var output_h = content_h * 4 // 10
        if output_h < 2 and content_h >= 6:
            output_h = 2
        if output_h > content_h - 2:
            output_h = content_h - 2
        if output_h < 0:
            output_h = 0
        var inspect_h = content_h - output_h
        # Inspect rows.
        self._last_inspect_y0 = content_top
        var max_visible = inspect_h
        if max_visible > len(self.rows) - self.inspect_scroll:
            max_visible = len(self.rows) - self.inspect_scroll
        if max_visible < 0:
            max_visible = 0
        for k in range(max_visible):
            var idx = self.inspect_scroll + k
            var r = self.rows[idx]
            var y = content_top + k
            if r.kind == PANE_ROW_HEADER:
                _ = canvas.put_text(
                    Point(panel.a.x + 2, y), r.text + String(":"),
                    section, panel.b.x - 1,
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
                    attr, panel.b.x - 1,
                )
            elif r.kind == PANE_ROW_VARIABLE:
                var indent = String("  ")
                for _ in range(r.depth):
                    indent = indent + String("  ")
                var chev = String("  ")
                if r.ref_id != 0:
                    chev = String("▼ ") if r.expanded else String("▶ ")
                _ = canvas.put_text(
                    Point(panel.a.x + 2, y),
                    indent + chev + r.text,
                    bg, panel.b.x - 1,
                )
            elif r.kind == PANE_ROW_WATCH:
                _ = canvas.put_text(
                    Point(panel.a.x + 2, y),
                    String("  ") + r.text,
                    bg, panel.b.x - 1,
                )
            elif r.kind == PANE_ROW_BLANK:
                pass
        # Inspect / output divider.
        var div_y = content_top + inspect_h
        if div_y < panel.b.y and output_h > 0:
            for x in range(panel.a.x, panel.b.x):
                canvas.set(x, div_y, Cell(String("─"), border, 1))
            _ = canvas.put_text(
                Point(panel.a.x + 2, div_y), String(" Output "),
                title, panel.b.x,
            )
        # Output lines (last visible window). Autoscroll places the
        # *most recent* line on the bottom row so eyes track new
        # output as it arrives.
        var out_top = div_y + 1
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
            _ = canvas.put_text(
                Point(panel.a.x + 2, out_top + k), line, attr,
                panel.b.x - 1,
            )

    # --- input -----------------------------------------------------------

    fn handle_mouse(mut self, event: Event, panel: Rect) -> Bool:
        """Return True if the click landed in the pane (consumed),
        False to let it fall through to the workspace."""
        if event.kind != EVENT_MOUSE:
            return False
        if not panel.contains(event.pos):
            self.focused = False
            return False
        # Wheel routes to the section under the cursor — independent
        # scroll for inspect vs output is what users expect.
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if event.pressed:
                var delta = -3 if event.button == MOUSE_WHEEL_UP else 3
                if event.pos.y >= self._last_output_y0:
                    self._scroll_output(delta)
                else:
                    self._scroll_inspect(delta)
            return True
        if event.button != MOUSE_BUTTON_LEFT or not event.pressed:
            return True
        self.focused = True
        # Inspect-area click: map back to a row.
        if event.pos.y >= self._last_inspect_y0 \
                and event.pos.y < self._last_output_y0 - 1:
            var row_idx = self.inspect_scroll \
                + (event.pos.y - self._last_inspect_y0)
            if row_idx >= 0 and row_idx < len(self.rows):
                self._on_row_click(row_idx)
        # Output-area click: stop autoscroll so the user can read
        # without lines sliding out from under them. Click again at
        # the bottom row to re-engage autoscroll.
        elif event.pos.y >= self._last_output_y0:
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
        if event.key == KEY_UP:
            self._scroll_inspect(-1)
            return True
        if event.key == KEY_DOWN:
            self._scroll_inspect(1)
            return True
        if event.key == KEY_PAGEUP:
            self._scroll_inspect(-8)
            return True
        if event.key == KEY_PAGEDOWN:
            self._scroll_inspect(8)
            return True
        if event.key == KEY_HOME:
            self.inspect_scroll = 0
            return True
        if event.key == KEY_END:
            self.output_autoscroll = True
            return True
        return False

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

    fn _scroll_inspect(mut self, delta: Int):
        var ns = self.inspect_scroll + delta
        if ns < 0:
            ns = 0
        var max_s = len(self.rows) - 1
        if max_s < 0:
            max_s = 0
        if ns > max_s:
            ns = max_s
        self.inspect_scroll = ns

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


