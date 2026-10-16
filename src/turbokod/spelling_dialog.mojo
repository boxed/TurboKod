"""Project ▸ Spelling: every word the spell checker flags across the
project, most frequent first, with buttons to teach the dictionaries.

The dialog owns a ``ProjectSpellScan`` and advances it from ``tick``
(called once a frame by the host), painting a progress bar until the
scan is done. Rows stream in while it runs and the list re-sorts by
count on every frame that changed it; the cursor follows its word once
the user has moved it, and otherwise stays on the top row.

Selection is multi: click selects one row, Shift-click / Shift-arrows
extend a range, Ctrl- or Cmd-click / Space toggle a row, Ctrl+A
selects everything. "Add to Project" / "Add to User" hand the selected
words to the host (``submitted`` + ``action``), which writes them to
the dictionary and calls ``remove_words`` so the rows disappear.

Selection is held by word *key*, not row index, because rows move
whenever the list re-sorts.
"""

from std.collections.list import List

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, button_face, paint_shadow_button, ShadowButton,
)
from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, CYAN, DARK_GRAY, LIGHT_GRAY, WHITE
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_HOME, KEY_PAGEDOWN, KEY_PAGEUP, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_CTRL, MOD_META, MOD_SHIFT, MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN,
    MOUSE_WHEEL_UP,
)
from .geometry import Point, Rect, center_in
from .spell import Speller
from .spell_scan import ProjectSpellScan, SpellScanWord
from .string_utils import display_columns
from .view import FocusGroup
from .window import close_button_clicked, paint_modal_frame, paint_window_title


comptime SPELLING_NONE = 0
comptime SPELLING_ADD_PROJECT = 1
comptime SPELLING_ADD_USER = 2

comptime _SLOT_LIST = 0
comptime _SLOT_PROJECT = 1
comptime _SLOT_USER = 2
comptime _SLOT_CLOSE = 3

comptime _SCAN_BUDGET_MS = 40
"""Scan time spent per frame. The Swift host ticks every 50 ms (and the
terminal loops stop waiting on input while a scan runs — see
``Desktop.has_background_work``), so this leaves room for input and
paint while giving the scan most of the frame."""

comptime _MAX_WIDTH = 72
comptime _COUNT_W = 8
"""Columns for the right-aligned count, including its gap."""

comptime _KEY_A = UInt32(0x61)
comptime _KEY_A_UPPER = UInt32(0x41)


