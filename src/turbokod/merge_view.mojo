"""Interactive three-way merge modal.

Opened by ``Desktop.process_external_changes`` when a file changed on
disk while the buffer was dirty *and* the auto 3-way merge
(``diff3_regions``) produced at least one genuine conflict. The view
shows the merged document — auto-merged "stable" runs as plain text and
each conflict inline as a LOCAL block + DISK block + an action bar:

    [◀ Local]  [Disk ▶]  [Both]  [Edit]

Picking ``Local``/``Disk``/``Both`` resolves that hunk; ``Edit`` drops
into a small inline editor seeded from the current choice so the user
can hand-craft the resolution. When every conflict is resolved, Apply
assembles the result, writes it into the editor buffer, and saves to
disk in one step (the host does the buffer swap + save).

It's an in-grid modal — modeled on ``ConfirmDialog`` — painted into the
Desktop ``Canvas`` and routed through ``Desktop.handle_event``, so it
works identically under the terminal and native-macOS frontends with no
frontend-specific code. Resolving every conflict to ``Disk`` is "reload
from disk"; resolving every conflict to ``Local`` is "keep my edits";
anything in between is a real merge — which is why no separate
load/keep/merge choice dialog is needed.
"""

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE,
    ShadowButton, paint_shadow_button,
)
from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_GRAY, WHITE, YELLOW,
)
from .diff import MergeRegion, REGION_CONFLICT, REGION_STABLE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import basename
from .geometry import Point, Rect
from .string_utils import (
    display_columns, prev_codepoint_start, utf8_codepoint_size,
)
from .view import FocusGroup
from .window import hit_close_button, paint_close_button


# --- per-conflict resolution choice -------------------------------------

comptime CHOICE_NONE  = 0
comptime CHOICE_LOCAL = 1
comptime CHOICE_DISK  = 2
comptime CHOICE_BOTH  = 3
comptime CHOICE_EDIT  = 4


@fieldwise_init
struct ConflictState(Copyable, Movable):
    """Resolution state for one CONFLICT region (parallel to the
    conflict subsequence of ``MergeView.regions``). ``edited_lines`` is
    only meaningful when ``choice == CHOICE_EDIT``."""
    var choice: Int
    var edited_lines: List[String]


# --- bottom-bar focus slots ---------------------------------------------

comptime _SLOT_APPLY  = 0
comptime _SLOT_CANCEL = 1

comptime _APPLY_LABEL  = String(" Apply ")
comptime _CANCEL_LABEL = String(" Cancel ")


# --- virtual render rows ------------------------------------------------
# The merged document is flattened into a geometry-independent list of
# RenderRows; paint maps a scroll window of them onto container_bounds rows, and
# handle_mouse re-derives the same list to hit-test the action bars.

comptime _ROW_TEXT      = 0   # stable / agreed line
comptime _ROW_HEADER    = 1   # "── Conflict N/M ──"
comptime _ROW_LABEL     = 2   # "LOCAL (your edits):" / "ON DISK:"
comptime _ROW_LOCAL     = 3   # one of the local lines
comptime _ROW_DISK      = 4   # one of the disk lines
comptime _ROW_EDIT      = 5   # one editable line (choice == CHOICE_EDIT)
comptime _ROW_ACTIONBAR = 6   # the [◀ Local] [Disk ▶] [Both] [Edit] row


@fieldwise_init
struct RenderRow(Copyable, Movable):
    var kind: Int
    var text: String
    var ordinal: Int    # conflict ordinal for conflict-related rows, else -1
    var line_idx: Int   # ROW_EDIT: index into edited_lines (for the caret), else -1


@fieldwise_init
struct _Span(Copyable, Movable):
    """A horizontal click target on the action bar."""
    var x0: Int
    var x1: Int
    var action: Int   # CHOICE_LOCAL / CHOICE_DISK / CHOICE_BOTH / CHOICE_EDIT


