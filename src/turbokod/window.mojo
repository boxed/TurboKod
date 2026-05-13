"""Window: a managed sub-window with TV-style chrome (close, resize, move).

A ``Window`` is a value-typed widget: title, rect, and a list of content lines.
A ``WindowManager`` owns a stack of them and handles the tedious bits — z-order,
focus, click-to-front, drag-by-title-bar, resize-by-grip, close-by-button — so
the application code only has to construct them and react to higher-level events.

Visual style is hard-coded to classic Turbo Vision: white border on blue, yellow
content text, ``[■]`` close in the top-left, window number in the top-right,
``◢`` resize grip in the bottom-right.
"""

from std.collections.list import List

from .canvas import Canvas, paint_drop_shadow, popup_size_for_text
from .painter import Painter
from .cell import Cell
from .colors import Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, LIGHT_YELLOW, WHITE, YELLOW
from .editor import (
    EXT_CHANGE_CONFLICT, EXT_CHANGE_MERGED, EXT_CHANGE_NONE,
    EXT_CHANGE_RELOADED, Editor,
)
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import basename, parent_path
from .geometry import Point, Rect
from .scrollbar import HScrollbar, VScrollbar


comptime MIN_WIN_W: Int = 10
comptime MIN_WIN_H: Int = 2
# MIN_WIN_W = 3 (close button [■]) + 5 (single-digit indicator =[▲])
# + 2 borders, so both chrome buttons always fit in a min-width window.
# Two-digit window numbers drop the maximize indicator down to the bare
# number — the dynamic checks in ``Window.paint`` already handle that.
# MIN_WIN_H = 2 is the smallest height that can render top + bottom
# borders simultaneously; the interior is empty at that height.


fn _grow_to_min(rect: Rect) -> Rect:
    """Extend ``rect`` toward bottom-right so it is at least
    ``MIN_WIN_W`` wide and ``MIN_WIN_H`` tall. Used at construction
    time, before there's a workspace to clamp against."""
    var bx = rect.b.x
    var by = rect.b.y
    if bx - rect.a.x < MIN_WIN_W:
        bx = rect.a.x + MIN_WIN_W
    if by - rect.a.y < MIN_WIN_H:
        by = rect.a.y + MIN_WIN_H
    return Rect(rect.a.x, rect.a.y, bx, by)


fn _fit_min_in_workspace(rect: Rect, workspace: Rect) -> Rect:
    """Return ``rect`` grown to at least ``MIN_WIN_W`` x ``MIN_WIN_H``,
    extending toward bottom-right; if that would push past
    ``workspace``, pull the top-left back the rest of the way.
    When ``workspace`` itself is smaller than the minimum along an
    axis, the result is clamped to ``workspace`` along that axis —
    a 5-column terminal can't host a 10-column window, so the
    invariant degrades gracefully rather than crashing."""
    var ax = rect.a.x
    var ay = rect.a.y
    var bx = rect.b.x
    var by = rect.b.y
    if bx - ax < MIN_WIN_W:
        bx = ax + MIN_WIN_W
        if bx > workspace.b.x:
            bx = workspace.b.x
            ax = bx - MIN_WIN_W
            if ax < workspace.a.x:
                ax = workspace.a.x
    if by - ay < MIN_WIN_H:
        by = ay + MIN_WIN_H
        if by > workspace.b.y:
            by = workspace.b.y
            ay = by - MIN_WIN_H
            if ay < workspace.a.y:
                ay = workspace.a.y
    return Rect(ax, ay, bx, by)


