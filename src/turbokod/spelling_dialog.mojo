"""Project ▸ Spelling: every word the spell checker flags across the
project, most frequent first, with buttons to teach the dictionaries.

The dialog owns a ``ProjectSpellScan`` and advances it from ``tick``
(called once a frame by the host), painting a progress bar until the
scan is done. Rows stream in while it runs and the list re-sorts by
count on every frame that changed it; the cursor follows its word once
the user has moved it, and otherwise stays on the top row.

The list is a multi-select ``ListBox`` (Windows extended-selection
behavior — see ``list_box.mojo`` for the click / drag / key rules).
"Add to Project" / "Add to User" hand the selected words to the host
(``submitted`` + ``action``), which writes them to the dictionary and
calls ``remove_words`` so the rows disappear.

``ListBox`` selects by row index, but rows move whenever the list
re-sorts, so ``_resort`` carries the selection across by word *key*.
"""

from std.collections.dict import Dict
from std.collections.list import List

from .buttons import (
    BUTTON_FIRED, BUTTON_NONE, button_face, paint_shadow_button, ShadowButton,
)
from .canvas import Canvas
from .colors import Attr, BLACK, BLUE, DARK_GRAY, LIGHT_GRAY
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_ENTER, KEY_ESC, KEY_TAB, MOD_SHIFT,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect, center_in
from .list_box import ListBox
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


struct _CarriedSelection(Copyable, Movable):
    """A selection expressed as word keys, so it survives a re-sort."""
    var active: Bool
    var keys: List[String]
    var caret: String
    var anchor: String

    def __init__(out self):
        self.active = False
        self.keys = List[String]()
        self.caret = String("")
        self.anchor = String("")


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
    var list: ListBox
    """Selection, caret and scroll over ``order``'s rows."""
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
        self.list = ListBox(multi=True)
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
        self.list.reset()
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
        self.list.reset()

    def tick(mut self, speller: Speller):
        """Advance the scan by one frame's budget and keep the list
        sorted. Called by the host every frame; free when closed."""
        if not self.active:
            return
        if self.scan.active:
            _ = self.scan.step(_SCAN_BUDGET_MS, speller)
        if self._sorted_version != self.scan.version:
            self._resort(self._carried_selection())

    # --- results ----------------------------------------------------------

    def selected_keys(self) -> List[String]:
        """Selected words in list order — what an Add button applies to."""
        var out = List[String]()
        for i in range(len(self.order)):
            if self.list.is_selected(i):
                out.append(self._key_at(i))
        return out^

    def acknowledge(mut self, added: List[String]):
        """The host handled an Add: drop those rows and clear the
        selection, keeping the cursor near where it was."""
        self.submitted = False
        self.action = SPELLING_NONE
        var caret = max(self.list.selected, 0)
        # ``order`` indexes the word list ``remove_keys`` is about to
        # shrink, so drop it before anything reads it again. The caret
        # keeps its row number rather than following a removed word.
        self.order = List[Int]()
        self.scan.remove_keys(added)
        self._resort(_CarriedSelection())
        if len(self.order) > 0:
            self.list.set_selected(min(caret, len(self.order) - 1))

    # --- sorting ----------------------------------------------------------

    def _carried_selection(self) -> _CarriedSelection:
        """The selection as word keys, to survive a re-sort. Nothing is
        carried until the user has selected something: before that the
        caret just stays on its row, the top one."""
        var c = _CarriedSelection()
        if self.list.selected_count() == 0:
            return c^
        c.active = True
        c.keys = self.selected_keys()
        if 0 <= self.list.selected and self.list.selected < len(self.order):
            c.caret = self._key_at(self.list.selected)
        var a = self.list.anchor()
        if 0 <= a and a < len(self.order):
            c.anchor = self._key_at(a)
        return c^

    def _resort(mut self, carried: _CarriedSelection):
        """Rebuild ``order`` (count descending, then word) and re-apply
        ``carried`` to the new row numbers."""
        var idx = List[Int](capacity=len(self.scan.words))
        for i in range(len(self.scan.words)):
            idx.append(i)
        _merge_sort(idx, self.scan.words)
        self.order = idx^
        self._sorted_version = self.scan.version
        var n = len(self.order)
        if not carried.active:
            self.list.set_selection(
                List[Int](), max(min(self.list.selected, n - 1), 0),
                self.list.anchor(), n,
            )
            return
        var wanted = Dict[String, Bool]()
        for i in range(len(carried.keys)):
            wanted[carried.keys[i]] = True
        var rows = List[Int]()
        var caret = -1
        var anchor = -1
        for i in range(n):
            var key = self._key_at(i)
            if key in wanted:
                rows.append(i)
            if key == carried.caret:
                caret = i
            if key == carried.anchor:
                anchor = i
        if caret < 0:
            caret = max(min(self.list.selected, n - 1), 0)
        self.list.set_selection(rows, caret, anchor, n)

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
        var list_focused = self._focus.is_focused(_SLOT_LIST)
        var first = self.list.prepare(self._list_rect, len(self.order))
        var labels = List[String]()
        for i in range(
            first,
            min(first + max(self._list_rect.height(), 0), len(self.order)),
        ):
            var w = self.scan.words[self.order[i]]
            # Count right-aligned in its column, then the word; the
            # list's own one-cell indent puts the count at ``x0``.
            var count = String(w.count)
            var pad = max(_COUNT_W - 2 - display_columns(count), 0)
            labels.append(String(" ") * pad + count + String("  ") + w.word)
        self.list.paint_rows(canvas, self._list_rect, labels, list_focused, bg)
        if len(self.order) == 0:
            var msg = String("Looking for misspellings…") if self.scan.active \
                else String("No misspellings found.")
            _ = painter.put_text(canvas, Point(x0, list_top), msg, dim)
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
        var n_selected = self.list.selected_count()
        var any_sel = n_selected > 0
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
            String(String(n_selected) + String(" selected")), dim,
        )

    # --- events -----------------------------------------------------------

    def _submit(mut self, action: Int):
        if self.list.selected_count() == 0:
            return
        if action == SPELLING_ADD_PROJECT and not self.has_project:
            return
        self.action = action
        self.submitted = True

    def _key_at(self, i: Int) -> String:
        return self.scan.words[self.order[i]].key

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
        var page = max(self._list_rect.height() - 1, 1)
        if self.list.handle_nav_key(event, len(self.order), page):
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
        if self.list.handle_mouse_drag(event, self._list_rect, len(self.order)):
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
        if self.list.handle_mouse_press(event, self._list_rect, len(self.order)):
            if event.button == MOUSE_BUTTON_LEFT:
                self._focus.focus_force(_SLOT_LIST)
            return True
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