comptime _BTN_LOCAL = String("[◀ Local]")
comptime _BTN_DISK  = String("[Disk ▶]")
comptime _BTN_BOTH  = String("[Both]")
comptime _BTN_EDIT  = String("[Edit]")
comptime _BTN_GAP   = 2


struct MergeView(Movable):
    """Modal three-way merge resolver. Single-instance on ``Desktop``;
    ``open`` re-arms it from a fresh set of regions, ``close`` clears it.

    Persistent ``ShadowButton``s for the bottom Apply/Cancel bar (their
    press latch must survive across paints — same reason as
    ``ConfirmDialog``). The per-hunk action bar is hand-rolled bracketed
    text hit-tested against recomputed spans, because there's an
    arbitrary number of conflicts and a fixed button widget per hunk
    wouldn't fit a virtualized, scrolling list.
    """
    var active: Bool
    var done: Bool
    """All conflicts resolved and the user pressed Apply — the host
    reads ``resolved_text`` then calls ``close``."""
    var cancelled: Bool
    """User backed out (Esc / close button / Cancel) — host discards."""
    var regions: List[MergeRegion]
    var states: List[ConflictState]
    """One entry per CONFLICT region, in conflict order."""
    var conflict_count: Int
    var current: Int
    """Which conflict (0-based ordinal) the keyboard actions target."""
    var scroll: Int
    var edit_mode: Bool
    var edit_row: Int
    var edit_col: Int
    """Byte offset of the caret within the current edited line."""
    var target_idx: Int
    """Window index the host seeded at open() — re-validated on Apply."""
    var file_path: String
    var _apply_button: ShadowButton
    var _cancel_button: ShadowButton
    var _focus: FocusGroup

    def __init__(out self):
        self.active = False
        self.done = False
        self.cancelled = False
        self.regions = List[MergeRegion]()
        self.states = List[ConflictState]()
        self.conflict_count = 0
        self.current = 0
        self.scroll = 0
        self.edit_mode = False
        self.edit_row = 0
        self.edit_col = 0
        self.target_idx = -1
        self.file_path = String("")
        self._apply_button = ShadowButton(_APPLY_LABEL, 0, 0)
        self._cancel_button = ShadowButton(_CANCEL_LABEL, 0, 0)
        self._focus = FocusGroup(2)

    def open(
        mut self,
        var regions: List[MergeRegion],
        target_idx: Int,
        var file_path: String,
    ):
        self.conflict_count = 0
        var states = List[ConflictState]()
        for i in range(len(regions)):
            if regions[i].kind == REGION_CONFLICT:
                self.conflict_count += 1
                states.append(ConflictState(CHOICE_NONE, List[String]()))
        self.regions = regions^
        self.states = states^
        self.file_path = file_path^
        self.target_idx = target_idx
        self.active = True
        self.done = False
        self.cancelled = False
        self.current = 0
        self.scroll = 0
        self.edit_mode = False
        self.edit_row = 0
        self.edit_col = 0
        self._focus.focus_force(_SLOT_APPLY)
        self._apply_button.pressed = False
        self._apply_button.pressed_inside = False
        self._cancel_button.pressed = False
        self._cancel_button.pressed_inside = False

    def close(mut self):
        self.active = False
        self.done = False
        self.cancelled = False
        self.regions = List[MergeRegion]()
        self.states = List[ConflictState]()
        self.conflict_count = 0
        self.current = 0
        self.scroll = 0
        self.edit_mode = False
        self.file_path = String("")
        self.target_idx = -1

    # --- resolution ------------------------------------------------------

    def _all_resolved(self) -> Bool:
        for i in range(len(self.states)):
            if self.states[i].choice == CHOICE_NONE:
                return False
        return True

    def _first_unresolved(self) -> Int:
        for i in range(len(self.states)):
            if self.states[i].choice == CHOICE_NONE:
                return i
        return -1

    def resolved_text(self) -> String:
        """Assemble the merged buffer text from the stable runs and each
        conflict's chosen resolution. Joined with ``\\n`` so the host can
        feed it straight to ``TextBuffer(...)``."""
        var out = List[String]()
        var ci = 0
        for ri in range(len(self.regions)):
            ref reg = self.regions[ri]
            if reg.kind == REGION_STABLE:
                for j in range(len(reg.lines)):
                    out.append(reg.lines[j])
            else:
                var ch = self.states[ci].choice
                if ch == CHOICE_DISK:
                    for j in range(len(reg.theirs_lines)):
                        out.append(reg.theirs_lines[j])
                elif ch == CHOICE_BOTH:
                    for j in range(len(reg.ours_lines)):
                        out.append(reg.ours_lines[j])
                    for j in range(len(reg.theirs_lines)):
                        out.append(reg.theirs_lines[j])
                elif ch == CHOICE_EDIT:
                    for j in range(len(self.states[ci].edited_lines)):
                        out.append(self.states[ci].edited_lines[j])
                else:
                    # CHOICE_LOCAL and the defensive CHOICE_NONE fallback.
                    for j in range(len(reg.ours_lines)):
                        out.append(reg.ours_lines[j])
                ci += 1
        var text = String("")
        for i in range(len(out)):
            if i > 0:
                text += String("\n")
            text += out[i]
        return text^

    # --- virtual layout --------------------------------------------------

    def _build_rows(self) -> List[RenderRow]:
        var rows = List[RenderRow]()
        var ci = 0
        for ri in range(len(self.regions)):
            ref reg = self.regions[ri]
            if reg.kind == REGION_STABLE:
                for j in range(len(reg.lines)):
                    rows.append(RenderRow(_ROW_TEXT, reg.lines[j], -1, -1))
            else:
                var st_choice = self.states[ci].choice
                var hdr = String("── Conflict ") + String(ci + 1) \
                    + String("/") + String(self.conflict_count) + String(" ──")
                if st_choice != CHOICE_NONE:
                    hdr += String("  ✓")
                rows.append(RenderRow(_ROW_HEADER, hdr^, ci, -1))
                if st_choice == CHOICE_EDIT:
                    ref ed = self.states[ci].edited_lines
                    if len(ed) == 0:
                        rows.append(RenderRow(_ROW_EDIT, String(""), ci, 0))
                    else:
                        for j in range(len(ed)):
                            rows.append(RenderRow(_ROW_EDIT, ed[j], ci, j))
                else:
                    rows.append(RenderRow(
                        _ROW_LABEL, String("LOCAL (your edits):"), ci, -1))
                    for j in range(len(reg.ours_lines)):
                        rows.append(RenderRow(_ROW_LOCAL, reg.ours_lines[j], ci, -1))
                    rows.append(RenderRow(_ROW_LABEL, String("ON DISK:"), ci, -1))
                    for j in range(len(reg.theirs_lines)):
                        rows.append(RenderRow(_ROW_DISK, reg.theirs_lines[j], ci, -1))
                rows.append(RenderRow(_ROW_ACTIONBAR, String(""), ci, -1))
                ci += 1
        return rows^

    def _action_spans(self, content_x: Int) -> List[_Span]:
        var spans = List[_Span]()
        var x = content_x
        var w = display_columns(_BTN_LOCAL)
        spans.append(_Span(x, x + w, CHOICE_LOCAL)); x += w + _BTN_GAP
        w = display_columns(_BTN_DISK)
        spans.append(_Span(x, x + w, CHOICE_DISK)); x += w + _BTN_GAP
        w = display_columns(_BTN_BOTH)
        spans.append(_Span(x, x + w, CHOICE_BOTH)); x += w + _BTN_GAP
        w = display_columns(_BTN_EDIT)
        spans.append(_Span(x, x + w, CHOICE_EDIT)); x += w + _BTN_GAP
        return spans^

    def _header_vrow_of(self, rows: List[RenderRow], ordinal: Int) -> Int:
        """Virtual-row index of the header for conflict ``ordinal``."""
        for i in range(len(rows)):
            if rows[i].kind == _ROW_HEADER and rows[i].ordinal == ordinal:
                return i
        return -1

    def _layout(self, container_bounds: Rect) -> Rect:
        var width = 100
        if width > container_bounds.b.x - 4:
            width = container_bounds.b.x - 4
        if width < 30:
            width = 30
        var height = 40
        if height > container_bounds.b.y - 4:
            height = container_bounds.b.y - 4
        if height < 10:
            height = 10
        var x = (container_bounds.b.x - width) // 2
        var y = (container_bounds.b.y - height) // 2
        if x < 0: x = 0
        if y < 0: y = 0
        return Rect(x, y, x + width, y + height)

    def _content_rect(self, rect: Rect) -> Rect:
        # Box border (1) + title row (1) at top; status row + button row
        # + button shadow + bottom border (4) at the bottom.
        return Rect(
            rect.a.x + 2, rect.a.y + 2,
            rect.b.x - 2, rect.b.y - 4,
        )

    def _clamp_scroll(mut self, total: Int, visible: Int):
        var max_scroll = total - visible
        if max_scroll < 0:
            max_scroll = 0
        if self.scroll > max_scroll:
            self.scroll = max_scroll
        if self.scroll < 0:
            self.scroll = 0

    def _ensure_current_visible(mut self, container_bounds: Rect):
        var rows = self._build_rows()
        var content = self._content_rect(self._layout(container_bounds))
        var visible = content.height()
        if visible < 1:
            return
        var hv = self._header_vrow_of(rows, self.current)
        if hv < 0:
            return
        if hv < self.scroll:
            self.scroll = hv
        elif hv >= self.scroll + visible:
            self.scroll = hv - visible + 1
        self._clamp_scroll(len(rows), visible)

    # --- paint -----------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var body = Attr(BLACK, LIGHT_GRAY)
        var rect = self._layout(container_bounds)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), body)
        painter.draw_box(canvas, rect, body, False)
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), body)
        var title = String("  Merge: ") + basename(self.file_path)
        _ = painter.put_text(canvas, Point(rect.a.x + 4, rect.a.y), title, body)

        var content = self._content_rect(rect)
        var visible = content.height()
        var content_x = content.a.x
        var rows = self._build_rows()
        self._clamp_scroll(len(rows), visible)

        var cp = Painter(content)
        for vy in range(visible):
            var vrow = self.scroll + vy
            if vrow >= len(rows):
                break
            ref row = rows[vrow]
            var y = content.a.y + vy
            var is_current = row.ordinal == self.current and row.ordinal >= 0
            if row.kind == _ROW_TEXT:
                _ = cp.put_text(canvas, Point(content_x, y), row.text,
                    Attr(BLACK, LIGHT_GRAY))
            elif row.kind == _ROW_HEADER:
                var hattr = Attr(WHITE, BLUE) if is_current else Attr(BLUE, LIGHT_GRAY)
                cp.fill(canvas, Rect(content.a.x, y, content.b.x, y + 1),
                    String(" "), hattr)
                _ = cp.put_text(canvas, Point(content_x, y), row.text, hattr)
            elif row.kind == _ROW_LABEL:
                _ = cp.put_text(canvas, Point(content_x, y), row.text,
                    Attr(BLACK, LIGHT_GRAY, UInt8(1)))
            elif row.kind == _ROW_LOCAL:
                _ = cp.put_text(canvas, Point(content_x + 2, y), row.text,
                    Attr(WHITE, BLUE))
            elif row.kind == _ROW_DISK:
                _ = cp.put_text(canvas, Point(content_x + 2, y), row.text,
                    Attr(BLACK, GREEN))
            elif row.kind == _ROW_EDIT:
                _ = cp.put_text(canvas, Point(content_x + 2, y), row.text,
                    Attr(BLACK, CYAN))
                if self.edit_mode and is_current and row.line_idx == self.edit_row:
                    var pre = row.text.as_bytes()[0:self.edit_col]
                    var cx = content_x + 2 + display_columns(
                        String(StringSlice(unsafe_from_utf8=pre)))
                    cp.set_attr(canvas, cx, y, Attr(CYAN, BLACK))
            elif row.kind == _ROW_ACTIONBAR:
                self._paint_action_bar(canvas, cp, content_x, y, row.ordinal)

        self._paint_footer(canvas, painter, rect)

    def _paint_action_bar(
        self, mut canvas: Canvas, cp: Painter,
        content_x: Int, y: Int, ordinal: Int,
    ):
        var spans = self._action_spans(content_x + 2)
        var choice = self.states[ordinal].choice
        var labels = List[String]()
        labels.append(_BTN_LOCAL)
        labels.append(_BTN_DISK)
        labels.append(_BTN_BOTH)
        labels.append(_BTN_EDIT)
        for i in range(len(spans)):
            var sel = choice == spans[i].action
            var attr = Attr(BLACK, YELLOW) if sel else Attr(BLACK, CYAN)
            _ = cp.put_text(canvas, Point(spans[i].x0, y), labels[i], attr)

    def _paint_footer(mut self, mut canvas: Canvas, painter: Painter, rect: Rect):
        var body = Attr(BLACK, LIGHT_GRAY)
        var resolved = 0
        for i in range(len(self.states)):
            if self.states[i].choice != CHOICE_NONE:
                resolved += 1
        var status: String
        if self.edit_mode:
            status = String("editing — Esc to finish this hunk")
        else:
            status = String(resolved) + String("/") + String(self.conflict_count) \
                + String(" resolved · Tab move · L/D/B choose · E edit · Enter apply")
        var sy = rect.b.y - 4
        _ = painter.put_text(canvas, Point(rect.a.x + 2, sy), status, body)

        # Apply / Cancel buttons, centered, two rows from the bottom border.
        var by = rect.b.y - 3
        var apply_w = self._apply_button.total_width()
        var cancel_w = self._cancel_button.total_width()
        var gap = 2
        var total = apply_w + gap + cancel_w
        var bx = rect.a.x + (rect.width() - total) // 2
        if bx < rect.a.x + 2:
            bx = rect.a.x + 2
        self._apply_button.move_to(bx, by)
        self._cancel_button.move_to(bx + apply_w + gap, by)
        self._focus.update(
            _SLOT_APPLY,
            Rect(bx, by, bx + self._apply_button.face_width(), by + 1))
        self._focus.update(
            _SLOT_CANCEL,
            Rect(bx + apply_w + gap, by,
                 bx + apply_w + gap + self._cancel_button.face_width(), by + 1))
        var apply_face: Attr
        var cancel_face: Attr
        if self._focus.is_focused(_SLOT_APPLY):
            apply_face = Attr(WHITE, BLUE)
            cancel_face = Attr(BLACK, GREEN)
        else:
            apply_face = Attr(BLACK, GREEN)
            cancel_face = Attr(WHITE, BLUE)
        paint_shadow_button(canvas, self._apply_button, apply_face, LIGHT_GRAY)
        paint_shadow_button(canvas, self._cancel_button, cancel_face, LIGHT_GRAY)

    # --- keyboard --------------------------------------------------------

    def _set_choice(mut self, action: Int):
        if self.conflict_count == 0:
            return
        if action == CHOICE_EDIT:
            self._enter_edit_mode()
            return
        self.states[self.current].choice = action

    def _enter_edit_mode(mut self):
        if self.conflict_count == 0:
            return
        var ci = self.current
        var ri = self._current_region_index()
        # Seed the editable lines from the current choice. Default is the
        # local edits (covers CHOICE_LOCAL and the not-yet-picked case),
        # and is also the base the CHOICE_BOTH branch appends onto.
        var seed = self.regions[ri].ours_lines.copy()
        var ch = self.states[ci].choice
        if ch == CHOICE_EDIT:
            seed = self.states[ci].edited_lines.copy()
        elif ch == CHOICE_DISK:
            seed = self.regions[ri].theirs_lines.copy()
        elif ch == CHOICE_BOTH:
            for j in range(len(self.regions[ri].theirs_lines)):
                seed.append(self.regions[ri].theirs_lines[j])
        if len(seed) == 0:
            seed.append(String(""))
        self.states[ci].edited_lines = seed^
        self.states[ci].choice = CHOICE_EDIT
        self.edit_mode = True
        self.edit_row = 0
        self.edit_col = 0

    def _current_region_index(self) -> Int:
        var ci = 0
        for ri in range(len(self.regions)):
            if self.regions[ri].kind == REGION_CONFLICT:
                if ci == self.current:
                    return ri
                ci += 1
        return 0

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        if self.edit_mode:
            self._edit_key(event)
            return True
        var k = event.key
        if k == KEY_ESC:
            self.cancelled = True
            return True
        if k == KEY_TAB:
            if self.conflict_count > 0:
                var backward = (event.mods & MOD_SHIFT) != 0
                if backward:
                    self.current = (self.current - 1 + self.conflict_count) \
                        % self.conflict_count
                else:
                    self.current = (self.current + 1) % self.conflict_count
            return True
        if k == KEY_UP:
            self.scroll -= 1
            if self.scroll < 0:
                self.scroll = 0
            return True
        if k == KEY_DOWN:
            self.scroll += 1
            return True
        if k == KEY_PAGEUP:
            self.scroll -= 10
            if self.scroll < 0:
                self.scroll = 0
            return True
        if k == KEY_PAGEDOWN:
            self.scroll += 10
            return True
        if k == KEY_ENTER:
            if self._all_resolved():
                self.done = True
            else:
                self.current = self._first_unresolved()
            return True
        # Letter shortcuts (raw codepoints; no char constants exist).
        if k == UInt32(0x6C) or k == UInt32(0x4C):       # l / L
            self._set_choice(CHOICE_LOCAL)
            return True
        if k == UInt32(0x64) or k == UInt32(0x44):       # d / D
            self._set_choice(CHOICE_DISK)
            return True
        if k == UInt32(0x62) or k == UInt32(0x42):       # b / B
            self._set_choice(CHOICE_BOTH)
            return True
        if k == UInt32(0x65) or k == UInt32(0x45):       # e / E
            self._set_choice(CHOICE_EDIT)
            return True
        return True

    def _edit_key(mut self, event: Event):
        var k = event.key
        var ci = self.current
        if k == KEY_ESC:
            self.edit_mode = False
            return
        if k == KEY_LEFT:
            if self.edit_col > 0:
                self.edit_col = prev_codepoint_start(
                    self.states[ci].edited_lines[self.edit_row], self.edit_col)
            return
        if k == KEY_RIGHT:
            var line = self.states[ci].edited_lines[self.edit_row]
            if self.edit_col < len(line.as_bytes()):
                self.edit_col += utf8_codepoint_size(
                    Int(line.as_bytes()[self.edit_col]))
            return
        if k == KEY_UP:
            if self.edit_row > 0:
                self.edit_row -= 1
                self._clamp_edit_col()
            return
        if k == KEY_DOWN:
            if self.edit_row < len(self.states[ci].edited_lines) - 1:
                self.edit_row += 1
                self._clamp_edit_col()
            return
        if k == KEY_HOME:
            self.edit_col = 0
            return
        if k == KEY_END:
            self.edit_col = len(self.states[ci].edited_lines[self.edit_row].as_bytes())
            return
        if k == KEY_BACKSPACE:
            self._edit_backspace()
            return
        if k == KEY_ENTER:
            self._edit_split()
            return
        # Printable insert: same range gate the editor uses.
        if (UInt32(0x20) <= k and k < UInt32(0x7F)) \
                or (UInt32(0xA0) <= k and k < UInt32(0xE000)) \
                or k > UInt32(0xF8FF):
            if (event.mods & (MOD_CTRL | MOD_ALT | MOD_META)) != 0:
                return
            self._edit_insert(chr(Int(k)))

    def _clamp_edit_col(mut self):
        var n = len(self.states[self.current].edited_lines[self.edit_row].as_bytes())
        if self.edit_col > n:
            self.edit_col = n

    def _edit_insert(mut self, s: String):
        var ci = self.current
        var line = self.states[ci].edited_lines[self.edit_row]
        var b = line.as_bytes()
        var head = String(StringSlice(unsafe_from_utf8=b[0:self.edit_col]))
        var tail = String(StringSlice(unsafe_from_utf8=b[self.edit_col:len(b)]))
        self.states[ci].edited_lines[self.edit_row] = head + s + tail
        self.edit_col += len(s.as_bytes())

    def _edit_backspace(mut self):
        var ci = self.current
        if self.edit_col > 0:
            var line = self.states[ci].edited_lines[self.edit_row]
            var b = line.as_bytes()
            var start = prev_codepoint_start(line, self.edit_col)
            var head = String(StringSlice(unsafe_from_utf8=b[0:start]))
            var tail = String(StringSlice(unsafe_from_utf8=b[self.edit_col:len(b)]))
            self.states[ci].edited_lines[self.edit_row] = head + tail
            self.edit_col = start
        elif self.edit_row > 0:
            # Join with the previous line.
            var prev = self.states[ci].edited_lines[self.edit_row - 1]
            var cur = self.states[ci].edited_lines[self.edit_row]
            self.edit_col = len(prev.as_bytes())
            self.states[ci].edited_lines[self.edit_row - 1] = prev + cur
            _ = self.states[ci].edited_lines.pop(self.edit_row)
            self.edit_row -= 1

    def _edit_split(mut self):
        var ci = self.current
        var line = self.states[ci].edited_lines[self.edit_row]
        var b = line.as_bytes()
        var head = String(StringSlice(unsafe_from_utf8=b[0:self.edit_col]))
        var tail = String(StringSlice(unsafe_from_utf8=b[self.edit_col:len(b)]))
        self.states[ci].edited_lines[self.edit_row] = head
        self.states[ci].edited_lines.insert(self.edit_row + 1, tail)
        self.edit_row += 1
        self.edit_col = 0

    # --- mouse -----------------------------------------------------------

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._layout(container_bounds)
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion \
                and hit_close_button(Point(rect.a.x, rect.a.y), event.pos):
            self.cancelled = True
            return True
        # Mouse wheel scrolls the merged document.
        if event.button == MOUSE_WHEEL_UP:
            self.scroll -= 3
            if self.scroll < 0:
                self.scroll = 0
            return True
        if event.button == MOUSE_WHEEL_DOWN:
            self.scroll += 3
            return True
        # Action-bar hit-testing (only on a real left press).
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion and not self.edit_mode:
            var content = self._content_rect(rect)
            if content.contains(event.pos):
                var rows = self._build_rows()
                var vrow = self.scroll + (event.pos.y - content.a.y)
                if 0 <= vrow and vrow < len(rows):
                    ref row = rows[vrow]
                    if row.kind == _ROW_ACTIONBAR:
                        var spans = self._action_spans(content.a.x + 2)
                        for i in range(len(spans)):
                            if spans[i].x0 <= event.pos.x \
                                    and event.pos.x < spans[i].x1:
                                self.current = row.ordinal
                                self._set_choice(spans[i].action)
                                return True
                    elif row.ordinal >= 0:
                        # Click anywhere in a conflict block selects it.
                        self.current = row.ordinal
                        return True
        # Bottom Apply / Cancel buttons.
        _ = self._focus.handle_click(event)
        var s = self._apply_button.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                if self._all_resolved():
                    self.done = True
                else:
                    self.current = self._first_unresolved()
            return True
        s = self._cancel_button.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self.cancelled = True
            return True
        return True