fn _scale_coord(c: Int, old_origin: Int, old_size: Int, new_origin: Int, new_size: Int) -> Int:
    """Map ``c`` from ``[old_origin, old_origin + old_size]`` to
    ``[new_origin, new_origin + new_size]`` with round-half-up. Two
    inputs at the same value map to the same output, which is what
    keeps adjacent-window seams seamless after a workspace rescale."""
    var offset = c - old_origin
    var scaled: Int
    if offset >= 0:
        scaled = (offset * new_size + old_size // 2) // old_size
    else:
        # Negative offsets (windows positioned outside the old workspace)
        # are vanishingly rare but possible during edge transitions —
        # mirror the round-half-up rule symmetrically around zero so the
        # mapping stays monotonic.
        scaled = -((-offset * new_size + old_size // 2) // old_size)
    return new_origin + scaled


fn _scale_rect(r: Rect, old_ws: Rect, new_ws: Rect) -> Rect:
    """Apply ``_scale_coord`` to all four edges of ``r``, then clamp
    inside ``new_ws`` and guarantee at least one cell along each axis
    so the result is always a non-empty rect."""
    var old_w = old_ws.width()
    var old_h = old_ws.height()
    var new_w = new_ws.width()
    var new_h = new_ws.height()
    var ax = _scale_coord(r.a.x, old_ws.a.x, old_w, new_ws.a.x, new_w)
    var bx = _scale_coord(r.b.x, old_ws.a.x, old_w, new_ws.a.x, new_w)
    var ay = _scale_coord(r.a.y, old_ws.a.y, old_h, new_ws.a.y, new_h)
    var by = _scale_coord(r.b.y, old_ws.a.y, old_h, new_ws.a.y, new_h)
    if ax < new_ws.a.x: ax = new_ws.a.x
    if ay < new_ws.a.y: ay = new_ws.a.y
    if bx > new_ws.b.x: bx = new_ws.b.x
    if by > new_ws.b.y: by = new_ws.b.y
    if bx <= ax: bx = ax + 1
    if by <= ay: by = ay + 1
    if bx > new_ws.b.x:
        bx = new_ws.b.x
        if ax >= bx: ax = bx - 1
        if ax < new_ws.a.x: ax = new_ws.a.x
    if by > new_ws.b.y:
        by = new_ws.b.y
        if ay >= by: ay = by - 1
        if ay < new_ws.a.y: ay = new_ws.a.y
    return _fit_min_in_workspace(Rect(ax, ay, bx, by), new_ws)


fn paint_close_button(mut canvas: Canvas, top_left: Point, border: Attr):
    """Draw the ``[■]`` close-button decoration at a frame's top-LEFT
    corner. ``top_left`` is the frame's top-left cell — the bracket
    starts one column in. ``border`` is the frame's existing border
    attr; the brackets reuse it so they blend into the title bar,
    and the green ■ glyph reuses ``border.bg`` so the same helper
    works on any frame colour (blue editor windows, light-gray
    dialogs, …) without the caller having to thread a separate
    glyph attr through.

    Framework feature: dialogs as well as windows pull this in so
    the close affordance lives in the same place everywhere.
    """
    var glyph_attr = Attr(GREEN, border.bg, border.style)
    canvas.set(
        top_left.x + 1, top_left.y, Cell(String("["), border, 1),
    )
    canvas.set(
        top_left.x + 2, top_left.y, Cell(String("■"), glyph_attr, 1),
    )
    canvas.set(
        top_left.x + 3, top_left.y, Cell(String("]"), border, 1),
    )


fn hit_close_button(top_left: Point, p: Point) -> Bool:
    """Hit-test counterpart for ``paint_close_button``: True iff
    ``p`` lies on any of the three cells the button paints. Named
    ``hit_*`` rather than ``*_hit`` so the free function doesn't
    shadow ``Window.close_button_hit``, which keeps the method
    form for backwards compat with ``WindowManager``.
    """
    return p.y == top_left.y \
        and top_left.x + 1 <= p.x and p.x <= top_left.x + 3


fn paint_window_title(
    mut canvas: Canvas, rect: Rect, title: String,
    title_attr: Attr, body_bg: Attr,
):
    """Paint a centered title on the top border row of ``rect``.

    Framework rule: a window's title shares the body's background
    colour, so the label blends into the rest of the window instead
    of appearing as a separately-coloured bar. The helper composes
    ``Attr(title_attr.fg, body_bg.bg, title_attr.style)`` — callers
    pass whatever foreground/style they want (focus tinting, brighter
    headline colour, …) and the framework picks up the bg, so the
    rule can't drift even if a caller's ``title_attr`` carries a stale
    bg from copy-paste.
    """
    var enforced = Attr(title_attr.fg, body_bg.bg, title_attr.style)
    var title_len = len(title.as_bytes())
    if rect.width() < title_len + 2:
        return
    var tx = rect.a.x + (rect.width() - title_len) // 2
    _ = canvas.put_text(Point(tx, rect.a.y), title, enforced)


fn paint_window_title_at(
    mut canvas: Canvas, p: Point, title: String,
    title_attr: Attr, body_bg: Attr,
):
    """Paint a title at ``p`` instead of centred on a row.

    Same framework rule as ``paint_window_title``: the title's bg is
    forced to ``body_bg.bg``. For windows whose title isn't centred
    on the top edge (e.g. ``InstallRunner``'s left-aligned banner
    paired with a right-aligned spinner).
    """
    var enforced = Attr(title_attr.fg, body_bg.bg, title_attr.style)
    _ = canvas.put_text(p, title, enforced)


@fieldwise_init
struct TitleCommand(ImplicitlyCopyable, Movable):
    """One clickable label rendered on a panel/window's title row,
    after the title and a ``- `` separator.

    ``label`` is painted verbatim — wrap with ``[...]`` for a
    bracketed-button look, or include a leading glyph to mimic
    Turbo Vision's icon-buttons. ``id`` is the caller's discriminant;
    ``hit_title_command`` returns it so the click handler can
    dispatch. Empty ``id`` is reserved (means "no hit"), so callers
    must use a non-empty string for every real command.
    """
    var label: String
    var id: String


@fieldwise_init
struct TitleCommandHit(ImplicitlyCopyable, Movable):
    """Painted-rect record for one ``TitleCommand``. ``y`` is the
    title row, ``x_start`` is inclusive, ``x_end`` is exclusive.
    Returned in paint order from ``paint_title_commands``; commands
    that the helper had to truncate are dropped so a click on a
    half-painted label can't fire."""
    var id: String
    var y: Int
    var x_start: Int
    var x_end: Int


fn _label_cell_count(s: String) -> Int:
    """Codepoint count of ``s`` — matches the per-codepoint advance
    ``Canvas.put_text`` uses, so a label's painted width equals this
    when nothing was clipped."""
    var b = s.as_bytes()
    var n = len(b)
    var cells = 0
    var i = 0
    while i < n:
        var c = Int(b[i])
        if (c & 0xC0) != 0x80:
            cells += 1
        i += 1
    return cells


fn paint_title_commands(
    mut canvas: Canvas, p: Point,
    commands: List[TitleCommand],
    sep_attr: Attr, cmd_attr: Attr, body_bg: Attr,
    max_x: Int,
) -> List[TitleCommandHit]:
    """Paint a ``- <cmd1> <cmd2>...`` strip starting at ``p``.

    Caller is responsible for painting the title itself; this helper
    only renders the leading ``- `` separator and the commands. The
    framework rule (mirroring ``paint_window_title``) is enforced
    here too: separator and command bg are clamped to ``body_bg.bg``
    so the strip blends into the title row regardless of the focus
    tint the caller passes in.

    A one-cell gap is inserted between consecutive commands. Labels
    that don't fully fit before ``max_x`` are skipped — the returned
    list contains only commands the user can see end-to-end, so a
    click never fires on a label whose hint half is off-screen.
    """
    var hits = List[TitleCommandHit]()
    if len(commands) == 0:
        return hits^
    var enforced_sep = Attr(sep_attr.fg, body_bg.bg, sep_attr.style)
    var enforced_cmd = Attr(cmd_attr.fg, body_bg.bg, cmd_attr.style)
    var x = p.x
    if x + 2 > max_x:
        return hits^
    _ = canvas.put_text(
        Point(x, p.y), String("- "), enforced_sep, max_x,
    )
    x += 2
    for i in range(len(commands)):
        var c = commands[i]
        var label_cells = _label_cell_count(c.label)
        if x + label_cells > max_x:
            break
        var x0 = x
        var advanced = canvas.put_text(
            Point(x, p.y), c.label, enforced_cmd, max_x,
        )
        if advanced != label_cells:
            break
        x += advanced
        hits.append(TitleCommandHit(c.id, p.y, x0, x))
        if i < len(commands) - 1:
            if x + 1 > max_x:
                break
            x += 1
    return hits^


fn hit_title_command(
    hits: List[TitleCommandHit], pos: Point,
) -> String:
    """Returns the ``id`` of the command at ``pos``, or empty string
    when ``pos`` falls on no command. Mirror of ``hit_close_button``
    — kept as a free function so callers don't need a struct method
    just to do the contains-check on a list of rects."""
    for i in range(len(hits)):
        var h = hits[i]
        if pos.y == h.y \
                and pos.x >= h.x_start \
                and pos.x < h.x_end:
            return h.id
    return String("")


# --- panel chrome (min/max/restore) ---------------------------------------
# A "panel" here is a docked widget with a title row that can collapse to
# a single header (MINIMIZED), expand to fill the workspace (MAXIMIZED),
# or sit at its caller-defined size (NORMAL). The state machine + button
# chrome live in window.mojo so every panel — debug pane, git viewer, any
# future docked widget — paints the same affordance in the same slot and
# dispatches clicks the same way.

comptime PANEL_STATE_NORMAL    = UInt8(0)
comptime PANEL_STATE_MINIMIZED = UInt8(1)
comptime PANEL_STATE_MAXIMIZED = UInt8(2)


fn paint_panel_button(
    mut canvas: Canvas, painter: Painter,
    top_left: Point, border: Attr, glyph: String,
):
    """Three-cell ``[<glyph>]`` chrome button painted in a panel's title
    row. Mirrors ``paint_close_button`` but with a caller-supplied glyph
    so the same helper renders min, max, and restore buttons. Routed
    through ``painter`` so a button drawn near the panel edge clips
    against the panel bounds rather than leaking onto a neighbouring
    widget."""
    var glyph_attr = Attr(LIGHT_YELLOW, border.bg, border.style)
    painter.set(canvas, top_left.x, top_left.y, Cell(String("["), border, 1))
    painter.set(canvas, top_left.x + 1, top_left.y, Cell(glyph, glyph_attr, 1))
    painter.set(canvas, top_left.x + 2, top_left.y, Cell(String("]"), border, 1))


@fieldwise_init
struct PanelChromeHits(ImplicitlyCopyable, Movable):
    """Painted-rect record for the panel min/max chrome buttons. ``-1``
    on either x means that button wasn't painted this frame (panel too
    narrow, or caller asked for max-only) — hit-tests against ``-1``
    always miss. Callers store one of these per paint and consult it
    from ``handle_mouse``."""
    var top_y: Int
    var min_btn_x: Int
    var max_btn_x: Int

    fn __init__(out self):
        self.top_y = -1
        self.min_btn_x = -1
        self.max_btn_x = -1

    fn on_min(self, pos: Point) -> Bool:
        return self.min_btn_x >= 0 \
            and pos.y == self.top_y \
            and pos.x >= self.min_btn_x \
            and pos.x < self.min_btn_x + 3

    fn on_max(self, pos: Point) -> Bool:
        return self.max_btn_x >= 0 \
            and pos.y == self.top_y \
            and pos.x >= self.max_btn_x \
            and pos.x < self.max_btn_x + 3

    fn on_any(self, pos: Point) -> Bool:
        return self.on_min(pos) or self.on_max(pos)


fn paint_panel_window_buttons(
    mut canvas: Canvas, painter: Painter,
    top_y: Int, panel: Rect,
    state: UInt8, border: Attr,
    trailing_reserve: Int = 0,
    show_minimize: Bool = True,
) -> PanelChromeHits:
    """Paint the standard min/max chrome buttons at the right of a
    panel's title row.

    Buttons are 3 cells each. Layout (from the right edge of ``panel``):
    ``[trailing_reserve cells][maximize button][minimize button]``. The
    ``trailing_reserve`` argument lets callers reserve space for a
    keyboard-shortcut hint (the debug pane uses ``2`` for `` 9``).

    Glyphs flip between the action and its reverse so the user always
    sees what the *next* click will do: ``▣`` maximize / ``□`` restore;
    ``▁`` minimize / ``□`` restore. When ``show_minimize`` is False the
    minimize button is omitted (panels that have no meaningful collapsed
    state — e.g. a modal that intercepts all input — still want the
    maximize/restore toggle).

    Returns a ``PanelChromeHits`` recording the painted x positions so
    the caller's ``handle_mouse`` can dispatch clicks. When the panel is
    too narrow to hold the buttons + reserve, returns an empty hit
    record (everything ``-1``) without painting."""
    var hits = PanelChromeHits()
    hits.top_y = top_y
    var pane_w = panel.b.x - panel.a.x
    var slots = 6 if show_minimize else 3
    if pane_w < slots + trailing_reserve:
        return hits^
    var max_x = panel.b.x - 3 - trailing_reserve
    hits.max_btn_x = max_x
    var max_glyph: String
    if state == PANEL_STATE_MAXIMIZED:
        max_glyph = String("□")
    else:
        max_glyph = String("▣")
    paint_panel_button(canvas, painter, Point(max_x, top_y), border, max_glyph)
    if show_minimize:
        var min_x = max_x - 3
        hits.min_btn_x = min_x
        var min_glyph: String
        if state == PANEL_STATE_MINIMIZED:
            min_glyph = String("□")
        else:
            min_glyph = String("▁")
        paint_panel_button(
            canvas, painter, Point(min_x, top_y), border, min_glyph,
        )
    return hits^


# --- docked panel stack ---------------------------------------------------
# A "docked panel stack" is a vertical column of N section panels with
# splitters between them — used for the sidebar of a multi-section
# widget (LocalChanges Files/Branches/Commits, file browsers, outline
# views, ...). Each section has its own min/max chrome and renders a
# title bar that stays visible even when collapsed to one row. At most
# one section may be MAXIMIZED; when one is, the others paint as
# MINIMIZED so the user can still see what's there and click to bring
# them back.
#
# This is the framework half of the feature. Hosts (LocalChanges et al)
# add named sections, then on each frame:
#   1. call ``layout(top, bottom)`` to get per-section [top, h] pairs,
#   2. paint each section's body inside the rect they own,
#   3. call ``paint_headers(...)`` once to overlay all title bars +
#      chrome buttons on top of the bodies (so headers always win),
#   4. on a left-click, call ``hit_chrome(pos)`` and route the result
#      back into ``toggle_max(idx)`` / ``toggle_min(idx)``.


@fieldwise_init
struct DockedSection(ImplicitlyCopyable, Movable):
    """One section in a ``DockedPanelStack``. ``title`` is the bar text;
    ``state`` is the per-section min/max state; ``chrome_hits`` is
    refreshed by ``paint_headers`` so the next click can dispatch."""
    var title: String
    var state: UInt8
    var chrome_hits: PanelChromeHits

    fn __init__(out self, var title: String):
        self.title = title^
        self.state = PANEL_STATE_NORMAL
        self.chrome_hits = PanelChromeHits()


@fieldwise_init
struct DockChromeHit(ImplicitlyCopyable, Movable):
    """Result of ``DockedPanelStack.hit_chrome``. ``section_idx`` is -1
    on a miss; ``is_max`` distinguishes the maximize vs minimize
    button so the dispatch can call the right toggle."""
    var section_idx: Int
    var is_max: Bool

    fn __init__(out self):
        self.section_idx = -1
        self.is_max = False

    fn hit(self) -> Bool:
        return self.section_idx >= 0


struct DockedPanelStack(Movable):
    """Stack of vertically-tiled docked panels with min/max chrome.

    Owns the per-section state and produces a state-driven layout.
    State invariants:

    * At most one section may be MAXIMIZED. When one is, the layout
      coalesces the others to MINIMIZED for painting (their stored
      state is preserved so a "restore all" returns them to NORMAL).
    * MIN sections render header-only (height 1).
    * NORMAL sections share the leftover content rows equally.
    """
    var sections: List[DockedSection]

    fn __init__(out self):
        self.sections = List[DockedSection]()

    fn __copyinit__(out self, copy: Self):
        self.sections = copy.sections.copy()

    fn add(mut self, var title: String) -> Int:
        """Append a section, return its 0-based index."""
        self.sections.append(DockedSection(title^))
        return len(self.sections) - 1

    fn count(self) -> Int:
        return len(self.sections)

    fn state(self, idx: Int) -> UInt8:
        if idx < 0 or idx >= len(self.sections):
            return PANEL_STATE_NORMAL
        return self.sections[idx].state

    fn effective_states(self) -> List[UInt8]:
        """Resolve visual state per section. If any section is
        MAXIMIZED, the others paint as MINIMIZED regardless of their
        stored state. Otherwise returns each section's stored state
        verbatim."""
        var max_idx = -1
        for i in range(len(self.sections)):
            if self.sections[i].state == PANEL_STATE_MAXIMIZED:
                max_idx = i
                break
        var out = List[UInt8]()
        for i in range(len(self.sections)):
            if max_idx >= 0:
                if i == max_idx:
                    out.append(PANEL_STATE_MAXIMIZED)
                else:
                    out.append(PANEL_STATE_MINIMIZED)
            else:
                out.append(self.sections[i].state)
        return out^

    fn all_normal(self) -> Bool:
        """True iff every section is in PANEL_STATE_NORMAL — used by
        callers to decide whether splitter-drag should be active."""
        for i in range(len(self.sections)):
            if self.sections[i].state != PANEL_STATE_NORMAL:
                return False
        return True

    fn layout(self, top: Int, bottom: Int) -> List[Int]:
        """Return ``[s0_top, s0_h, s1_top, s1_h, ...]`` — per-section
        ``(top, height)`` pairs. One splitter row between each pair is
        not counted in any section's height; caller paints the splitter
        at ``s_i_top + s_i_h``.

        Section heights honor the effective state machine: MIN → 1,
        NORMAL → equal share of leftover, MAXIMIZED → all remaining
        space after MIN siblings consume their headers."""
        var n = len(self.sections)
        var out = List[Int]()
        if n == 0:
            return out^
        var splitters = n - 1
        if splitters < 0: splitters = 0
        var total = bottom - top
        if total < n:
            total = n
        var content = total - splitters
        if content < n:
            content = n
        var states = self.effective_states()
        var any_non_normal = False
        for i in range(n):
            if states[i] != PANEL_STATE_NORMAL:
                any_non_normal = True
                break
        var heights = List[Int]()
        for _ in range(n):
            heights.append(0)
        if any_non_normal:
            var n_min = 0
            var n_normal = 0
            for i in range(n):
                if states[i] == PANEL_STATE_MINIMIZED:
                    n_min += 1
                elif states[i] == PANEL_STATE_NORMAL:
                    n_normal += 1
            var leftover = content - n_min
            if leftover < 0: leftover = 0
            var normal_share: Int
            if n_normal > 0:
                normal_share = leftover // n_normal
                if normal_share < 1: normal_share = 1
            else:
                normal_share = 0
            for i in range(n):
                if states[i] == PANEL_STATE_MINIMIZED:
                    heights[i] = 1
                elif states[i] == PANEL_STATE_NORMAL:
                    heights[i] = normal_share
                else:
                    heights[i] = -1  # MAXIMIZED — fill leftover
            var used = 0
            for i in range(n):
                if heights[i] > 0:
                    used += heights[i]
            var remaining = content - used
            if remaining < 1: remaining = 1
            for i in range(n):
                if heights[i] < 0:
                    heights[i] = remaining
                    break
        else:
            var share = content // n
            if share < 1: share = 1
            for i in range(n - 1):
                heights[i] = share
            var rest = content - share * (n - 1)
            if rest < 1: rest = 1
            heights[n - 1] = rest
        var y = top
        for i in range(n):
            out.append(y)
            out.append(heights[i])
            y += heights[i] + 1  # +1 for splitter between sections
        return out^

    fn paint_headers(
        mut self, mut canvas: Canvas,
        left: Int, right_excl: Int,
        layout: List[Int],
        section_attr: Attr,
        focused_idx: Int = -1,
    ):
        """Paint each section's title bar with a one-row bright fill,
        the centered (via marker) title, and the min/max chrome buttons
        at the right edge. Refreshes ``chrome_hits`` on each section so
        the next click can dispatch.

        ``focused_idx`` (default -1) lights the matching section's title
        with a ``> `` marker — pass the host's currently-focused section
        index, or ``-1`` to skip the focus marker entirely.

        The header is painted inside ``[left, right_excl)`` and clips
        to that range via a Painter, so a too-narrow column collapses
        the buttons gracefully (they just don't paint).
        """
        var n = len(self.sections)
        var states = self.effective_states()
        for i in range(n):
            var top = layout[i * 2]
            # Header always paints, even when the section's effective
            # height is 1 (header-only): the title strip is the bit the
            # user clicks to restore.
            var header_rect = Rect(left, top, right_excl, top + 1)
            if header_rect.width() < 1:
                continue
            var p = Painter(header_rect)
            p.fill(canvas, header_rect, String(" "), section_attr)
            var marker: String
            if focused_idx == i:
                marker = String("> ")
            else:
                marker = String("  ")
            _ = p.put_text(
                canvas, Point(left, top),
                marker + self.sections[i].title, section_attr,
            )
            self.sections[i].chrome_hits = paint_panel_window_buttons(
                canvas, p, top, header_rect,
                states[i], section_attr,
            )

    fn toggle_max(mut self, idx: Int):
        """Click on section ``idx``'s maximize/restore button.

        Toggles between MAXIMIZED and NORMAL on ``idx``. Setting one to
        MAXIMIZED forces all others to NORMAL (the effective-states
        resolver paints them as MINIMIZED for the duration of the max).
        Restoring from MAXIMIZED resets every section to NORMAL so the
        original splitter-driven layout returns."""
        if idx < 0 or idx >= len(self.sections):
            return
        if self.sections[idx].state == PANEL_STATE_MAXIMIZED:
            for i in range(len(self.sections)):
                self.sections[i].state = PANEL_STATE_NORMAL
            return
        for i in range(len(self.sections)):
            self.sections[i].state = PANEL_STATE_NORMAL
        self.sections[idx].state = PANEL_STATE_MAXIMIZED

    fn toggle_min(mut self, idx: Int):
        """Click on section ``idx``'s minimize/restore button.

        Toggles between MINIMIZED and NORMAL on the targeted section.
        If a sibling was MAXIMIZED, that maximize is cleared (the user
        is overriding the max state by directly poking a min button).
        Visually-min'd sections of a maximized stack route here too —
        their click acts as "restore everything to NORMAL" since
        clicking restore on a min button on top of a max-collapsed
        sibling is the user's signal to back out of max mode."""
        if idx < 0 or idx >= len(self.sections):
            return
        var states = self.effective_states()
        var effective = states[idx]
        for i in range(len(self.sections)):
            if i != idx and self.sections[i].state == PANEL_STATE_MAXIMIZED:
                self.sections[i].state = PANEL_STATE_NORMAL
        if effective == PANEL_STATE_MINIMIZED:
            self.sections[idx].state = PANEL_STATE_NORMAL
            return
        self.sections[idx].state = PANEL_STATE_MINIMIZED

    fn reset(mut self):
        """Restore every section to NORMAL. Useful on close/reopen."""
        for i in range(len(self.sections)):
            self.sections[i].state = PANEL_STATE_NORMAL
            self.sections[i].chrome_hits = PanelChromeHits()

    fn hit_chrome(self, pos: Point) -> DockChromeHit:
        """Return the section + button under ``pos``. Returns a hit
        with ``section_idx == -1`` if the click misses every chrome
        button. Hosts call this from ``handle_mouse`` and route to
        ``toggle_max`` / ``toggle_min``."""
        var out = DockChromeHit()
        for i in range(len(self.sections)):
            if self.sections[i].chrome_hits.on_max(pos):
                out.section_idx = i
                out.is_max = True
                return out^
            if self.sections[i].chrome_hits.on_min(pos):
                out.section_idx = i
                out.is_max = False
                return out^
        return out^


struct Window(ImplicitlyCopyable, Movable):
    var title: String
    var rect: Rect
    var content: List[String]
    var editor: Editor          # only used when ``is_editor`` is True
    var is_editor: Bool
    var is_maximized: Bool
    var _restore_rect: Rect
    # Proportional-resize baselines. ``_baseline_rect`` is the rect we
    # want to preserve as the workspace changes, expressed in
    # ``_baseline_ws``; on each terminal resize we scale from this pair
    # (not from the current rect) so a shrink-then-grow round trip
    # lands back exactly where we started instead of accumulating
    # rounding error. ``_has_baseline`` is false until ``WindowManager``
    # observes the workspace for the first time and seeds the baseline
    # — newly-constructed windows don't know what workspace they were
    # created in. ``_last_observed_rect`` is the rect at the end of the
    # previous ``fit_into`` pass; if it differs at the start of the
    # next pass (and the workspace hasn't changed), a user action has
    # mutated the rect and the baseline gets rebased.
    var _baseline_rect: Rect
    var _baseline_ws: Rect
    var _has_baseline: Bool
    var _last_observed_rect: Rect

    fn __init__(out self, var title: String, rect: Rect, var content: List[String]):
        self.title = title^
        var sized = _grow_to_min(rect)
        self.rect = sized
        self.content = content^
        self.editor = Editor()
        self.is_editor = False
        self.is_maximized = False
        self._restore_rect = sized
        self._baseline_rect = sized
        self._baseline_ws = Rect.empty()
        self._has_baseline = False
        self._last_observed_rect = sized

    @staticmethod
    fn editor_window(var title: String, rect: Rect, var text: String) -> Self:
        """Convenience constructor for an editable text window."""
        var w = Window(title^, rect, List[String]())
        w.editor = Editor(text^)
        w.is_editor = True
        return w^

    @staticmethod
    fn from_file(var title: String, rect: Rect, var path: String) raises -> Self:
        """Open a file as an editor window, with external-change detection."""
        var w = Window(title^, rect, List[String]())
        w.editor = Editor.from_file(path^)
        w.is_editor = True
        return w^

    fn __copyinit__(out self, copy: Self):
        self.title = copy.title
        self.rect = copy.rect
        self.content = copy.content.copy()
        self.editor = copy.editor
        self.is_editor = copy.is_editor
        self.is_maximized = copy.is_maximized
        self._restore_rect = copy._restore_rect
        self._baseline_rect = copy._baseline_rect
        self._baseline_ws = copy._baseline_ws
        self._has_baseline = copy._has_baseline
        self._last_observed_rect = copy._last_observed_rect

    fn interior(self) -> Rect:
        """Region inside the border where content / editor paints. Public
        so hosts can compute view-relative things — e.g. ``reveal_cursor``
        after a goto-definition jump."""
        return Rect(self.rect.a.x + 1, self.rect.a.y + 1,
                    self.rect.b.x - 1, self.rect.b.y - 1)

    fn handle_key(mut self, event: Event) -> Bool:
        if not self.is_editor:
            return False
        return self.editor.handle_key(event, self.interior())

    fn handle_mouse_in_body(mut self, event: Event) -> Bool:
        """Editor mouse handling for clicks/drags inside the window body."""
        if not self.is_editor:
            return False
        return self.editor.handle_mouse(event, self.interior())

    fn toggle_maximize(mut self, workspace: Rect):
        if self.is_maximized:
            self.rect = self._restore_rect
            self.is_maximized = False
        else:
            self._restore_rect = self.rect
            self.rect = workspace
            self.is_maximized = True

    fn paint(
        self, mut canvas: Canvas, display_title: String,
        focused: Bool, number: Int,
    ):
        var border: Attr
        if focused:
            border = Attr(WHITE, BLUE)
        else:
            border = Attr(LIGHT_GRAY, BLUE)
        var content_attr = Attr(YELLOW, BLUE)
        var body_bg = Attr(LIGHT_GRAY, BLUE)
        # Bind every write to the window's own rect — chrome (border,
        # title, indicators, scrollbars) sits ON the rect's perimeter,
        # body content fills the interior; either way nothing should
        # leak outside ``self.rect``.
        var painter = Painter(self.rect)
        var interior = self.rect.inset(1, 1)
        if not interior.is_empty():
            painter.fill(canvas, interior, String(" "), body_bg)
        # Focused windows get the classic TV double-line border; others single.
        painter.draw_box(canvas, self.rect, border, focused)
        # Title sits on the top border row through the framework helper:
        # the helper enforces title-bg = body-bg, while ``border`` only
        # contributes its focus-tinted fg. The +6 width gate keeps the
        # centered title from poking under the close button (left, 3
        # cells) or the number/maximize indicator (right) on small
        # windows — those always win the row.
        var title_padded = String(" ") + display_title + String(" ")
        if self.rect.width() >= len(title_padded.as_bytes()) + 6:
            paint_window_title(
                canvas, self.rect, title_padded, border, body_bg,
            )
        # Close button [■] at top-LEFT (TV convention) — focused only.
        # Drawing is delegated to ``paint_close_button`` so dialogs
        # can reuse the same chrome without copy-pasting the glyphs.
        if focused and self.rect.width() >= 8:
            paint_close_button(
                canvas, Point(self.rect.a.x, self.rect.a.y), border,
            )
        # Window number (and, when focused, a maximize/restore button) at top-RIGHT.
        # Format: ``<num>=[▲]`` while normal, ``<num>=[▼]`` while
        # maximized. Unfocused windows show only the bare number.
        var num_str = String(number)
        var num_len = len(num_str.as_bytes())
        if focused and self.rect.width() >= num_len + 9:
            var arrow: String
            if self.is_maximized:
                arrow = String("▼")
            else:
                arrow = String("▲")
            var indicator = num_str + String("=[") + arrow + String("]")
            _ = painter.put_text(
                canvas,
                Point(self.rect.b.x - num_len - 5, self.rect.a.y),
                indicator,
                border,
            )
        elif self.rect.width() >= num_len + 6:
            _ = painter.put_text(
                canvas,
                Point(self.rect.b.x - num_len - 2, self.rect.a.y),
                num_str,
                border,
            )
        if self.is_editor:
            self.editor.paint(canvas, self.interior(), focused)
        else:
            # Content, left-aligned. The painter clips to ``self.rect``
            # on both axes; ``inner_h`` keeps us off the bottom border.
            var inner_h = self.rect.height() - 2
            for i in range(len(self.content)):
                if i >= inner_h:
                    break
                _ = painter.put_text(
                    canvas,
                    Point(self.rect.a.x + 2, self.rect.a.y + 1 + i),
                    self.content[i],
                    content_attr,
                )
        # Editor windows get scroll bars + a row:col indicator, both integrated
        # into the window border (overlaying the ``─``/``│`` line chars).
        if self.is_editor:
            self._paint_v_scrollbar(canvas, painter, border)
            self._paint_h_scrollbar(canvas, painter, border)
        # Unsaved-changes marker: a green ``*`` at column a.x+2 of the bottom
        # border (skipping the corner ``└`` at a.x and the dash at a.x+1).
        if self.is_editor and self.editor.dirty and self.rect.width() >= 4:
            painter.set(
                canvas,
                self.rect.a.x + 2, self.rect.b.y - 1,
                Cell(String("*"), Attr(GREEN, BLUE), 1),
            )

    # --- scroll bar geometry ----------------------------------------------
    # Both axes delegate to the reusable ``scrollbar`` primitive.
    # ``_v_scrollbar`` / ``_h_scrollbar`` are the single source of truth
    # for paint + hit-test + drag + track-jump; the public methods are
    # thin wrappers so existing callers (WindowManager mouse routing)
    # don't have to know the primitive exists.

    fn _v_scrollbar(self) -> VScrollbar:
        """Vertical scrollbar value for this window's editor pane.

        Returns a degenerate bar (``bottom < top``) — and therefore
        ``metrics().present == False`` — when the window isn't an
        editor or is too short for a meaningful bar."""
        if not self.is_editor or self.rect.width() < 2 or self.rect.height() < 5:
            return VScrollbar(0, 0, -1, 0, 0, 0)
        var visible = self.rect.height() - 2
        return VScrollbar(
            self.rect.b.x - 1, self.rect.a.y + 1, self.rect.b.y - 2,
            self.editor.buffer.line_count(),
            visible,
            self.editor.scroll_y,
        )

    fn _h_scrollbar(self) -> HScrollbar:
        """Horizontal scrollbar value. Soft-wrap mode and too-narrow
        windows produce a degenerate bar (``right < left``)."""
        if not self.is_editor or self.editor.soft_wrap \
                or self.rect.width() < 14 or self.rect.height() < 2:
            return HScrollbar(0, 0, -1, 0, 0, 0)
        var pos_text = String(self.editor.cursor_row + 1) \
            + String(":") + String(self.editor.cursor_col + 1)
        var pos_x = self.rect.a.x + 4
        var pos_len = len(pos_text.as_bytes())
        var sb_left = pos_x + pos_len + 1
        var sb_right = self.rect.b.x - 2
        var visible = self.rect.width() - 2
        return HScrollbar(
            self.rect.b.y - 1, sb_left, sb_right,
            self.editor.longest_line_width(),
            visible,
            self.editor.scroll_x,
        )

    fn _paint_v_scrollbar(
        self, mut canvas: Canvas, painter: Painter, border: Attr,
    ):
        """Vertical scroll bar overlaying the right ``│`` border."""
        self._v_scrollbar().paint(canvas, painter, border)

    fn _paint_h_scrollbar(
        self, mut canvas: Canvas, painter: Painter, border: Attr,
    ):
        """Horizontal scroll bar + ``row:col`` indicator on the bottom border.

        Layout (after the ``└`` corner and the dirty-marker slot at ``a.x+2``):
        ``─ROW:COL─◄════════►─┘``. The ``◄░░░█░░►`` portion fills whatever
        space remains between the indicator and the right corner.
        """
        if self.rect.width() < 14 or self.rect.height() < 2:
            return
        var y = self.rect.b.y - 1
        var pos_text = String(self.editor.cursor_row + 1) \
            + String(":") + String(self.editor.cursor_col + 1)
        var pos_x = self.rect.a.x + 4
        _ = painter.put_text(canvas, Point(pos_x, y), pos_text, border)
        self._h_scrollbar().paint(canvas, painter, border)

    # --- scroll bar hit-testing & actions ---------------------------------
    # ``part`` codes: 0=none, 1=up/left arrow, 2=above/left of thumb,
    # 3=on thumb, 4=below/right of thumb, 5=down/right arrow.
    # The second tuple element is the track-relative offset of the click
    # for parts 2 / 3 / 4 — used as the drag anchor for thumb (3) and as
    # the jump target for the page areas (2, 4).

    fn v_scrollbar_hit(self, p: Point) -> Tuple[Int, Int]:
        return self._v_scrollbar().hit(p)

    fn h_scrollbar_hit(self, p: Point) -> Tuple[Int, Int]:
        return self._h_scrollbar().hit(p)

    fn v_scroll_by(mut self, lines: Int):
        """Scroll the editor vertically by ``lines`` (negative = up). Cursor
        does not move; same convention as wheel scrolling."""
        if not self.is_editor: return
        var view = self.interior()
        var max_y = self.editor.buffer.line_count() - view.height()
        if max_y < 0: max_y = 0
        var ny = self.editor.scroll_y + lines
        if ny < 0: ny = 0
        if ny > max_y: ny = max_y
        self.editor.scroll_y = ny

    fn h_scroll_by(mut self, cols: Int):
        if not self.is_editor: return
        var view = self.interior()
        var max_x = self.editor.longest_line_width() - view.width()
        if max_x < 0: max_x = 0
        var nx = self.editor.scroll_x + cols
        if nx < 0: nx = 0
        if nx > max_x: nx = max_x
        self.editor.scroll_x = nx

    fn v_scroll_to_track_pos(mut self, track_pos: Int):
        """Jump so the buffer row whose minimap projection falls at
        ``track_pos`` (track-relative, 0..track_h) sits centered in the
        editor view. Triggered by clicks in the page-up / page-down zones
        of the vertical scrollbar — the user gets a direct "go here, with
        a screen of context above and below" jump instead of paging."""
        if not self.is_editor: return
        self.editor.scroll_y = self._v_scrollbar().track_jump(track_pos)

    fn h_scroll_to_track_pos(mut self, track_pos: Int):
        """Horizontal twin of :func:`v_scroll_to_track_pos` — clicking in
        the page-left / page-right zones jumps to that proportional column
        with the target column horizontally centered in the view."""
        if not self.is_editor: return
        self.editor.scroll_x = self._h_scrollbar().track_jump(track_pos)

    fn v_drag_thumb_to(mut self, mouse_y: Int, drag_offset: Int):
        """Reposition ``scroll_y`` so the thumb's top sits at
        ``mouse_y - drag_offset``. Used while dragging the v-thumb."""
        if not self.is_editor: return
        var bar = self._v_scrollbar()
        if not bar.metrics().present: return
        self.editor.scroll_y = bar.drag_to(mouse_y, drag_offset)

    fn h_drag_thumb_to(mut self, mouse_x: Int, drag_offset: Int):
        if not self.is_editor: return
        var bar = self._h_scrollbar()
        if not bar.metrics().present: return
        self.editor.scroll_x = bar.drag_to(mouse_x, drag_offset)

    fn close_button_hit(self, p: Point) -> Bool:
        return hit_close_button(Point(self.rect.a.x, self.rect.a.y), p)

    fn maximize_button_hit(self, p: Point) -> Bool:
        # The `[↑]` / `[↓]` triplet sits one cell in from the right corner.
        return p.y == self.rect.a.y and self.rect.b.x - 4 <= p.x and p.x <= self.rect.b.x - 2

    fn title_bar_hit(self, p: Point) -> Bool:
        return p.y == self.rect.a.y \
            and not self.close_button_hit(p) \
            and not self.maximize_button_hit(p)

    fn resize_edges_hit(self, p: Point) -> Tuple[Bool, Bool, Bool]:
        """Which edges of the border ``p`` is on: ``(left, right, bottom)``.

        The top row is reserved for the title bar (drag-to-move), so it never
        counts as a resize edge — even at the top corners.
        """
        if p.y == self.rect.a.y:
            return (False, False, False)
        var left = (p.x == self.rect.a.x)
        var right = (p.x == self.rect.b.x - 1)
        var bottom = (p.y == self.rect.b.y - 1)
        return (left, right, bottom)


fn compute_display_titles(windows: List[Window]) -> List[String]:
    """Return a parallel list of display titles for ``windows``. When
    two file-backed windows share a basename but have distinct paths,
    each colliding title is prefixed with its parent-directory
    component (``parent/file.py``) so they're distinguishable in the
    tab bar and on the title border. Non-file-backed windows (and
    windows with no resolvable parent component) keep their original
    title."""
    var titles = List[String]()
    var n = len(windows)
    for i in range(n):
        titles.append(windows[i].title)
    for i in range(n):
        if not windows[i].is_editor:
            continue
        var path_i = windows[i].editor.file_path
        if len(path_i.as_bytes()) == 0:
            continue
        var collides = False
        for j in range(n):
            if i == j:
                continue
            if not windows[j].is_editor:
                continue
            var path_j = windows[j].editor.file_path
            if len(path_j.as_bytes()) == 0:
                continue
            if windows[j].title == windows[i].title and path_j != path_i:
                collides = True
                break
        if not collides:
            continue
        var parent_dir = basename(parent_path(path_i))
        if len(parent_dir.as_bytes()) == 0 or parent_dir == String("/") \
                or parent_dir == String("."):
            continue
        titles[i] = parent_dir + String("/") + windows[i].title
    return titles^


struct WindowManager(Movable):
    """Owns the open windows and their interaction state.

    ``windows`` is the **stable** list — its order is insertion order and
    never changes when focus shifts, so menu items / Ctrl+N bindings keyed
    on the index stay aligned across focus changes.

    ``z_order`` carries the actual painting / hit-test order: it's a list
    of indices into ``windows`` with the topmost window last. Focusing a
    window moves its index to the end of ``z_order`` only — ``windows``
    is untouched. The invariant ``z_order[-1] == focused`` holds whenever
    there is at least one window.
    """
    var windows: List[Window]
    var focused: Int
    var z_order: List[Int]
    var _dragging: Int
    var _resizing: Int
    var _editor_dragging: Int   # window index for in-body editor select-drag
    var _v_scrolling: Int       # window idx, or -1: dragging the v-thumb
    var _h_scrolling: Int       # window idx, or -1: dragging the h-thumb
    var _v_drag_offset: Int     # cell offset within the v-thumb at press time
    var _h_drag_offset: Int
    var _resize_left: Bool
    var _resize_right: Bool
    var _resize_bottom: Bool
    var _drag_dx: Int
    var _drag_dy: Int
    # Bare-hover tracker for the title-bar full-path tooltip. ``-1``
    # means nothing is hovered; otherwise the index of the editor
    # window whose title row the pointer is currently over (and whose
    # ``editor.file_path`` is non-empty). ``_title_hover_x/y`` are the
    # cursor cell used to anchor the popup. Cleared on any non-hover
    # mouse event so a click doesn't leave a stale tooltip behind.
    var _title_hover_idx: Int
    var _title_hover_x: Int
    var _title_hover_y: Int
    # The workspace last seen by ``fit_into`` — used to scale every
    # window's rect proportionally when the workspace changes (terminal
    # resize, side-panel toggle, …). Unset on a freshly-constructed
    # manager so the first ``fit_into`` falls back to the move-and-clip
    # path; ``note_workspace`` resets the baseline after a manual rect
    # assignment (session restore) so the next scale doesn't act on it.
    var _last_workspace: Rect
    var _has_last_workspace: Bool

    fn __init__(out self):
        self.windows = List[Window]()
        self.focused = -1
        self.z_order = List[Int]()
        self._dragging = -1
        self._resizing = -1
        self._editor_dragging = -1
        self._v_scrolling = -1
        self._h_scrolling = -1
        self._v_drag_offset = 0
        self._h_drag_offset = 0
        self._resize_left = False
        self._resize_right = False
        self._resize_bottom = False
        self._drag_dx = 0
        self._drag_dy = 0
        self._title_hover_idx = -1
        self._title_hover_x = 0
        self._title_hover_y = 0
        self._last_workspace = Rect.empty()
        self._has_last_workspace = False

    fn add(mut self, var window: Window):
        self.windows.append(window^)
        var idx = len(self.windows) - 1
        self.z_order.append(idx)
        self.focused = idx

    fn fit_into(mut self, workspace: Rect):
        """Reflow every window into ``workspace`` after it changes.

        The workspace changes for three reasons: terminal resize, a side
        panel (file tree / debug pane) toggling, or a session restore
        rewriting rects from saved positions. The first two should
        preserve the user's layout — two windows tiled side by side
        covering the screen must still cover it after the terminal grows
        — so each non-maximized window's rect is scaled proportionally
        when the workspace differs from the last one seen.

        Crucially, the scale is computed from a **baseline** per window
        (``_baseline_rect`` in ``_baseline_ws``) rather than from the
        window's current rect. This makes shrink-then-grow round trips
        lossless: scaling from the original baseline straight to the
        new workspace dodges the rounding error that would accumulate
        across two integer rescales. The baseline is rebased only when
        a user action (drag, edge resize, maximize toggle, …) changes
        the rect between paints; we detect that by comparing the
        current rect against ``_last_observed_rect`` (the rect at the
        end of the previous pass), and only inside the
        workspace-unchanged branch — a rect that changed because of a
        workspace transition must not pollute the baseline.

        Maximized windows pin to the new workspace; their
        ``_restore_rect`` is scaled along with the workspace so
        un-maximizing after a resize lands proportionally.

        The very first call has no baseline yet (a freshly-constructed
        manager whose windows were created in some unknown workspace),
        so it falls back to a clip-and-move pass that only resizes when
        a window is larger than the workspace along an axis. After that
        pass the baseline is seeded from the resulting rects.

        After fitting, every editor window's scroll offsets get clamped
        against its (possibly resized) interior — a window that was
        scrolled right while narrow must not leave leading text wedged
        off-screen once it's wide enough that the scrollbar disappears.
        """
        if not self._has_last_workspace:
            self._clip_into(workspace)
            for i in range(len(self.windows)):
                self.windows[i]._baseline_rect = self.windows[i].rect
                self.windows[i]._baseline_ws = workspace
                self.windows[i]._has_baseline = True
                self.windows[i]._last_observed_rect = self.windows[i].rect
        elif self._last_workspace != workspace:
            var prev_ws = self._last_workspace
            self._scale_from_baselines(prev_ws, workspace)
        else:
            self._rebase_user_changes(workspace)
        # Always clamp scrolls: layout might be unchanged but a buffer
        # could have shrunk underneath us between paints.
        for i in range(len(self.windows)):
            if self.windows[i].is_editor:
                self.windows[i].editor.clamp_scroll(self.windows[i].interior())
        self._last_workspace = workspace
        self._has_last_workspace = True

    fn note_workspace(mut self, workspace: Rect):
        """Reset the workspace + every window's baseline without touching
        any rect.

        Called by the desktop after it has manually assigned rects to
        windows (e.g. session restore) so that the next ``fit_into``
        doesn't see the workspace as "changed since last time" and
        scale the just-restored positions away. Re-seeding the per-
        window baselines here means subsequent terminal resizes scale
        from the restored layout instead of from whatever baseline was
        cached pre-restore.
        """
        self._last_workspace = workspace
        self._has_last_workspace = True
        for i in range(len(self.windows)):
            self.windows[i]._baseline_rect = self.windows[i].rect
            self.windows[i]._baseline_ws = workspace
            self.windows[i]._has_baseline = True
            self.windows[i]._last_observed_rect = self.windows[i].rect

    fn _clip_into(mut self, workspace: Rect):
        """Move-and-clip fallback used on the first ``fit_into`` call,
        before there's a baseline workspace to scale relative to.

        Movement is preferred over resizing: a window only shrinks when
        it's larger than the workspace along an axis. Maximized windows
        pin to the workspace.
        """
        for i in range(len(self.windows)):
            if self.windows[i].is_maximized:
                self.windows[i].rect = workspace
            else:
                var w = self.windows[i].rect.width()
                var h = self.windows[i].rect.height()
                var ws_w = workspace.width()
                var ws_h = workspace.height()
                if w > ws_w: w = ws_w
                if h > ws_h: h = ws_h
                var ax = self.windows[i].rect.a.x
                var ay = self.windows[i].rect.a.y
                if ax < workspace.a.x: ax = workspace.a.x
                if ay < workspace.a.y: ay = workspace.a.y
                if ax + w > workspace.b.x: ax = workspace.b.x - w
                if ay + h > workspace.b.y: ay = workspace.b.y - h
                self.windows[i].rect = _fit_min_in_workspace(
                    Rect(ax, ay, ax + w, ay + h), workspace,
                )

    fn _scale_from_baselines(mut self, prev_ws: Rect, new_ws: Rect):
        """Workspace just changed. Scale every non-maximized window's
        rect from its own baseline pair to ``new_ws``; pin maximized
        windows to ``new_ws`` and proportionally scale their
        ``_restore_rect``. Baselines are not touched here — they are
        the source of truth for the *next* resize.

        Windows whose baseline workspace is empty (created between the
        manager's first ``fit_into`` and now) inherit the previous
        workspace as a fallback baseline so they still scale sensibly
        on this transition.
        """
        for i in range(len(self.windows)):
            if not self.windows[i]._has_baseline:
                self.windows[i]._baseline_rect = self.windows[i].rect
                self.windows[i]._baseline_ws = prev_ws
                self.windows[i]._has_baseline = True
            var base_ws = self.windows[i]._baseline_ws
            if base_ws.width() <= 0 or base_ws.height() <= 0:
                base_ws = prev_ws
            if self.windows[i].is_maximized:
                self.windows[i].rect = new_ws
                self.windows[i]._restore_rect = _scale_rect(
                    self.windows[i]._restore_rect, base_ws, new_ws,
                )
            else:
                self.windows[i].rect = _scale_rect(
                    self.windows[i]._baseline_rect, base_ws, new_ws,
                )
            self.windows[i]._last_observed_rect = self.windows[i].rect

    fn _rebase_user_changes(mut self, workspace: Rect):
        """Workspace unchanged since last pass. Any window whose rect
        differs from ``_last_observed_rect`` was mutated by user action
        (drag, edge resize, maximize toggle, new-window insertion) —
        capture its new rect as the baseline for the next workspace
        change. Untouched windows have their baseline left alone so
        round-trip resizes can still scale from their original
        precision-preserving anchor.
        """
        for i in range(len(self.windows)):
            if self.windows[i].rect != self.windows[i]._last_observed_rect:
                self.windows[i]._baseline_rect = self.windows[i].rect
                self.windows[i]._baseline_ws = workspace
                self.windows[i]._has_baseline = True
            elif not self.windows[i]._has_baseline:
                self.windows[i]._baseline_rect = self.windows[i].rect
                self.windows[i]._baseline_ws = workspace
                self.windows[i]._has_baseline = True
            self.windows[i]._last_observed_rect = self.windows[i].rect

    fn focus_by_title(mut self, title: String):
        for i in range(len(self.windows)):
            if self.windows[i].title == title:
                self.focused = i
                self._raise_in_z(i)
                return

    fn focus_by_index(mut self, idx: Int):
        """Focus window ``idx`` and raise it to the top of the z-order.

        Out-of-range indices are silently ignored — useful for stale menu
        clicks where the window has just been closed. ``windows`` itself
        is *not* reordered (so keyboard shortcuts and menu indices stay
        stable across focus changes); only ``z_order`` updates.
        """
        if idx < 0 or idx >= len(self.windows):
            return
        self.focused = idx
        self._raise_in_z(idx)

    fn rotate_focus(mut self, forward: Bool):
        """Cycle focus to the next (forward) or previous window in the
        stable insertion order. No-op when there are 0 or 1 windows.
        Stable order — not z-order — keeps rotation predictable: the
        sequence is always the same as the numbered window labels."""
        var n = len(self.windows)
        if n <= 1:
            return
        var cur = self.focused
        if cur < 0 or cur >= n:
            cur = 0
        var step = 1 if forward else n - 1
        var nxt = (cur + step) % n
        self.focused = nxt
        self._raise_in_z(nxt)

    fn close_focused(mut self) -> Bool:
        """Close the focused window. Focus moves to whichever window was
        next-most-recently focused (the new top of ``z_order``); ``-1`` when
        the last window is closed. Returns True if a window was closed.
        """
        if self.focused < 0 or self.focused >= len(self.windows):
            return False
        var idx = self.focused
        _ = self.windows.pop(idx)
        # Drop ``idx`` from z_order and shift any index above it down by one
        # to keep the indices in sync with the now-shorter ``windows`` list.
        var new_z = List[Int]()
        for k in range(len(self.z_order)):
            var v = self.z_order[k]
            if v == idx:
                continue
            if v > idx:
                v = v - 1
            new_z.append(v)
        self.z_order = new_z^
        if len(self.z_order) > 0:
            self.focused = self.z_order[len(self.z_order) - 1]
        else:
            self.focused = -1
        return True

    fn maximize_all(mut self, workspace: Rect):
        """Maximize every window into ``workspace``. Each window's pre-max
        rect is preserved in ``_restore_rect`` so ``restore_all`` can undo."""
        for i in range(len(self.windows)):
            if not self.windows[i].is_maximized:
                self.windows[i].toggle_maximize(workspace)

    fn restore_all(mut self):
        """Drop every window out of maximized mode, back to its pre-max rect."""
        for i in range(len(self.windows)):
            if self.windows[i].is_maximized:
                self.windows[i].rect = self.windows[i]._restore_rect
                self.windows[i].is_maximized = False

    fn focused_is_editor(self) -> Bool:
        if self.focused < 0 or self.focused >= len(self.windows):
            return False
        return self.windows[self.focused].is_editor

    fn check_external_changes(mut self) raises -> List[Int]:
        """Re-stat every file-backed editor window and react to any
        out-of-band write. Returns the list of window indices whose
        merge produced conflicts — the host opens a diff view for
        each. Clean reloads and clean 3-way merges happen silently and
        are not surfaced.
        """
        var conflicts = List[Int]()
        for i in range(len(self.windows)):
            if not self.windows[i].is_editor:
                continue
            var status = self.windows[i].editor.check_for_external_change()
            if status == EXT_CHANGE_CONFLICT:
                conflicts.append(i)
        return conflicts^

    fn _raise_in_z(mut self, idx: Int):
        """Move ``idx`` to the end of ``z_order`` (making it the topmost
        window in the paint stack)."""
        var new_z = List[Int]()
        for k in range(len(self.z_order)):
            if self.z_order[k] != idx:
                new_z.append(self.z_order[k])
        new_z.append(idx)
        self.z_order = new_z^

    fn paint(self, mut canvas: Canvas):
        # Iterate z-order back-to-front so the focused window (which is
        # always at the end of z_order, by invariant) lands on top.
        var titles = compute_display_titles(self.windows)
        for k in range(len(self.z_order)):
            var i = self.z_order[k]
            self.windows[i].paint(canvas, titles[i], i == self.focused, i + 1)

    fn paint_title_tooltip(self, mut canvas: Canvas, workspace: Rect):
        """Overlay the full-path tooltip for whichever editor window's
        title bar is currently being hovered, if any. Painted by the
        host after ``paint`` so the popup z-orders above every window.
        """
        if self._title_hover_idx < 0:
            return
        if self._title_hover_idx >= len(self.windows):
            return
        var win = self.windows[self._title_hover_idx]
        if not win.is_editor:
            return
        var path = win.editor.file_path
        if len(path.as_bytes()) == 0:
            return
        var max_box_w = workspace.width() - 2
        if max_box_w < 5:
            max_box_w = workspace.width()
        var size = popup_size_for_text(path, max_box_w, workspace.height())
        var w = size[0]
        var h = size[1]
        if w == 0 or h == 0:
            return
        # Anchor one row below the hovered cell so the popup doesn't
        # cover the title text the user is pointing at. Flip above
        # when there's no room below; clamp horizontally so the box
        # always fits inside ``workspace``.
        var bx = self._title_hover_x
        var by = self._title_hover_y + 1
        if by + h > workspace.b.y:
            by = self._title_hover_y - h
        if by < workspace.a.y:
            by = workspace.a.y
        if bx + w > workspace.b.x:
            bx = workspace.b.x - w
        if bx < workspace.a.x:
            bx = workspace.a.x
        var r = Rect(bx, by, bx + w, by + h)
        var attr = Attr(BLACK, LIGHT_GRAY)
        paint_drop_shadow(canvas, r)
        var tt_painter = Painter(r)
        tt_painter.fill(canvas, r, String(" "), attr)
        tt_painter.draw_box(canvas, r, attr, False)
        var msg_rect = Rect(
            r.a.x + 2, r.a.y + 1,
            r.b.x - 2, r.b.y - 1,
        )
        if msg_rect.width() > 0 and msg_rect.height() > 0:
            _ = canvas.put_wrapped_text(msg_rect, path, attr)

    fn handle_key(mut self, event: Event) -> Bool:
        """Forward a key event to the focused window's editor (if it has one)."""
        if 0 <= self.focused and self.focused < len(self.windows):
            return self.windows[self.focused].handle_key(event)
        return False

    fn handle_mouse(mut self, event: Event, workspace: Rect) -> Bool:
        if event.kind != EVENT_MOUSE:
            return False
        # Wheel events: scroll the editor under the cursor (top-most hit).
        if event.button == MOUSE_WHEEL_UP or event.button == MOUSE_WHEEL_DOWN:
            if not event.pressed:
                return True
            self._title_hover_idx = -1
            var k = len(self.z_order) - 1
            while k >= 0:
                var i = self.z_order[k]
                if self.windows[i].rect.contains(event.pos):
                    return self.windows[i].handle_mouse_in_body(event)
                k -= 1
            return True
        # Bare hover (button=NONE, motion=True under xterm 1003 mode):
        # forward to the editor body of whichever window the pointer is
        # over so it can drive minimap-tooltip state. Don't touch focus
        # or z-order — the user hasn't clicked. Editors not under the
        # pointer have their hover state cleared so a stale tooltip
        # doesn't linger after the pointer crosses a border.
        if event.button == MOUSE_BUTTON_NONE:
            var k2 = len(self.z_order) - 1
            var hit = -1
            while k2 >= 0:
                var i2 = self.z_order[k2]
                if self.windows[i2].rect.contains(event.pos):
                    hit = i2
                    break
                k2 -= 1
            for j in range(len(self.windows)):
                if self.windows[j].is_editor and j != hit:
                    self.windows[j].editor.clear_minimap_hover()
            # Title-bar full-path tooltip: arm only when the pointer is
            # on the topmost window's title row AND that window is a
            # file-backed editor. The body forwards to handle_mouse_in_body
            # below for minimap-hover state, so the two trackers stay
            # independent.
            self._title_hover_idx = -1
            if hit >= 0 and self.windows[hit].is_editor \
                    and self.windows[hit].title_bar_hit(event.pos) \
                    and len(self.windows[hit].editor.file_path.as_bytes()) > 0:
                self._title_hover_idx = hit
                self._title_hover_x = event.pos.x
                self._title_hover_y = event.pos.y
            if hit >= 0 and self.windows[hit].is_editor:
                _ = self.windows[hit].handle_mouse_in_body(event)
            return True
        # Right-click: forward the press to whichever editor body the
        # pointer is over so it can stamp a context-menu request (e.g.
        # the breakpoint-edit dialog on a gutter dot). Don't touch focus
        # or z-order — the resulting modal doesn't depend on focus and
        # silently re-stacking on every right-click would be surprising.
        if event.button == MOUSE_BUTTON_RIGHT:
            if not event.pressed:
                return True
            self._title_hover_idx = -1
            var k3 = len(self.z_order) - 1
            while k3 >= 0:
                var i3 = self.z_order[k3]
                if self.windows[i3].rect.contains(event.pos):
                    return self.windows[i3].handle_mouse_in_body(event)
                k3 -= 1
            return True
        if event.button != MOUSE_BUTTON_LEFT:
            return False
        # Any left-button activity (press, drag, release) drops the
        # title-bar tooltip. Bare hover re-arms it on the next motion.
        self._title_hover_idx = -1
        if event.pressed and not event.motion:
            return self._handle_press(event, workspace)
        elif event.pressed and event.motion:
            return self._handle_motion(event, workspace)
        else:
            self._dragging = -1
            self._resizing = -1
            self._editor_dragging = -1
            self._v_scrolling = -1
            self._h_scrolling = -1
            self._resize_left = False
            self._resize_right = False
            self._resize_bottom = False
            return True

    fn _handle_press(mut self, event: Event, workspace: Rect) -> Bool:
        # Hit-test top-down using ``z_order`` (last entry = topmost window).
        var clicked = -1
        var k = len(self.z_order) - 1
        while k >= 0:
            var i = self.z_order[k]
            if self.windows[i].rect.contains(event.pos):
                clicked = i
                break
            k -= 1
        if clicked < 0:
            return False
        self.focused = clicked
        self._raise_in_z(clicked)
        if self.windows[self.focused].close_button_hit(event.pos):
            _ = self.close_focused()
            return True
        if self.windows[self.focused].maximize_button_hit(event.pos):
            self.windows[self.focused].toggle_maximize(workspace)
            return True
        # Scroll bars overlay the right and bottom borders, so hit-test them
        # before the resize-edge check.
        if self.windows[self.focused].is_editor:
            var vh = self.windows[self.focused].v_scrollbar_hit(event.pos)
            if vh[0] != 0:
                if vh[0] == 1:
                    self.windows[self.focused].v_scroll_by(-1)
                elif vh[0] == 5:
                    self.windows[self.focused].v_scroll_by(1)
                elif vh[0] == 2 or vh[0] == 4:
                    self.windows[self.focused].v_scroll_to_track_pos(vh[1])
                else:  # 3 — on thumb
                    self._v_scrolling = self.focused
                    self._v_drag_offset = vh[1]
                return True
            var hh = self.windows[self.focused].h_scrollbar_hit(event.pos)
            if hh[0] != 0:
                if hh[0] == 1:
                    self.windows[self.focused].h_scroll_by(-1)
                elif hh[0] == 5:
                    self.windows[self.focused].h_scroll_by(1)
                elif hh[0] == 2 or hh[0] == 4:
                    self.windows[self.focused].h_scroll_to_track_pos(hh[1])
                else:
                    self._h_scrolling = self.focused
                    self._h_drag_offset = hh[1]
                return True
        var edges = self.windows[self.focused].resize_edges_hit(event.pos)
        if edges[0] or edges[1] or edges[2]:
            self._resizing = self.focused
            self._resize_left = edges[0]
            self._resize_right = edges[1]
            self._resize_bottom = edges[2]
            return True
        if self.windows[self.focused].title_bar_hit(event.pos):
            self._dragging = self.focused
            self._drag_dx = event.pos.x - self.windows[self.focused].rect.a.x
            self._drag_dy = event.pos.y - self.windows[self.focused].rect.a.y
            return True
        # Body click — forward to the editor (if any). A True return means the
        # editor consumed it and we should treat subsequent motion as a drag-
        # extend on the same editor.
        if self.windows[self.focused].handle_mouse_in_body(event):
            self._editor_dragging = self.focused
        return True

    fn _handle_motion(mut self, event: Event, workspace: Rect) -> Bool:
        if self._dragging >= 0:
            var width = self.windows[self._dragging].rect.width()
            var height = self.windows[self._dragging].rect.height()
            var nx = event.pos.x - self._drag_dx
            var ny = event.pos.y - self._drag_dy
            if nx < workspace.a.x: nx = workspace.a.x
            if ny < workspace.a.y: ny = workspace.a.y
            if nx + width > workspace.b.x: nx = workspace.b.x - width
            if ny + height > workspace.b.y: ny = workspace.b.y - height
            self.windows[self._dragging].rect = Rect(nx, ny, nx + width, ny + height)
            self.windows[self._dragging].is_maximized = False
            return True
        if self._resizing >= 0:
            var rect = self.windows[self._resizing].rect
            var ax = rect.a.x
            var ay = rect.a.y
            var bx = rect.b.x
            var by = rect.b.y
            if self._resize_left:
                ax = event.pos.x
                if ax < workspace.a.x: ax = workspace.a.x
                if bx - ax < MIN_WIN_W: ax = bx - MIN_WIN_W
            if self._resize_right:
                bx = event.pos.x + 1
                if bx > workspace.b.x: bx = workspace.b.x
                if bx - ax < MIN_WIN_W: bx = ax + MIN_WIN_W
            if self._resize_bottom:
                by = event.pos.y + 1
                if by > workspace.b.y: by = workspace.b.y
                if by - ay < MIN_WIN_H: by = ay + MIN_WIN_H
            self.windows[self._resizing].rect = Rect(ax, ay, bx, by)
            self.windows[self._resizing].is_maximized = False
            return True
        if self._v_scrolling >= 0:
            self.windows[self._v_scrolling].v_drag_thumb_to(
                event.pos.y, self._v_drag_offset,
            )
            return True
        if self._h_scrolling >= 0:
            self.windows[self._h_scrolling].h_drag_thumb_to(
                event.pos.x, self._h_drag_offset,
            )
            return True
        if self._editor_dragging >= 0:
            return self.windows[self._editor_dragging].handle_mouse_in_body(event)
        return False
