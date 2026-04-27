"""QuickOpen: type-to-filter file picker for the active project.

A modal centered dialog. The user types a substring of the path; the list
below the input filters as they type. Arrow keys / PgUp / PgDn navigate;
Enter submits the selected entry; Esc cancels. ``submitted`` /
``selected_path`` mirror ``FileDialog`` so the desktop owner can either
inspect them or rely on ``Desktop`` to dispatch into ``open_file``.

The candidate set comes from ``walk_project_files(root)`` — gitignore-
respected by default, so ``tvision/`` style large vendored trees stay out
of the picker.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, WHITE, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESC, KEY_PAGEDOWN, KEY_PAGEUP,
    KEY_UP, MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import join_path
from .geometry import Point, Rect
from .project import walk_project_files


struct QuickOpen(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    var query: String
    var selected_path: String
    # Candidate paths kept relative to the project root for display; we
    # join with ``root`` only when the user submits.
    var entries: List[String]
    # Indices into ``entries`` that match the current query.
    var matched: List[Int]
    var selected: Int
    var scroll: Int

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = String("")
        self.selected_path = String("")
        self.entries = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0

    fn open(mut self, var root: String):
        self.root = root^
        self.query = String("")
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.selected = 0
        self.scroll = 0
        # Load candidate set from disk. Paths come back absolute; strip the
        # root prefix so the picker shows the project-relative form.
        self.entries = List[String]()
        var paths = walk_project_files(self.root)
        var rb = self.root.as_bytes()
        for i in range(len(paths)):
            var fb = paths[i].as_bytes()
            if len(fb) > len(rb) + 1:
                var matches_root = True
                for k in range(len(rb)):
                    if fb[k] != rb[k]:
                        matches_root = False
                        break
                if matches_root and fb[len(rb)] == 0x2F:
                    self.entries.append(String(StringSlice(
                        unsafe_from_utf8=fb[len(rb) + 1:],
                    )))
                    continue
            self.entries.append(paths[i])
        self._refilter()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = String("")
        self.selected_path = String("")
        self.entries = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0

    # --- filtering --------------------------------------------------------

    fn _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.as_bytes()) == 0:
            for i in range(len(self.entries)):
                self.matched.append(i)
        else:
            for i in range(len(self.entries)):
                if quick_open_match(self.entries[i], self.query):
                    self.matched.append(i)
        self.selected = 0
        self.scroll = 0

    # --- geometry ---------------------------------------------------------

    fn _rect(self, screen: Rect) -> Rect:
        var width = 70
        var height = 20
        if width > screen.b.x - 4: width = screen.b.x - 4
        if height > screen.b.y - 4: height = screen.b.y - 4
        var x = (screen.b.x - width) // 2
        var y = (screen.b.y - height) // 2
        return Rect(x, y, x + width, y + height)

    fn _list_top(self, rect: Rect) -> Int:
        return rect.a.y + 3

    fn _list_height(self, rect: Rect) -> Int:
        var h = (rect.b.y - 1) - self._list_top(rect)
        if h < 0:
            return 0
        return h

    # --- paint ------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var title_attr  = Attr(WHITE,  BLUE)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var rect = self._rect(screen)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        var title = String(" Quick Open ")
        var tx = rect.a.x + (rect.width() - len(title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), title, title_attr)
        # Search line: ``Find: <query>_``
        var label = String(" Find: ")
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.a.y + 1), label, bg, rect.b.x - 1,
        )
        var qx = rect.a.x + 2 + len(label.as_bytes())
        _ = canvas.put_text(
            Point(qx, rect.a.y + 1), self.query, bg, rect.b.x - 1,
        )
        var cur = qx + len(self.query.as_bytes())
        if cur < rect.b.x - 1:
            canvas.set(cur, rect.a.y + 1, Cell(String(" "), Attr(LIGHT_GRAY, BLACK), 1))
        # Listing.
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matched):
                break
            var entry = self.entries[self.matched[idx]]
            var attr = sel_attr if idx == self.selected else bg
            canvas.fill(
                Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), attr,
            )
            _ = canvas.put_text(
                Point(rect.a.x + 2, top + i), entry, attr, rect.b.x - 1,
            )
        # Bottom hint.
        _ = canvas.put_text(
            Point(rect.a.x + 2, rect.b.y - 1),
            String(" Enter: open  ESC: cancel "),
            hint_attr, rect.b.x - 1,
        )

    # --- events -----------------------------------------------------------

    fn handle_key(mut self, event: Event) -> Bool:
        """Returns True if the event was consumed (always True while active)."""
        if not self.active:
            return False
        if event.kind != EVENT_KEY:
            return True
        var k = event.key
        if k == KEY_ESC:
            self.close()
            return True
        if k == KEY_ENTER:
            if self.selected < 0 or self.selected >= len(self.matched):
                return True
            var rel = self.entries[self.matched[self.selected]]
            self.selected_path = join_path(self.root, rel)
            self.submitted = True
            return True
        if k == KEY_UP:
            if self.selected > 0:
                self.selected -= 1
                self._scroll_to_selection()
            return True
        if k == KEY_DOWN:
            if self.selected + 1 < len(self.matched):
                self.selected += 1
                self._scroll_to_selection()
            return True
        if k == KEY_PAGEUP:
            self.selected -= 10
            if self.selected < 0:
                self.selected = 0
            self._scroll_to_selection()
            return True
        if k == KEY_PAGEDOWN:
            self.selected += 10
            if self.selected >= len(self.matched):
                self.selected = len(self.matched) - 1
            if self.selected < 0:
                self.selected = 0
            self._scroll_to_selection()
            return True
        if k == KEY_BACKSPACE:
            var qb = self.query.as_bytes()
            if len(qb) > 0:
                self.query = String(StringSlice(
                    unsafe_from_utf8=qb[:len(qb) - 1],
                ))
                self._refilter()
            return True
        # Modified letters are commands (e.g., a hotkey) — leave them alone.
        if (event.mods & MOD_CTRL) != 0 or (event.mods & MOD_ALT) != 0:
            return True
        if UInt32(0x20) <= k and k < UInt32(0x7F):
            self.query = self.query + chr(Int(k))
            self._refilter()
            return True
        return True

    fn handle_mouse(mut self, event: Event, screen: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(screen)
        if event.pressed and not event.motion:
            if event.button == MOUSE_WHEEL_UP:
                if self.scroll > 0:
                    self.scroll -= 3
                    if self.scroll < 0:
                        self.scroll = 0
                return True
            if event.button == MOUSE_WHEEL_DOWN:
                var h = self._list_height(rect)
                var max_scroll = len(self.matched) - h
                if max_scroll < 0:
                    max_scroll = 0
                if self.scroll < max_scroll:
                    self.scroll += 3
                    if self.scroll > max_scroll:
                        self.scroll = max_scroll
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True
        var top = self._list_top(rect)
        var h = self._list_height(rect)
        if event.pos.y < top or event.pos.y >= top + h:
            return True
        var idx = self.scroll + (event.pos.y - top)
        if idx < 0 or idx >= len(self.matched):
            return True
        if idx == self.selected:
            var rel = self.entries[self.matched[idx]]
            self.selected_path = join_path(self.root, rel)
            self.submitted = True
            return True
        self.selected = idx
        return True

    fn _scroll_to_selection(mut self):
        var visible = 14
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + visible:
            self.scroll = self.selected - visible + 1


# --- match algorithm ---------------------------------------------------------
# Tokens (space-separated) match in order as case-insensitive **subsequences**
# of the path. The first token can start anywhere; every subsequent token
# must start at a word boundary. Within a token, characters are matched as
# subsequences (so ``j/c`` matches ``src/mojovision/cell.mojo`` because
# j → '/' → c can be found in order). Word boundaries are: start of string,
# the position right after a non-alphanumeric byte, or a camelCase split
# (lowercase byte followed by an uppercase byte).


fn quick_open_match(path: String, query: String) -> Bool:
    """Return True iff ``query`` matches ``path`` under the QuickOpen rules.

    Examples (with ``path = src/mojovision/cell.mojo``):

    * ``"j/c"``    → matches (one token, j then '/' then c, in order).
    * ``"j c"``    → matches (j anywhere, then c at a word boundary).

    With ``path = "jobCall"``:
    * ``"j c"``    → matches (j at start, c at the camelCase boundary).

    With ``path = "jack"``:
    * ``"j c"``    → does **not** match (no word boundary precedes the c).
    """
    var tokens = _split_tokens(query)
    if len(tokens) == 0:
        return True
    var pos = 0
    for ti in range(len(tokens)):
        var anywhere = (ti == 0)
        var ne = _find_token_match(path, pos, tokens[ti], anywhere)
        if ne < 0:
            return False
        pos = ne
    return True


fn _split_tokens(q: String) -> List[String]:
    var out = List[String]()
    var b = q.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x20:
            if i > start:
                out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    if start < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[start:])))
    return out^


fn _find_token_match(
    path: String, start_pos: Int, token: String, anywhere: Bool,
) -> Int:
    """Earliest end-index of a subsequence match for ``token`` starting at
    or after ``start_pos``. ``-1`` if the token can't be matched. When
    ``anywhere`` is False, the start position is constrained to a word
    boundary in ``path``.
    """
    var pb = path.as_bytes()
    var tb = token.as_bytes()
    if len(tb) == 0:
        return start_pos
    var sp = start_pos
    while sp < len(pb):
        if (anywhere or _is_word_boundary(path, sp)) \
                and _ci_byte_eq(pb[sp], tb[0]):
            var ti = 1
            var pi = sp + 1
            while ti < len(tb) and pi < len(pb):
                if _ci_byte_eq(pb[pi], tb[ti]):
                    ti += 1
                pi += 1
            if ti == len(tb):
                return pi
        sp += 1
    return -1


fn _ci_byte_eq(a: UInt8, b: UInt8) -> Bool:
    var ai = Int(a)
    var bi = Int(b)
    if 0x41 <= ai and ai <= 0x5A: ai = ai + 0x20
    if 0x41 <= bi and bi <= 0x5A: bi = bi + 0x20
    return ai == bi


fn _is_alnum(c: Int) -> Bool:
    if 0x30 <= c and c <= 0x39: return True
    if 0x41 <= c and c <= 0x5A: return True
    if 0x61 <= c and c <= 0x7A: return True
    return False


fn _is_word_boundary(path: String, p: Int) -> Bool:
    var pb = path.as_bytes()
    if p == 0:
        return True
    if p > len(pb) or p < 0:
        return False
    var prev = Int(pb[p - 1])
    if not _is_alnum(prev):
        return True
    if p < len(pb):
        var cur = Int(pb[p])
        # camelCase split: lowercase → uppercase.
        if 0x61 <= prev and prev <= 0x7A and 0x41 <= cur and cur <= 0x5A:
            return True
    return False