struct SpellingDialog(Movable):
    var active: Bool
    var submitted: Bool
    """True when the user pressed one of the Add buttons. The host reads
    ``action`` and ``selected_keys()``, then calls ``acknowledge``."""
    var action: Int
    var scan: ProjectSpellScan
    var order: List[Int]
    """Rows on screen: indices into ``scan.words``, by count descending."""
    var _sorted_version: Int
    var selected: List[String]
    """Keys of the selected rows."""
    var cursor: Int
    """Row (index into ``order``) the keyboard is on."""
    var _anchor_key: String
    """Range anchor for Shift-click / Shift-arrows."""
    var scroll: Int
    var _list_rect: Rect
    var _project_button: ShadowButton
    var _user_button: ShadowButton
    var _close_button: ShadowButton
    var _focus: FocusGroup
    var has_project: Bool

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.action = SPELLING_NONE
        self.scan = ProjectSpellScan()
        self.order = List[Int]()
        self._sorted_version = -1
        self.selected = List[String]()
        self.cursor = 0
        self._anchor_key = String("")
        self.scroll = 0
        self._list_rect = Rect(0, 0, 0, 0)
        self._project_button = ShadowButton(String(" Add to Project "), 0, 0)
        self._user_button = ShadowButton(String(" Add to User "), 0, 0)
        self._close_button = ShadowButton(String(" Close "), 0, 0)
        self._focus = FocusGroup(4)
        self.has_project = False

    def open(mut self, var files: List[String], has_project: Bool):
        """Start a fresh scan of ``files`` and show the dialog."""
        self.active = True
        self.submitted = False
        self.action = SPELLING_NONE
        self.has_project = has_project
        self.scan.start(files^)
        self.order = List[Int]()
        self._sorted_version = -1
        self.selected = List[String]()
        self.cursor = 0
        self._anchor_key = String("")
        self.scroll = 0
        self._focus.focus_force(_SLOT_LIST)
        self._project_button.reset_press()
        self._user_button.reset_press()
        self._close_button.reset_press()

    def close(mut self):
        self.active = False
        self.submitted = False
        self.action = SPELLING_NONE
        self.scan.cancel()
        self.order = List[Int]()
        self.selected = List[String]()

    def tick(mut self, speller: Speller):
        """Advance the scan by one frame's budget and keep the list
        sorted. Called by the host every frame; free when closed."""
        if not self.active:
            return
        if self.scan.active:
            _ = self.scan.step(_SCAN_BUDGET_MS, speller)
        if self._sorted_version != self.scan.version:
            var cursor_key = String("")
            if len(self.selected) > 0 and 0 <= self.cursor \
                    and self.cursor < len(self.order):
                cursor_key = self._key_at(self.cursor)
            self._resort(cursor_key)

    # --- results ----------------------------------------------------------

    def selected_keys(self) -> List[String]:
        """Selected words in list order — what an Add button applies to."""
        var out = List[String]()
        for i in range(len(self.order)):
            var key = self.scan.words[self.order[i]].key
            if self._is_selected(key):
                out.append(key)
        return out^

    def acknowledge(mut self, added: List[String]):
        """The host handled an Add: drop those rows and clear the
        selection, keeping the cursor near where it was."""
        self.submitted = False
        self.action = SPELLING_NONE
        # ``order`` indexes the word list ``remove_keys`` is about to
        # shrink, so drop it before anything reads it again. The cursor
        # keeps its row number rather than following a removed word.
        self.order = List[Int]()
        self.scan.remove_keys(added)
        self.selected = List[String]()
        self._anchor_key = String("")
        self._resort(String(""))
        if self.cursor >= len(self.order):
            self.cursor = max(len(self.order) - 1, 0)
        if len(self.order) > 0:
            var key = self.scan.words[self.order[self.cursor]].key
            self.selected.append(key)
            self._anchor_key = key

    def _is_selected(self, key: String) -> Bool:
        for i in range(len(self.selected)):
            if self.selected[i] == key:
                return True
        return False

    # --- sorting ----------------------------------------------------------

    def _resort(mut self, cursor_key: String):
        """Rebuild ``order`` (count descending, then word), keeping the
        cursor on ``cursor_key`` when it's still listed."""
        var idx = List[Int](capacity=len(self.scan.words))
        for i in range(len(self.scan.words)):
            idx.append(i)
        _merge_sort(idx, self.scan.words)
        self.order = idx^
        self._sorted_version = self.scan.version
        if len(cursor_key.as_bytes()) > 0:
            for i in range(len(self.order)):
                if self.scan.words[self.order[i]].key == cursor_key:
                    self.cursor = i
                    break
        if self.cursor >= len(self.order):
            self.cursor = max(len(self.order) - 1, 0)

    # --- layout + paint ---------------------------------------------------

    def _rect(self, bounds: Rect) -> Rect:
        var w = min(_MAX_WIDTH, bounds.width() - 4)
        var h = bounds.height() - 4
        return center_in(bounds, max(w, 30), max(h, 12))

    def paint(mut self, mut canvas: Canvas, bounds: Rect):
        if not self.active:
            return
        var bg = Attr(BLACK, LIGHT_GRAY)
        var dim = Attr(DARK_GRAY, LIGHT_GRAY)
        var rect = self._rect(bounds)
        var painter = paint_modal_frame(canvas, rect, bg)
        paint_window_title(canvas, rect, String(" Spelling "), bg, bg)
        var x0 = rect.a.x + 2
        var x1 = rect.b.x - 2
        var y = rect.a.y + 1
        # Status line + progress bar.
        var n_files = len(self.scan.files)
        var status: String
        if self.scan.active:
            status = String("Scanning ") + String(self.scan.files_done) \
                + String(" / ") + String(n_files) + String(" files…")
        else:
            status = String(self.scan.files_checked) + String(" files checked, ") \
                + String(len(self.scan.words)) + String(" suspect words")
        _ = painter.put_text(canvas, Point(x0, y), status, bg)
        y += 1
        if self.scan.active:
            _paint_bar(canvas, x0, y, x1 - x0, self.scan.progress())
        y += 2
        # List.
        var list_top = y
        var list_bottom = rect.b.y - 4
        self._list_rect = Rect(rect.a.x + 1, list_top, rect.b.x - 1, list_bottom)
        var rows = list_bottom - list_top
        self._clamp_scroll(rows)
        var list_focused = self._focus.is_focused(_SLOT_LIST)
        var sel_attr = Attr(WHITE, BLUE) if list_focused else Attr(BLACK, CYAN)
        if len(self.order) == 0:
            var msg = String("Looking for misspellings…") if self.scan.active \
                else String("No misspellings found.")
            _ = painter.put_text(canvas, Point(x0, list_top), msg, dim)
        for r in range(rows):
            var i = self.scroll + r
            if i >= len(self.order):
                break
            var w = self.scan.words[self.order[i]]
            var row_attr = sel_attr if self._is_selected(w.key) else bg
            painter.fill(
                canvas, Rect(rect.a.x + 1, list_top + r, rect.b.x - 1, list_top + r + 1),
                String(" "), row_attr,
            )
            if list_focused and i == self.cursor:
                _ = painter.put_text(canvas, Point(rect.a.x + 1, list_top + r), String("►"), row_attr)
            var count = String(w.count)
            var cx = x0 + _COUNT_W - 2 - display_columns(count)
            _ = painter.put_text(canvas, Point(cx, list_top + r), count, row_attr)
            _ = painter.put_text(canvas, Point(x0 + _COUNT_W, list_top + r), w.word, row_attr)
        # Buttons.
        var by = rect.b.y - 3
        var gap = 2
        var pw = self._project_button.total_width()
        var uw = self._user_button.total_width()
        var cw = self._close_button.total_width()
        var bx = rect.b.x - 2 - (pw + gap + uw + gap + cw)
        self._project_button.move_to(bx, by)
        self._user_button.move_to(bx + pw + gap, by)
        self._close_button.move_to(bx + pw + gap + uw + gap, by)
        var any_sel = len(self.selected) > 0
        self._focus.update(_SLOT_LIST, self._list_rect)
        self._focus.update(
            _SLOT_PROJECT, self._project_button.hit_rect(),
            visitable=self.has_project,
        )
        self._focus.update(_SLOT_USER, self._user_button.hit_rect())
        self._focus.update(_SLOT_CLOSE, self._close_button.hit_rect())
        paint_shadow_button(
            canvas, self._project_button,
            button_face(self._focus.is_focused(_SLOT_PROJECT),
                        enabled=any_sel and self.has_project),
            LIGHT_GRAY,
        )
        paint_shadow_button(
            canvas, self._user_button,
            button_face(self._focus.is_focused(_SLOT_USER), enabled=any_sel),
            LIGHT_GRAY,
        )
        paint_shadow_button(
            canvas, self._close_button,
            button_face(self._focus.is_focused(_SLOT_CLOSE)), LIGHT_GRAY,
        )
        _ = painter.put_text(
            canvas, Point(x0, by),
            String(String(len(self.selected)) + String(" selected")), dim,
        )

    def _clamp_scroll(mut self, rows: Int):
        if rows <= 0:
            return
        if self.cursor < self.scroll:
            self.scroll = self.cursor
        if self.cursor >= self.scroll + rows:
            self.scroll = self.cursor - rows + 1
        var max_scroll = max(len(self.order) - rows, 0)
        if self.scroll > max_scroll:
            self.scroll = max_scroll
        if self.scroll < 0:
            self.scroll = 0

    # --- events -----------------------------------------------------------

    def _submit(mut self, action: Int):
        if len(self.selected) == 0:
            return
        if action == SPELLING_ADD_PROJECT and not self.has_project:
            return
        self.action = action
        self.submitted = True

    def _key_at(self, i: Int) -> String:
        return self.scan.words[self.order[i]].key

    def _select_only(mut self, i: Int):
        self.selected = List[String]()
        if 0 <= i and i < len(self.order):
            var key = self._key_at(i)
            self.selected.append(key)
            self._anchor_key = key

    def _toggle(mut self, i: Int):
        if i < 0 or i >= len(self.order):
            return
        var key = self._key_at(i)
        var kept = List[String]()
        var was = False
        for k in range(len(self.selected)):
            if self.selected[k] == key:
                was = True
            else:
                kept.append(self.selected[k])
        if not was:
            kept.append(key)
        self.selected = kept^
        self._anchor_key = key

    def _select_range_to(mut self, i: Int):
        """Select from the anchor row to ``i`` inclusive."""
        var a = -1
        for k in range(len(self.order)):
            if self._key_at(k) == self._anchor_key:
                a = k
                break
        if a < 0:
            self._select_only(i)
            return
        self.selected = List[String]()
        for k in range(min(a, i), max(a, i) + 1):
            self.selected.append(self._key_at(k))

    def _move_cursor(mut self, to: Int, extend: Bool):
        if len(self.order) == 0:
            return
        self.cursor = max(0, min(to, len(self.order) - 1))
        if extend:
            self._select_range_to(self.cursor)
        else:
            self._select_only(self.cursor)

    def handle_key(mut self, event: Event) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_TAB:
            self._focus.cycle(backward=(event.mods & MOD_SHIFT) != 0)
            return True
        if k == KEY_ENTER:
            if self._focus.is_focused(_SLOT_PROJECT):
                self._submit(SPELLING_ADD_PROJECT)
            elif self._focus.is_focused(_SLOT_USER):
                self._submit(SPELLING_ADD_USER)
            elif self._focus.is_focused(_SLOT_CLOSE):
                self.close()
            return True
        if (k == _KEY_A or k == _KEY_A_UPPER) \
                and (event.mods & (MOD_CTRL | MOD_META)) != 0:
            self.selected = List[String]()
            for i in range(len(self.order)):
                self.selected.append(self._key_at(i))
            return True
        var extend = (event.mods & MOD_SHIFT) != 0
        var page = max(self._list_rect.height() - 1, 1)
        if k == KEY_UP:
            self._move_cursor(self.cursor - 1, extend)
        elif k == KEY_DOWN:
            self._move_cursor(self.cursor + 1, extend)
        elif k == KEY_PAGEUP:
            self._move_cursor(self.cursor - page, extend)
        elif k == KEY_PAGEDOWN:
            self._move_cursor(self.cursor + page, extend)
        elif k == KEY_HOME:
            self._move_cursor(0, extend)
        elif k == KEY_END:
            self._move_cursor(len(self.order) - 1, extend)
        elif k == KEY_SPACE:
            self._toggle(self.cursor)
        else:
            return True
        self._focus.focus_force(_SLOT_LIST)
        return True

    def handle_mouse(mut self, event: Event, bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(bounds)
        if close_button_clicked(rect, event):
            self.close()
            return True
        if event.pressed and not event.motion:
            if event.button == MOUSE_WHEEL_UP:
                self.scroll = max(self.scroll - 3, 0)
                self.cursor = min(self.cursor, self.scroll + self._list_rect.height() - 1)
                self.cursor = max(self.cursor, self.scroll)
                return True
            if event.button == MOUSE_WHEEL_DOWN:
                var max_scroll = max(len(self.order) - self._list_rect.height(), 0)
                self.scroll = min(self.scroll + 3, max_scroll)
                self.cursor = max(self.cursor, self.scroll)
                return True
        var s = self._project_button.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self._submit(SPELLING_ADD_PROJECT)
            return True
        s = self._user_button.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self._submit(SPELLING_ADD_USER)
            return True
        s = self._close_button.handle_mouse(event)
        if s != BUTTON_NONE:
            if s == BUTTON_FIRED:
                self.close()
            return True
        if event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion and self._list_rect.contains(event.pos):
            var i = self.scroll + (event.pos.y - self._list_rect.a.y)
            if i >= len(self.order):
                return True
            self._focus.focus_force(_SLOT_LIST)
            self.cursor = i
            if (event.mods & MOD_SHIFT) != 0:
                self._select_range_to(i)
            elif (event.mods & (MOD_CTRL | MOD_META)) != 0:
                self._toggle(i)
            else:
                self._select_only(i)
        return True


def _paint_bar(mut canvas: Canvas, x: Int, y: Int, width: Int, frac: Float64):
    """A one-row progress bar: ``frac`` of ``width`` filled."""
    if width <= 0:
        return
    var filled = Int(frac * Float64(width))
    var on = Attr(BLUE, LIGHT_GRAY)
    var off = Attr(DARK_GRAY, LIGHT_GRAY)
    for i in range(width):
        if i < filled:
            _ = canvas.put_text(Point(x + i, y), String("█"), on)
        else:
            _ = canvas.put_text(Point(x + i, y), String("░"), off)


def _before(a: SpellScanWord, b: SpellScanWord) -> Bool:
    """List order: higher count first, then the word alphabetically."""
    if a.count != b.count:
        return a.count > b.count
    return a.key < b.key


def _merge_sort(mut idx: List[Int], words: List[SpellScanWord]):
    """Stable sort of ``idx`` (indices into ``words``) by ``_before``.
    Merge sort rather than insertion: a project yields thousands of
    distinct words and the list re-sorts while the scan runs."""
    var n = len(idx)
    if n < 2:
        return
    var buf = List[Int](capacity=n)
    for i in range(n):
        buf.append(idx[i])
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if _before(words[idx[j]], words[idx[i]]):
                    buf[k] = idx[j]
                    j += 1
                else:
                    buf[k] = idx[i]
                    i += 1
                k += 1
            while i < mid:
                buf[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                buf[k] = idx[j]
                j += 1
                k += 1
            lo += 2 * width
        for t in range(n):
            idx[t] = buf[t]
        width *= 2
