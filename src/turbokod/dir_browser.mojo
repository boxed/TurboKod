"""Shared directory-listing widget used by the open-file and save-as
dialogs.

Owns the navigation state (current directory, entries, selection, scroll)
plus the bits that don't depend on the surrounding chrome: refreshing the
listing, ascending/descending, painting the rows into a caller-supplied
rect, and translating a list-area click to a row index. The host dialog
adds its own border, title, key routing, and submit semantics on top of
this — that's where the two dialogs differ.

Set ``dirs_only=True`` to filter the listing to directories — used by
``SaveAsDialog`` so the user can pick a destination folder without files
cluttering the picker. ``..`` is always included regardless of the flag.
"""

from std.collections.list import List

from .buttons import ShadowButton, paint_shadow_button
from .canvas import Canvas
from .cell import Cell
from .colors import (
    Attr, BLACK, BLUE, CYAN, GREEN, LIGHT_CYAN, LIGHT_GRAY, WHITE, YELLOW,
)
from .events import (
    Event, EVENT_MOUSE,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import (
    join_path, list_directory, parent_path, sort_directory_listing,
    stat_file,
)
from .geometry import Point, Rect
from .painter import Painter
from .posix import getenv_value, monotonic_ms, realpath


@fieldwise_init
struct JumpShortcut(ImplicitlyCopyable, Movable):
    """One entry in the Desktop / Home / Root row at the bottom of
    the file dialogs. ``label`` is what the user sees, ``path`` is
    where a click takes them, ``x`` is the column the label starts
    at — pre-computed so paint and click-mapping share one source
    of truth for the button layout.
    """
    var label: String
    var path: String
    var x: Int


fn jump_shortcuts(start_x: Int) -> List[JumpShortcut]:
    """Build the Desktop / Home / Root button row, laid out left-
    to-right from ``start_x`` with a single-column gap between
    buttons. ``$HOME`` is consulted at call time so a session that
    inherits a different value picks it up.

    When ``$HOME`` is unset the user-relative buttons collapse to
    ``"."`` rather than to bare paths like ``/Desktop`` — clicking a
    button on a misconfigured shell shouldn't silently teleport the
    listing to a wrong absolute path.
    """
    var home = getenv_value(String("HOME"))
    var has_home = len(home.as_bytes()) > 0
    var fallback = String(".")
    var out = List[JumpShortcut]()
    var labels = List[String]()
    var paths = List[String]()
    # Labels are padded with one space on each side so the green
    # button face has visible breathing room around the letters —
    # matches the Turbo C/C++ "OK" / "Cancel" / "Help" buttons,
    # which are also rendered as " Label " on a green background.
    labels.append(String(" Desktop "))
    if has_home:
        paths.append(home + String("/Desktop"))
    else:
        paths.append(fallback)
    labels.append(String(" Home "))
    paths.append(home if has_home else fallback)
    labels.append(String(" / "))
    paths.append(String("/"))
    var x = start_x
    for i in range(len(labels)):
        out.append(JumpShortcut(labels[i], paths[i], x))
        # Each button claims its label width plus one column for
        # the right-edge shadow, plus one column of separation
        # before the next button.
        x += len(labels[i].as_bytes()) + 2
    return out^


comptime _SEARCH_RESET_MS: Int = 800
"""How long after the last keystroke a fresh char restarts the type-
to-search buffer instead of extending it. 800ms matches Windows
Explorer / GNOME Files / Finder closely enough that muscle memory
from those carries over."""


struct DirBrowser(Movable):
    var dir: String
    var entries: List[String]
    var entry_is_dir: List[Bool]
    var selected: Int
    var scroll: Int
    var dirs_only: Bool
    var _search_buf: String
    """Accumulated type-to-search keystrokes. Reset on every
    ``refresh`` (so navigating to a new dir starts fresh) and on
    timeout (when the user pauses long enough that a fresh letter
    is clearly a new search, not a continuation)."""
    var _search_last_ms: Int

    fn __init__(out self, dirs_only: Bool = False):
        self.dir = String(".")
        self.entries = List[String]()
        self.entry_is_dir = List[Bool]()
        self.selected = 0
        self.scroll = 0
        self.dirs_only = dirs_only
        self._search_buf = String("")
        self._search_last_ms = 0

    fn open(mut self, var start_dir: String):
        self.dir = start_dir^
        self.selected = 0
        self.scroll = 0
        self.refresh()

    fn refresh(mut self):
        """Rebuild ``entries``/``entry_is_dir`` for the current ``dir``.

        ``..`` is prepended unconditionally so an empty / unreadable
        directory still gives the user a way out. When ``dirs_only`` is
        set, plain files are filtered before sorting so the listing
        height is purely directories + the parent shortcut.
        """
        var names = List[String]()
        var is_dirs = List[Bool]()
        var raw = list_directory(self.dir)
        for i in range(len(raw)):
            var name = raw[i]
            if name == String(".") or name == String(".."):
                continue
            var info = stat_file(join_path(self.dir, name))
            var is_dir = info.is_dir() if info.ok else False
            if self.dirs_only and not is_dir:
                continue
            names.append(name)
            is_dirs.append(is_dir)
        sort_directory_listing(names, is_dirs)
        self.entries = List[String]()
        self.entry_is_dir = List[Bool]()
        self.entries.append(String(".."))
        self.entry_is_dir.append(True)
        for i in range(len(names)):
            self.entries.append(names[i])
            self.entry_is_dir.append(is_dirs[i])
        # Reset to the top whenever the listing changes — the user just
        # navigated, so an unrelated entry-5 in the new dir would be a
        # confusing landing spot. Matches the pre-refactor FileDialog.
        self.selected = 0
        self.scroll = 0
        # A new directory is a fresh context; old search prefix would
        # match against entries that no longer exist.
        self._search_buf = String("")
        self._search_last_ms = 0

    fn ascend(mut self):
        """Move ``self.dir`` to its parent. Canonicalizes via
        ``realpath`` first so a relative start dir like ``"."`` —
        whose parent under POSIX dirname semantics is itself — still
        ascends. Falls back to plain ``parent_path`` if ``realpath``
        can't resolve (e.g. the dir was deleted from under us)."""
        var resolved = realpath(self.dir)
        if len(resolved.as_bytes()) > 0:
            self.dir = parent_path(resolved)
        else:
            self.dir = parent_path(self.dir)
        self.refresh()

    fn descend(mut self, name: String):
        self.dir = join_path(self.dir, name)
        self.refresh()

    fn jump_to(mut self, var path: String):
        """Replace ``self.dir`` with ``path`` and rebuild the listing.
        Used by the Desktop / Home / Root shortcut buttons — same
        end-effect as a sequence of ``descend`` / ``ascend`` calls,
        but skips the intermediate listings."""
        self.dir = path^
        self.refresh()

    fn paint_jump_buttons(self, mut canvas: Canvas, row: Rect):
        """Paint the Desktop / Home / Root buttons across ``row``.

        Delegates the visual to ``paint_shadow_button`` so every
        Turbo Vision–style button in the codebase shares one
        rendering path. The layout (which buttons, their order, and
        their column positions) is owned here via
        ``jump_shortcuts(row.a.x)``.
        """
        var face = Attr(BLACK, GREEN)
        var buttons = jump_shortcuts(row.a.x)
        for i in range(len(buttons)):
            if buttons[i].x >= row.b.x:
                break
            paint_shadow_button(
                canvas,
                ShadowButton(buttons[i].label, buttons[i].x, row.a.y),
                face, LIGHT_GRAY, row.b.x,
            )

    fn handle_jump_click(mut self, event: Event, row: Rect) -> Bool:
        """Map a left-click landing on a jump button (face *or*
        shadow row, since users frequently miss-click downward) to a
        ``jump_to`` call. Returns True iff a button was hit; the
        host should treat that as a fully-consumed event."""
        if event.kind != EVENT_MOUSE:
            return False
        if event.button != MOUSE_BUTTON_LEFT:
            return False
        if not event.pressed or event.motion:
            return False
        if event.pos.y < row.a.y or event.pos.y > row.a.y + 1:
            return False
        if event.pos.x < row.a.x or event.pos.x >= row.b.x:
            return False
        var buttons = jump_shortcuts(row.a.x)
        for i in range(len(buttons)):
            var label_w = len(buttons[i].label.as_bytes())
            if buttons[i].x <= event.pos.x \
                    and event.pos.x < buttons[i].x + label_w + 1:
                self.jump_to(buttons[i].path)
                return True
        return False

    fn current_name(self) -> String:
        if self.selected < 0 or self.selected >= len(self.entries):
            return String("")
        return self.entries[self.selected]

    fn current_is_dir(self) -> Bool:
        if self.selected < 0 or self.selected >= len(self.entries):
            return False
        return self.entry_is_dir[self.selected]

    fn current_path(self) -> String:
        """Joined path of the highlighted entry, or ``self.dir`` when
        nothing is selected. Returns the parent dir for ``..``, not the
        literal ``"<dir>/.."`` — that's never what callers want."""
        var name = self.current_name()
        if len(name.as_bytes()) == 0:
            return self.dir
        if name == String(".."):
            var resolved = realpath(self.dir)
            if len(resolved.as_bytes()) > 0:
                return parent_path(resolved)
            return parent_path(self.dir)
        return join_path(self.dir, name)

    fn move_by(mut self, delta: Int, list_h: Int):
        """Bump the selection by ``delta`` rows and re-clip ``scroll`` so
        the new selection stays visible. ``list_h`` is the visible row
        count of the listing area (passed in because only the host knows
        the dialog geometry)."""
        var n = len(self.entries)
        if n == 0:
            return
        var s = self.selected + delta
        if s < 0:
            s = 0
        if s >= n:
            s = n - 1
        self.selected = s
        self._scroll_to_selection(list_h)

    fn set_selection(mut self, idx: Int, list_h: Int):
        var n = len(self.entries)
        if n == 0:
            return
        var s = idx
        if s < 0:
            s = 0
        if s >= n:
            s = n - 1
        self.selected = s
        self._scroll_to_selection(list_h)

    fn type_to_search(mut self, ch: String, list_h: Int) -> Bool:
        """Extend the type-to-search buffer with ``ch`` and jump the
        selection to the first entry whose name starts with the
        accumulated buffer (case-insensitive). Returns True if a
        match was found.

        ``..`` is excluded from matching — the parent shortcut isn't
        a real entry the user would search for, and a leading dot
        would otherwise match every keystroke that begins a search.

        On no match, the buffer is *reset* to just ``ch`` and a
        single-char match is retried — that way typing a fresh
        letter after a stale prefix lands somewhere useful instead
        of feeling like a dead key.
        """
        var now = monotonic_ms()
        if now - self._search_last_ms > _SEARCH_RESET_MS:
            self._search_buf = String("")
        self._search_last_ms = now
        self._search_buf = self._search_buf + ch
        # Copy the buffer before passing to ``_find_and_select``: Mojo
        # rejects passing ``self._search_buf`` as a borrow argument
        # while ``self`` is also borrowed mutably (the helper sets the
        # selection on success).
        var prefix = self._search_buf
        if self._find_and_select(prefix^, list_h):
            return True
        # Stale-prefix recovery: try the new char alone.
        if len(self._search_buf.as_bytes()) > 1:
            self._search_buf = ch
            var solo = self._search_buf
            if self._find_and_select(solo^, list_h):
                return True
        return False

    fn _find_and_select(mut self, var prefix: String, list_h: Int) -> Bool:
        """Locate the first entry (other than ``..``) whose name
        starts with ``prefix`` (case-insensitive). Returns True and
        updates the selection if one is found."""
        var pb = prefix.as_bytes()
        if len(pb) == 0:
            return False
        for i in range(len(self.entries)):
            if self.entries[i] == String(".."):
                continue
            if _starts_with_ci(self.entries[i], prefix):
                self.set_selection(i, list_h)
                return True
        return False

    fn _scroll_to_selection(mut self, list_h: Int):
        if list_h < 1:
            return
        if self.selected < self.scroll:
            self.scroll = self.selected
        elif self.selected >= self.scroll + list_h:
            self.scroll = self.selected - list_h + 1

    # --- painting ---------------------------------------------------------

    fn paint(self, mut canvas: Canvas, list_rect: Rect, focused: Bool = True):
        """Paint the entry list inside ``list_rect``. The host paints the
        dialog frame, title, and the "current directory" line above; this
        method only touches the rectangle it was given.

        ``focused=False`` dims the selection highlight so the listing
        looks inactive when keyboard focus is elsewhere (e.g. the
        filename input in Save-As). Directories get a distinct colour
        in either mode.

        Drawing flows through a ``Painter`` clipped to ``list_rect`` so a
        long entry name can't bleed past the right edge — every write is
        intersected with the clip, regardless of the source string's
        length. Row background is filled before the label so the
        selection bar spans the full row width even when the name is
        short.
        """
        # Turbo Vision file-dialog palette: cyan listing, white file
        # names, yellow directory names. Selection inverts to a high-
        # contrast bar — black on light-cyan when keyboard focus is
        # here, light-gray on blue when it isn't, so an unfocused
        # listing reads as inactive without disappearing.
        var bg = Attr(WHITE, CYAN)
        var dir_entry_attr = Attr(YELLOW, CYAN)
        var sel_attr = (
            Attr(BLACK, LIGHT_CYAN) if focused
            else Attr(LIGHT_GRAY, BLUE)
        )
        var list_h = list_rect.height()
        var painter = Painter(list_rect)
        for i in range(list_h):
            var idx = self.scroll + i
            if idx >= len(self.entries):
                break
            var name = self.entries[idx]
            var is_dir = self.entry_is_dir[idx]
            var attr: Attr
            if idx == self.selected:
                attr = sel_attr
            else:
                attr = dir_entry_attr if is_dir else bg
            var row_y = list_rect.a.y + i
            painter.fill(
                canvas,
                Rect(list_rect.a.x, row_y, list_rect.b.x, row_y + 1),
                String(" "), attr,
            )
            var label = name + String("/") if is_dir else name
            _ = painter.put_text(
                canvas, Point(list_rect.a.x, row_y), label, attr,
            )

    # --- mouse ------------------------------------------------------------

    fn handle_list_mouse(
        mut self, event: Event, list_rect: Rect,
    ) -> Int:
        """Process a mouse event scoped to the listing area. Returns:

        ``-1``  — event ignored / outside list
        ``-2``  — wheel scroll consumed (no row activated)
        ``>=0`` — row index that was clicked. Caller decides whether to
                  treat that as "select only" (first click) or "activate"
                  (click-on-already-selected, i.e. open / descend).

        ``..`` is treated specially: any click on it activates immediately
        rather than requiring a second click — matching the "click the
        parent shortcut once" behavior most users expect."""
        if event.kind != EVENT_MOUSE:
            return -1
        if event.pressed and not event.motion:
            if event.button == MOUSE_WHEEL_UP:
                if self.scroll > 0:
                    self.scroll -= 3
                    if self.scroll < 0:
                        self.scroll = 0
                return -2
            if event.button == MOUSE_WHEEL_DOWN:
                var max_scroll = len(self.entries) - list_rect.height()
                if max_scroll < 0:
                    max_scroll = 0
                if self.scroll < max_scroll:
                    self.scroll += 3
                    if self.scroll > max_scroll:
                        self.scroll = max_scroll
                return -2
        if event.button != MOUSE_BUTTON_LEFT:
            return -1
        if not event.pressed or event.motion:
            return -1
        if not list_rect.contains(event.pos):
            return -1
        var row = event.pos.y - list_rect.a.y
        if row < 0 or row >= list_rect.height():
            return -1
        var idx = self.scroll + row
        if idx < 0 or idx >= len(self.entries):
            return -1
        return idx


fn _starts_with_ci(name: String, prefix: String) -> Bool:
    """ASCII-case-insensitive prefix test. Restricted to ASCII —
    UTF-8 case folding is non-trivial, and filenames in this
    codebase are matched the same way ``_sort_entries_ci`` (in
    ``file_io``) compares them, so the two views agree."""
    var nb = name.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(nb):
        return False
    for i in range(len(pb)):
        var cn = Int(nb[i])
        var cp = Int(pb[i])
        if 0x41 <= cn and cn <= 0x5A:
            cn += 0x20
        if 0x41 <= cp and cp <= 0x5A:
            cp += 0x20
        if cn != cp:
            return False
    return True
