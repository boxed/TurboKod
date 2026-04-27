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

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, GREEN, LIGHT_GRAY, WHITE, YELLOW
from .editor import Editor
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect


comptime MIN_WIN_W: Int = 12
comptime MIN_WIN_H: Int = 4


struct Window(ImplicitlyCopyable, Movable):
    var title: String
    var rect: Rect
    var content: List[String]
    var editor: Editor          # only used when ``is_editor`` is True
    var is_editor: Bool
    var is_maximized: Bool
    var _restore_rect: Rect

    fn __init__(out self, var title: String, rect: Rect, var content: List[String]):
        self.title = title^
        self.rect = rect
        self.content = content^
        self.editor = Editor()
        self.is_editor = False
        self.is_maximized = False
        self._restore_rect = rect

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

    fn paint(self, mut canvas: Canvas, focused: Bool, number: Int):
        var border: Attr
        if focused:
            border = Attr(WHITE, BLUE)
        else:
            border = Attr(LIGHT_GRAY, BLUE)
        var content_attr = Attr(YELLOW, BLUE)
        var interior = self.rect.inset(1, 1)
        if not interior.is_empty():
            canvas.fill(interior, String(" "), Attr(LIGHT_GRAY, BLUE))
        # Focused windows get the classic TV double-line border; others single.
        canvas.draw_box(self.rect, border, focused)
        # Title centered on the top edge, padded with a space either side.
        # The title shares the border's colors — focusing must not flip it to a
        # contrasting reverse-video patch, only the line weight (single → double)
        # and the border brightness change.
        var title_padded = String(" ") + self.title + String(" ")
        var title_len = len(title_padded.as_bytes())
        if self.rect.width() >= title_len + 6:
            var tx = self.rect.a.x + (self.rect.width() - title_len) // 2
            _ = canvas.put_text(Point(tx, self.rect.a.y), title_padded, border)
        # Close button [■] at top-LEFT (TV convention) — focused only.
        # The ■ glyph is green like in classic Turbo Vision; brackets keep the
        # border color.
        if focused and self.rect.width() >= 8:
            var close_glyph = Attr(GREEN, BLUE)
            canvas.set(self.rect.a.x + 1, self.rect.a.y, Cell(String("["), border, 1))
            canvas.set(self.rect.a.x + 2, self.rect.a.y, Cell(String("■"), close_glyph, 1))
            canvas.set(self.rect.a.x + 3, self.rect.a.y, Cell(String("]"), border, 1))
        # Window number (and, when focused, a maximize/restore button) at top-RIGHT.
        # Format: ``<num>=[↑]`` while normal, ``<num>=[↓]`` while maximized.
        # Unfocused windows show only the bare number.
        var num_str = String(number)
        var num_len = len(num_str.as_bytes())
        if focused and self.rect.width() >= num_len + 9:
            var arrow: String
            if self.is_maximized:
                arrow = String("↓")
            else:
                arrow = String("↑")
            var indicator = num_str + String("=[") + arrow + String("]")
            _ = canvas.put_text(
                Point(self.rect.b.x - num_len - 5, self.rect.a.y),
                indicator,
                border,
            )
        elif self.rect.width() >= num_len + 6:
            _ = canvas.put_text(
                Point(self.rect.b.x - num_len - 2, self.rect.a.y),
                num_str,
                border,
            )
        if self.is_editor:
            self.editor.paint(canvas, self.interior(), focused)
        else:
            # Content, left-aligned. Clipped to the interior on both axes:
            # the loop bound clips vertically; the ``max_x`` arg clips horizontally
            # so a long line can't bleed onto (or past) the right border.
            var inner_h = self.rect.height() - 2
            var content_right = self.rect.b.x - 1   # exclusive: stop before right border
            for i in range(len(self.content)):
                if i >= inner_h:
                    break
                _ = canvas.put_text(
                    Point(self.rect.a.x + 2, self.rect.a.y + 1 + i),
                    self.content[i],
                    content_attr,
                    content_right,
                )
        # Editor windows get scroll bars + a row:col indicator, both integrated
        # into the window border (overlaying the ``─``/``│`` line chars).
        if self.is_editor:
            self._paint_v_scrollbar(canvas, border)
            self._paint_h_scrollbar(canvas, border)
        # Unsaved-changes marker: a green ``*`` at column a.x+2 of the bottom
        # border (skipping the corner ``└`` at a.x and the dash at a.x+1).
        if self.is_editor and self.editor.dirty and self.rect.width() >= 4:
            canvas.set(
                self.rect.a.x + 2, self.rect.b.y - 1,
                Cell(String("*"), Attr(GREEN, BLUE), 1),
            )

    # --- scroll bar geometry ----------------------------------------------
    # ``_v_sb_metrics`` and ``_h_sb_metrics`` are the single source of truth
    # for both painting (``_paint_v/h_scrollbar``) and hit-testing
    # (``v/h_scrollbar_hit``). Keep them in sync by changing only the helpers.

    fn _v_sb_metrics(self) -> Tuple[Bool, Int, Int, Int, Int, Int]:
        """``(present, track_y0, track_h, knob_off, knob_h, max_scroll)``.
        ``present=False`` means no scroll bar is drawn."""
        if not self.is_editor:
            return (False, 0, 0, 0, 0, 0)
        if self.rect.width() < 2 or self.rect.height() < 5:
            return (False, 0, 0, 0, 0, 0)
        var top = self.rect.a.y + 1
        var bot = self.rect.b.y - 2
        var track_y0 = top + 1
        var track_h = bot - top - 1
        if track_h < 1:
            return (False, 0, 0, 0, 0, 0)
        var total = self.editor.buffer.line_count()
        var visible = self.rect.height() - 2
        if visible < 1: visible = 1
        var max_scroll: Int
        var knob_h: Int
        var knob_off: Int
        if total <= visible:
            max_scroll = 0
            knob_h = track_h
            knob_off = 0
        else:
            max_scroll = total - visible
            knob_h = (track_h * visible) // total
            if knob_h < 1: knob_h = 1
            if knob_h > track_h: knob_h = track_h
            knob_off = (self.editor.scroll_y * (track_h - knob_h)) // max_scroll
            if knob_off < 0: knob_off = 0
            if knob_off > track_h - knob_h: knob_off = track_h - knob_h
        return (True, track_y0, track_h, knob_off, knob_h, max_scroll)

    fn _h_sb_metrics(self) -> Tuple[Bool, Int, Int, Int, Int, Int]:
        """``(present, sb_left, track_w, knob_off, knob_w, max_scroll)``.
        Track cells run from ``sb_left + 1`` to ``sb_left + track_w`` inclusive;
        ``sb_right = sb_left + track_w + 1``."""
        if not self.is_editor:
            return (False, 0, 0, 0, 0, 0)
        if self.rect.width() < 14 or self.rect.height() < 2:
            return (False, 0, 0, 0, 0, 0)
        var pos_text = String(self.editor.cursor_row + 1) \
            + String(":") + String(self.editor.cursor_col + 1)
        var pos_x = self.rect.a.x + 4
        var pos_len = len(pos_text.as_bytes())
        var sb_left = pos_x + pos_len + 1
        var sb_right = self.rect.b.x - 2
        if sb_right - sb_left < 4:
            return (False, 0, 0, 0, 0, 0)
        var track_w = sb_right - sb_left - 1
        if track_w < 1:
            return (False, 0, 0, 0, 0, 0)
        var total = self.editor.longest_line_width()
        var visible = self.rect.width() - 2
        if visible < 1: visible = 1
        var max_scroll: Int
        var knob_w: Int
        var knob_off: Int
        if total <= visible:
            max_scroll = 0
            knob_w = track_w
            knob_off = 0
        else:
            max_scroll = total - visible
            knob_w = (track_w * visible) // total
            if knob_w < 1: knob_w = 1
            if knob_w > track_w: knob_w = track_w
            knob_off = (self.editor.scroll_x * (track_w - knob_w)) // max_scroll
            if knob_off < 0: knob_off = 0
            if knob_off > track_w - knob_w: knob_off = track_w - knob_w
        return (True, sb_left, track_w, knob_off, knob_w, max_scroll)

    fn _paint_v_scrollbar(self, mut canvas: Canvas, border: Attr):
        """Vertical scroll bar overlaying the right ``│`` border."""
        var m = self._v_sb_metrics()
        if not m[0]:
            return
        var x = self.rect.b.x - 1
        var top = self.rect.a.y + 1
        var bot = self.rect.b.y - 2
        canvas.set(x, top, Cell(String("▲"), border, 1))
        canvas.set(x, bot, Cell(String("▼"), border, 1))
        var track_y0 = m[1]
        var track_h = m[2]
        var knob_off = m[3]
        var knob_h = m[4]
        for i in range(track_h):
            var ch: String
            if knob_off <= i and i < knob_off + knob_h:
                ch = String("█")
            else:
                ch = String("░")
            canvas.set(x, track_y0 + i, Cell(ch, border, 1))

    fn _paint_h_scrollbar(self, mut canvas: Canvas, border: Attr):
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
        _ = canvas.put_text(Point(pos_x, y), pos_text, border, self.rect.b.x - 1)
        var m = self._h_sb_metrics()
        if not m[0]:
            return
        var sb_left = m[1]
        var track_w = m[2]
        var knob_off = m[3]
        var knob_w = m[4]
        var sb_right = sb_left + track_w + 1
        canvas.set(sb_left, y, Cell(String("◄"), border, 1))
        canvas.set(sb_right, y, Cell(String("►"), border, 1))
        for i in range(track_w):
            var ch: String
            if knob_off <= i and i < knob_off + knob_w:
                ch = String("█")
            else:
                ch = String("░")
            canvas.set(sb_left + 1 + i, y, Cell(ch, border, 1))

    # --- scroll bar hit-testing & actions ---------------------------------
    # ``part`` codes: 0=none, 1=up/left arrow, 2=above/left of thumb,
    # 3=on thumb, 4=below/right of thumb, 5=down/right arrow.
    # The second tuple element is the cursor offset within the thumb at press
    # time (only meaningful for part==3, used as the drag anchor).

    fn v_scrollbar_hit(self, p: Point) -> Tuple[Int, Int]:
        if not self.is_editor:
            return (0, 0)
        if self.rect.width() < 2 or self.rect.height() < 5:
            return (0, 0)
        if p.x != self.rect.b.x - 1:
            return (0, 0)
        var top = self.rect.a.y + 1
        var bot = self.rect.b.y - 2
        if p.y == top: return (1, 0)
        if p.y == bot: return (5, 0)
        var m = self._v_sb_metrics()
        if not m[0]:
            return (0, 0)
        var track_y0 = m[1]
        var track_h = m[2]
        var knob_off = m[3]
        var knob_h = m[4]
        if p.y < track_y0 or p.y >= track_y0 + track_h:
            return (0, 0)
        var rel = p.y - track_y0
        if rel < knob_off: return (2, 0)
        if rel >= knob_off + knob_h: return (4, 0)
        return (3, rel - knob_off)

    fn h_scrollbar_hit(self, p: Point) -> Tuple[Int, Int]:
        if not self.is_editor:
            return (0, 0)
        if p.y != self.rect.b.y - 1:
            return (0, 0)
        var m = self._h_sb_metrics()
        if not m[0]:
            return (0, 0)
        var sb_left = m[1]
        var track_w = m[2]
        var knob_off = m[3]
        var knob_w = m[4]
        var sb_right = sb_left + track_w + 1
        if p.x == sb_left: return (1, 0)
        if p.x == sb_right: return (5, 0)
        if p.x < sb_left + 1 or p.x > sb_right - 1:
            return (0, 0)
        var rel = p.x - (sb_left + 1)
        if rel < knob_off: return (2, 0)
        if rel >= knob_off + knob_w: return (4, 0)
        return (3, rel - knob_off)

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

    fn v_drag_thumb_to(mut self, mouse_y: Int, drag_offset: Int):
        """Reposition ``scroll_y`` so the thumb's top sits at
        ``mouse_y - drag_offset``. Used while dragging the v-thumb."""
        if not self.is_editor: return
        var m = self._v_sb_metrics()
        if not m[0]: return
        var track_y0 = m[1]
        var track_h = m[2]
        var knob_h = m[4]
        var max_scroll = m[5]
        var denom = track_h - knob_h
        if max_scroll == 0 or denom <= 0:
            return
        var target = mouse_y - track_y0 - drag_offset
        if target < 0: target = 0
        if target > denom: target = denom
        var ny = (target * max_scroll + denom // 2) // denom
        if ny < 0: ny = 0
        if ny > max_scroll: ny = max_scroll
        self.editor.scroll_y = ny

    fn h_drag_thumb_to(mut self, mouse_x: Int, drag_offset: Int):
        if not self.is_editor: return
        var m = self._h_sb_metrics()
        if not m[0]: return
        var sb_left = m[1]
        var track_w = m[2]
        var knob_w = m[4]
        var max_scroll = m[5]
        var denom = track_w - knob_w
        if max_scroll == 0 or denom <= 0:
            return
        var target = mouse_x - (sb_left + 1) - drag_offset
        if target < 0: target = 0
        if target > denom: target = denom
        var nx = (target * max_scroll + denom // 2) // denom
        if nx < 0: nx = 0
        if nx > max_scroll: nx = max_scroll
        self.editor.scroll_x = nx

    fn close_button_hit(self, p: Point) -> Bool:
        return p.y == self.rect.a.y and self.rect.a.x + 1 <= p.x and p.x <= self.rect.a.x + 3

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

    fn add(mut self, var window: Window):
        self.windows.append(window^)
        var idx = len(self.windows) - 1
        self.z_order.append(idx)
        self.focused = idx

    fn fit_into(mut self, workspace: Rect):
        """Move (and resize when necessary) every window to fit ``workspace``.

        Used when the workspace shrinks — file tree shown, terminal resized,
        any other change that narrows the floating-window area. Movement is
        preferred; a window is only resized when it's larger than the
        workspace along that axis. Maximized windows are pinned to the new
        workspace so they keep covering it.
        """
        for i in range(len(self.windows)):
            if self.windows[i].is_maximized:
                self.windows[i].rect = workspace
                continue
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
            self.windows[i].rect = Rect(ax, ay, ax + w, ay + h)

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

    fn check_external_changes(mut self) raises -> Int:
        """Re-stat every file-backed editor window; reload any that changed
        and have no unsaved edits. Returns the number of windows reloaded."""
        var reloaded = 0
        for i in range(len(self.windows)):
            if self.windows[i].is_editor:
                if self.windows[i].editor.check_for_external_change():
                    reloaded += 1
        return reloaded

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
        for k in range(len(self.z_order)):
            var i = self.z_order[k]
            self.windows[i].paint(canvas, i == self.focused, i + 1)

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
            var k = len(self.z_order) - 1
            while k >= 0:
                var i = self.z_order[k]
                if self.windows[i].rect.contains(event.pos):
                    return self.windows[i].handle_mouse_in_body(event)
                k -= 1
            return True
        if event.button != MOUSE_BUTTON_LEFT:
            return False
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
                elif vh[0] == 2:
                    var page = self.windows[self.focused].interior().height()
                    self.windows[self.focused].v_scroll_by(-page)
                elif vh[0] == 4:
                    var page = self.windows[self.focused].interior().height()
                    self.windows[self.focused].v_scroll_by(page)
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
                elif hh[0] == 2:
                    var page = self.windows[self.focused].interior().width()
                    self.windows[self.focused].h_scroll_by(-page)
                elif hh[0] == 4:
                    var page = self.windows[self.focused].interior().width()
                    self.windows[self.focused].h_scroll_by(page)
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
