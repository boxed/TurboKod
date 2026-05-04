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
    KEY_BACKSPACE, KEY_ENTER, KEY_ESC,
    MOD_ALT, MOD_CTRL,
    MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .picker_input import picker_nav_key, picker_wheel_scroll
from .project import walk_project_files
from .text_field import text_field_clipboard_key
from .window import paint_drop_shadow


struct QuickOpen(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    var query: String
    var selected_path: String
    # Display labels (project-relative when possible). Each entry has a
    # parallel absolute path in ``entries_abs`` used as the submit target.
    var entries: List[String]
    var entries_abs: List[String]
    # Indices into ``entries`` that match the current query.
    var matched: List[Int]
    var selected: Int
    var scroll: Int
    # Dialog title — "Quick Open" by default, "Open Recent" for the
    # recents-mode entry point.
    var title: String
    # True when the picker is showing project roots rather than files.
    # Desktop reads this on submit to decide between ``open_project``
    # and ``open_file``. Reset on every ``open*`` / ``close``.
    var picks_project: Bool

    fn __init__(out self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = String("")
        self.selected_path = String("")
        self.entries = List[String]()
        self.entries_abs = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.title = String(" Quick Open ")
        self.picks_project = False

    fn open(mut self, var root: String):
        self.root = root^
        self.query = String("")
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.selected = 0
        self.scroll = 0
        self.title = String(" Quick Open ")
        self.picks_project = False
        # Load candidate set from disk. Paths come back absolute; strip the
        # root prefix so the picker shows the project-relative form.
        self.entries = List[String]()
        self.entries_abs = List[String]()
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
                    self.entries_abs.append(paths[i])
                    continue
            self.entries.append(paths[i])
            self.entries_abs.append(paths[i])
        self._refilter()

    fn open_recent(
        mut self, var root: String, var entries: List[String],
        var entries_abs: List[String], picks_project: Bool = False,
    ):
        """Open with a caller-supplied list of paths (display + absolute).

        Order is preserved verbatim — used for the "Open Recent" entry
        point so the most-recently-focused file is at the top. Entries
        are not re-sorted by the matcher; the empty-query view shows
        them in the order passed.

        ``picks_project`` flips the dialog into project-root mode: title
        changes to "Open Recent Project" and Desktop routes the submitted
        path through ``open_project`` instead of ``open_file``.
        """
        self.root = root^
        self.query = String("")
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.selected = 0
        self.scroll = 0
        self.title = String(
            " Open Recent Project " if picks_project else " Open Recent "
        )
        self.entries = entries^
        self.entries_abs = entries_abs^
        self.picks_project = picks_project
        self._refilter()

    fn close(mut self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = String("")
        self.selected_path = String("")
        self.entries = List[String]()
        self.entries_abs = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.scroll = 0
        self.title = String(" Quick Open ")
        self.picks_project = False

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

    fn is_input_at(self, pos: Point, screen: Rect) -> Bool:
        """True iff ``pos`` lies on the ``Find:`` query row."""
        if not self.active:
            return False
        var rect = self._rect(screen)
        return Rect(rect.a.x + 2, rect.a.y + 1, rect.b.x - 1, rect.a.y + 2).contains(pos)

    # --- paint ------------------------------------------------------------

    fn paint(self, mut canvas: Canvas, screen: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var title_attr  = Attr(WHITE,  BLUE)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var rect = self._rect(screen)
        paint_drop_shadow(canvas, rect)
        canvas.fill(rect, String(" "), bg)
        canvas.draw_box(rect, bg, False)
        var tx = rect.a.x + (rect.width() - len(self.title.as_bytes())) // 2
        _ = canvas.put_text(Point(tx, rect.a.y), self.title, title_attr)
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
            self.selected_path = self.entries_abs[self.matched[self.selected]]
            self.submitted = True
            return True
        if picker_nav_key(k, len(self.matched), self.selected):
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
        # Cut / copy / paste before the MOD_CTRL early-out below — those
        # arrive as raw control codepoints with MOD_NONE, but the guard
        # would otherwise catch the Ctrl+letter form on terminals that
        # report it as MOD_CTRL.
        var clip = text_field_clipboard_key(event, self.query)
        if clip.consumed:
            if clip.changed:
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
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.matched),
                self._list_height(rect),
            ):
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
            self.selected_path = self.entries_abs[self.matched[idx]]
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
# The query is split on spaces into tokens; each token is then split around
# every ``/``, with each ``/`` kept as its own one-byte part. Every part
# must appear as a case-insensitive **substring** of the path, in order.
# So ``foo bar`` requires the substrings ``foo`` then ``bar``; ``foo/bar``
# additionally requires a literal ``/`` between them — i.e. the parts
# ``foo``, ``/``, ``bar`` matched as substrings in that order.


fn quick_open_match(path: String, query: String) -> Bool:
    """Return True iff ``query`` matches ``path`` under the QuickOpen rules.

    Examples (with ``path = "src/turbokod/cell.mojo"``):

    * ``"k/c"`` → matches (``k`` in ``turbokod``, then ``/``, then ``c``
      in ``cell``).
    * ``"k c"`` → matches (``k`` then ``c`` as substrings, in order).
    * ``"km/"`` → does **not** match (``km`` is not a substring).

    With ``path = "dryft/homepage/cms/migrations/0003_snippet_preview_values.py"``
    and query ``"pro/views"``: does **not** match. The literal text
    ``pro`` is absent (``preview`` has ``pre``, not ``pro``), so the
    first part already fails.
    """
    var parts = _split_query_to_parts(query)
    if len(parts) == 0:
        return True
    var pos = 0
    for pi in range(len(parts)):
        var found = _find_substring_ci(path, parts[pi], pos)
        if found < 0:
            return False
        pos = found + len(parts[pi].as_bytes())
    return True


fn _split_query_to_parts(q: String) -> List[String]:
    """Split ``q`` on spaces, then split each token around every ``/``,
    keeping ``/`` as its own one-byte part. Empty parts are dropped.
    """
    var out = List[String]()
    var b = q.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        if b[i] == 0x20:
            i += 1
            continue
        # Walk one space-delimited token, emitting parts split on '/'.
        var run_start = i
        while i < n and b[i] != 0x20:
            if b[i] == 0x2F:
                if i > run_start:
                    out.append(String(StringSlice(
                        unsafe_from_utf8=b[run_start:i],
                    )))
                out.append(String("/"))
                i += 1
                run_start = i
            else:
                i += 1
        if i > run_start:
            out.append(String(StringSlice(
                unsafe_from_utf8=b[run_start:i],
            )))
    return out^


fn _find_substring_ci(path: String, needle: String, start: Int) -> Int:
    """Earliest index ``>= start`` where ``needle`` occurs as a
    case-insensitive substring of ``path``, or ``-1`` if absent.
    """
    var pb = path.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0:
        return start
    var i = start
    while i + len(nb) <= len(pb):
        var ok = True
        for j in range(len(nb)):
            if not _ci_byte_eq(pb[i + j], nb[j]):
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


fn _ci_byte_eq(a: UInt8, b: UInt8) -> Bool:
    var ai = Int(a)
    var bi = Int(b)
    if 0x41 <= ai and ai <= 0x5A: ai = ai + 0x20
    if 0x41 <= bi and bi <= 0x5A: bi = bi + 0x20
    return ai == bi
