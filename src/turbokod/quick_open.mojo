"""QuickOpen: type-to-filter file picker for the active project.

A modal centered dialog. The user types a substring of the path; the list
below the input filters as they type. Arrow keys / PgUp / PgDn navigate;
Enter submits the selected entry; Esc cancels. ``submitted`` /
``selected_path`` mirror ``FileDialog`` so the desktop owner can either
inspect them or rely on ``Desktop`` to dispatch into ``open_file``.

The candidate set keeps ignored *directories* (``node_modules``,
``venv``, ``__pycache__``, vendored trees like ``tvision/``) pruned so
the list stays usable, but individual gitignored files like
``settings_local.py`` or ``.env`` are kept so the user can open them.
On the async git path that's two parallel ``FileIndexer``s — the main
``ls-files -co`` enumeration plus an ignored-only one whose
``--directory`` flag collapses ignored dirs to a skipped single entry;
the non-git fallback gets the same split from ``walk_project_files(root,
include_ignored_files=True)``.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .canvas import Canvas, paint_drop_shadow
from .painter import Painter
from .cell import Cell
from .colors import Attr, BLACK, BLUE, LIGHT_GRAY, YELLOW
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_ENTER, KEY_ESC,
    MOD_SHIFT, MOUSE_BUTTON_LEFT,
)
from .geometry import Point, Rect
from .picker_input import picker_nav_key, picker_wheel_scroll
from .project import FileIndexer, QUICK_OPEN_FILE_CAP, walk_project_files
from .text_field import TextField
from .view import RowCursor
from .window import close_button_clicked, paint_close_button, paint_window_title


comptime _LABEL = String(" Find: ")
comptime _LABEL_W = 7
"""Columns occupied by the inline search label (``" Find: "``)."""


@fieldwise_init
struct _Layout(ImplicitlyCopyable, Movable):
    """Pre-computed rects for the picker. Shared by ``paint`` and
    ``handle_mouse``."""
    var input_rect: Rect
    var input_label_pt: Point
    var list_top: Int
    var list_height: Int
    var hint_y: Int


def _build_layout(rect: Rect) -> _Layout:
    var cursor = RowCursor(rect.a.y + 1)
    var input_y = cursor.place()
    var list_y = cursor.place()
    var hint_y = rect.b.y - 1
    var list_h = hint_y - list_y
    if list_h < 0:
        list_h = 0
    return _Layout(
        Rect(rect.a.x + 2 + _LABEL_W, input_y, rect.b.x - 1, input_y + 1),
        Point(rect.a.x + 2, input_y),
        list_y, list_h, hint_y,
    )


struct QuickOpen(Movable):
    var active: Bool
    var submitted: Bool
    var root: String
    var query: TextField
    # The "primary" submitted path — the one the cursor was on at submit
    # time. ``selected_paths`` (below) is the full set including the
    # multi-select range; this single field is what Desktop uses to
    # decide which window to focus after opening.
    var selected_path: String
    # Full set of paths to open on submit. Single-row selection ⇒ one
    # entry; multi-row (shift+arrow) ⇒ the whole range in row order
    # (low → high). Desktop iterates this and opens each.
    var selected_paths: List[String]
    # Display labels (project-relative when possible). Each entry has a
    # parallel absolute path in ``entries_abs`` used as the submit target.
    var entries: List[String]
    var entries_abs: List[String]
    # Indices into ``entries`` that match the current query.
    var matched: List[Int]
    var selected: Int
    # Multi-select anchor (index into ``matched``). When ``anchor ==
    # selected`` the picker has a single-row selection; shift+arrow keys
    # move ``selected`` while leaving ``anchor`` pinned, painting the
    # whole range highlighted and submitting all of it on Enter.
    var anchor: Int
    var scroll: Int
    # Dialog title — "Quick Open" by default, "Open Recent" for the
    # recents-mode entry point.
    var title: String
    # True when the picker is showing project roots rather than files.
    # Desktop reads this on submit to decide between ``open_project``
    # and ``open_file``. Reset on every ``open*`` / ``close``.
    var picks_project: Bool
    # Cached query strip rect (captured on the most recent ``paint``)
    # so ``handle_mouse`` can route clicks back to the field without
    # re-running layout. Negative width = "no paint yet".
    var _input_rect: Rect
    # Async file indexers. Owned for the duration of ``open()`` → first
    # ``tick()`` that observes ``indexer.alive==False``. ``_indexer`` is
    # the main ``ls-files -co`` enumeration; ``_ignored_indexer`` runs
    # the ignored-only pass in parallel so individually-gitignored files
    # (``.env``, ``settings_local.py``) make the list too. ``indexing``
    # tracks whether either is still running so ``paint`` can show
    # an "<indexing… N>" status; ``truncated`` records whether the cap
    # at ``QUICK_OPEN_FILE_CAP`` was hit.
    var _indexer: Optional[FileIndexer]
    var _ignored_indexer: Optional[FileIndexer]
    var indexing: Bool
    var truncated: Bool
    # Query text remembered across close/reopen, scoped to the project-
    # files ``open()`` path. ``close()`` captures the current query before
    # tearing the field down, and ``open()`` restores it (select-all'd
    # so the user's first keystroke replaces it). The "Open Recent"
    # variants do not restore — they always start empty since they
    # filter a different list.
    var _saved_query: String
    # Saved selection + scroll, also scoped to ``open()``. Stored as
    # raw indices (not paths) so the restore survives a partially-loaded
    # async indexer: ``_refilter`` clamps these into the current
    # ``matched`` length on every pass while ``_pending_restore`` is
    # True, so as the indexer fills entries the cursor settles back to
    # the saved row. Both reset to 0 the first time ``open()`` sees a
    # new project root.
    var _saved_selected: Int
    var _saved_scroll: Int
    # Project root associated with the saved query/selection/scroll. A
    # different root on the next ``open()`` clears the saved state —
    # carrying row 47 from project A into project B's file list would
    # land the cursor on an unrelated file.
    var _saved_root: String
    # While True, ``_refilter`` clamps ``selected`` / ``scroll`` to the
    # saved values instead of resetting them to 0. Set in ``open()``,
    # cleared the moment the user navigates, scrolls, or types — all
    # signals they're past the initial restore.
    var _pending_restore: Bool
    # True while we're inside the project-files ``open()`` lifecycle.
    # ``close()`` writes back to ``_saved_*`` only when this is set, so
    # an "Open Recent" close doesn't pollute the main picker's saved
    # state (open_recent always starts fresh).
    var _in_main_open: Bool

    def __init__(out self):
        self.active = False
        self.submitted = False
        self.root = String("")
        self.query = TextField()
        self.selected_path = String("")
        self.selected_paths = List[String]()
        self.entries = List[String]()
        self.entries_abs = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.anchor = 0
        self.scroll = 0
        self.title = String(" Quick Open ")
        self.picks_project = False
        self._input_rect = Rect(0, 0, 0, 0)
        self._indexer = Optional[FileIndexer]()
        self._ignored_indexer = Optional[FileIndexer]()
        self.indexing = False
        self.truncated = False
        self._saved_query = String("")
        self._saved_selected = 0
        self._saved_scroll = 0
        self._saved_root = String("")
        self._pending_restore = False
        self._in_main_open = False

    def open(mut self, var root: String, var prefill: String = String("")):
        # A different project root invalidates everything we'd saved —
        # the file list won't share indices, and the saved query was
        # likely about the previous tree. Reset before the move so
        # ``self.root`` reflects the new value when we compare next time.
        if self._saved_root != root:
            self._saved_query = String("")
            self._saved_selected = 0
            self._saved_scroll = 0
        self._saved_root = root
        self.root = root^
        self._in_main_open = True
        self.query = TextField()
        # A non-empty ``prefill`` (the editor's current selection) takes
        # priority over the remembered query: opening Quick Open with text
        # selected starts pre-searched for it. Otherwise restore the last
        # query the user typed in this picker. Either way ``set_text``
        # places the cursor at the end and ``select_all`` highlights the
        # whole field so the next printable keystroke replaces it (same
        # pattern VS Code / Sublime use when reopening their quick-open).
        var has_prefill = len(prefill.as_bytes()) > 0
        if has_prefill:
            self.query.set_text(prefill^)
            self.query.select_all()
        elif len(self._saved_query.as_bytes()) > 0:
            self.query.set_text(self._saved_query)
            self.query.select_all()
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.selected_paths = List[String]()
        self.selected = 0
        self.anchor = 0
        self.scroll = 0
        # ``_refilter`` will clamp ``_saved_selected`` / ``_saved_scroll``
        # into ``selected`` / ``scroll`` while this flag is True. The
        # first user navigation / scroll / keystroke flips it off. With a
        # prefill the saved row/scroll are meaningless against the new
        # filter, so skip the restore and let ``_refilter`` start at the
        # top of the prefiltered results.
        self._pending_restore = not has_prefill
        self.title = String(" Quick Open ")
        self.picks_project = False
        self.entries = List[String]()
        self.entries_abs = List[String]()
        self.truncated = False
        # Async path: ``git ls-files`` runs in a child process and its
        # output is drained from ``tick()`` each frame. The dialog opens
        # *immediately* showing an empty list + an "<indexing…>" status;
        # entries fill in as git produces them. Hits ``QUICK_OPEN_FILE_CAP``
        # → child gets SIGTERM, ``truncated`` flips on, list freezes at
        # the cap so the user can still pick from what loaded.
        var idx = FileIndexer.start(self.root)
        if idx:
            self._indexer = idx^
            # Parallel ignored-only pass: individually-gitignored files
            # (``.env``, ``settings_local.py``) are openable too. Ignored
            # *directories* arrive as single ``dir/`` entries the indexer
            # drops, so ``node_modules`` content never floods the list.
            self._ignored_indexer = FileIndexer.start(
                self.root, ignored_only=True,
            )
            self.indexing = True
        else:
            # Non-git project (or git unavailable): fall back to the
            # synchronous walk. Bounded by ``QUICK_OPEN_FILE_CAP`` so a
            # malformed huge non-git tree still doesn't hang us forever.
            self._indexer = Optional[FileIndexer]()
            self._ignored_indexer = Optional[FileIndexer]()
            self.indexing = False
            var paths = walk_project_files(self.root, include_ignored_files=True)
            for i in range(len(paths)):
                if len(self.entries) >= QUICK_OPEN_FILE_CAP:
                    self.truncated = True
                    break
                self._append_path(paths[i])
        self._refilter()

    def _append_path(mut self, full: String):
        """Append one absolute path to the entry list, also computing
        the project-relative display form. Centralized so both the sync
        and async paths produce identical entries."""
        var rb = self.root.as_bytes()
        var fb = full.as_bytes()
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
                self.entries_abs.append(full)
                return
        self.entries.append(full)
        self.entries_abs.append(full)

    def tick(mut self):
        """Drain anything the async indexer has produced since the last
        frame. Cheap when the indexer is done or the picker isn't open;
        called every frame by ``Desktop.paint``.

        After appending new entries we re-run the filter so the visible
        list grows in step with the load. The re-filter is the dominant
        cost; on a project where we end up with 100 k entries it amounts
        to one extra substring-walk per frame, comparable to typing a
        character into the query field.
        """
        if not self.active:
            return
        var changed = False
        if self._indexer:
            var new_paths = self._indexer.value().poll(self.root)
            for i in range(len(new_paths)):
                if len(self.entries) >= QUICK_OPEN_FILE_CAP:
                    self.truncated = True
                    break
                self._append_path(new_paths[i])
            if len(new_paths) > 0:
                changed = True
            if not self._indexer.value().alive:
                # Indexer finished. Pick up its ``truncated`` flag and
                # drop the handle so future ticks skip it.
                if self._indexer.value().truncated:
                    self.truncated = True
                self._indexer = Optional[FileIndexer]()
                changed = True
        if self._ignored_indexer:
            var ign_paths = self._ignored_indexer.value().poll(self.root)
            for i in range(len(ign_paths)):
                if len(self.entries) >= QUICK_OPEN_FILE_CAP:
                    self.truncated = True
                    break
                self._append_path(ign_paths[i])
            if len(ign_paths) > 0:
                changed = True
            if not self._ignored_indexer.value().alive:
                if self._ignored_indexer.value().truncated:
                    self.truncated = True
                self._ignored_indexer = Optional[FileIndexer]()
                changed = True
        # "Indexing…" shows while either enumeration is still running.
        self.indexing = False
        if self._indexer:
            self.indexing = True
        if self._ignored_indexer:
            self.indexing = True
        if changed:
            self._refilter()

    def open_recent(
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
        self._in_main_open = False
        self._pending_restore = False
        self.query = TextField()
        self.active = True
        self.submitted = False
        self.selected_path = String("")
        self.selected_paths = List[String]()
        self.selected = 0
        self.anchor = 0
        self.scroll = 0
        self.title = String(
            " Open Recent Project " if picks_project else " Open Recent "
        )
        self.entries = entries^
        self.entries_abs = entries_abs^
        self.picks_project = picks_project
        self._refilter()

    def close(mut self):
        self.active = False
        self.submitted = False
        # Remember the query / selection / scroll for the next
        # ``open()`` so the user comes back to the same state (cancel-
        # by-ESC and submit-via-Enter both route through here). Only
        # the main project-files variant participates; ``open_recent``
        # cleared ``_in_main_open`` so its close doesn't pollute the
        # main picker's saved state. The multi-select range is NOT
        # saved — only the cursor position — since "I shift-selected
        # 5 files, opened them, and reopened the picker" should land
        # back on a single cursor, not on a 5-row highlight.
        if self._in_main_open:
            self._saved_query = self.query.text
            self._saved_selected = self.selected
            self._saved_scroll = self.scroll
            # ``_saved_root`` was already set in ``open()``; leave it.
        self._in_main_open = False
        self._pending_restore = False
        self.root = String("")
        self.query = TextField()
        self.selected_path = String("")
        self.selected_paths = List[String]()
        self.entries = List[String]()
        self.entries_abs = List[String]()
        self.matched = List[Int]()
        self.selected = 0
        self.anchor = 0
        self.scroll = 0
        self.title = String(" Quick Open ")
        self.picks_project = False
        # Tear down the indexers if still running — SIGTERM the
        # children so they don't keep enumerating after the user
        # dismissed the picker. ``_terminate`` is best-effort; the
        # shim's atexit reaper catches anything still alive when the
        # process exits.
        if self._indexer:
            self._indexer.value()._terminate()
            self._indexer = Optional[FileIndexer]()
        if self._ignored_indexer:
            self._ignored_indexer.value()._terminate()
            self._ignored_indexer = Optional[FileIndexer]()
        self.indexing = False
        self.truncated = False

    # --- filtering --------------------------------------------------------

    def _refilter(mut self):
        self.matched = List[Int]()
        if len(self.query.text.as_bytes()) == 0:
            for i in range(len(self.entries)):
                self.matched.append(i)
        else:
            for i in range(len(self.entries)):
                if quick_open_match(self.entries[i], self.query.text):
                    self.matched.append(i)
        if self._pending_restore and len(self.matched) > 0:
            # Initial restore from a prior ``close()``. We always read
            # from ``_saved_selected`` / ``_saved_scroll`` (untouched
            # across multiple ``tick`` ⇒ ``_refilter`` cycles during
            # async indexing) and clamp into the *current* matched
            # length, so as more entries stream in the cursor settles
            # onto the saved row.
            var s = self._saved_selected
            if s >= len(self.matched): s = len(self.matched) - 1
            if s < 0: s = 0
            self.selected = s
            self.anchor = s
            var sc = self._saved_scroll
            if sc < 0: sc = 0
            # Loose clamp — keep ``scroll`` from running past where
            # there's anything to show. Paint's slice handles the
            # tight bound against list-height.
            if sc >= len(self.matched): sc = len(self.matched) - 1
            if sc < 0: sc = 0
            self.scroll = sc
        else:
            self.selected = 0
            self.anchor = 0
            self.scroll = 0

    # --- geometry ---------------------------------------------------------

    def _rect(self, container_bounds: Rect) -> Rect:
        var width = 70
        var height = 20
        if width > container_bounds.b.x - 4: width = container_bounds.b.x - 4
        if height > container_bounds.b.y - 4: height = container_bounds.b.y - 4
        var x = (container_bounds.b.x - width) // 2
        var y = (container_bounds.b.y - height) // 2
        return Rect(x, y, x + width, y + height)

    def is_input_at(self, pos: Point, container_bounds: Rect) -> Bool:
        """True iff ``pos`` lies on the ``Find:`` query row."""
        if not self.active:
            return False
        var rect = self._rect(container_bounds)
        return _build_layout(rect).input_rect.contains(pos)

    # --- paint ------------------------------------------------------------

    def paint(mut self, mut canvas: Canvas, container_bounds: Rect):
        if not self.active:
            return
        var bg          = Attr(BLACK,  LIGHT_GRAY)
        var sel_attr    = Attr(BLACK,  YELLOW)
        var hint_attr   = Attr(BLUE,   LIGHT_GRAY)
        var rect = self._rect(container_bounds)
        var layout = _build_layout(rect)
        paint_drop_shadow(canvas, rect)
        var painter = Painter(rect)
        painter.fill(canvas, rect, String(" "), bg)
        painter.draw_box(canvas, rect, bg, False)
        # Dynamic title — base label + a parenthetical status while the
        # async indexer is still running, or a one-shot "truncated"
        # marker after we hit ``QUICK_OPEN_FILE_CAP`` so the user knows
        # the visible list isn't the whole project.
        var painted_title = self.title
        if self.indexing:
            painted_title = self.title + String("(indexing… ") \
                + String(len(self.entries)) + String(") ")
        elif self.truncated:
            painted_title = self.title + String("(truncated at ") \
                + String(QUICK_OPEN_FILE_CAP) + String(" files) ")
        paint_window_title(canvas, rect, painted_title, bg, bg)
        # Standard ``[■]`` close button at the top-LEFT — equivalent to
        # ESC / cancel. Same chrome the editor windows and other dialogs
        # use, painted via the shared ``paint_close_button`` helper.
        paint_close_button(canvas, Point(rect.a.x, rect.a.y), bg)
        # Search line: ``Find: <query>_``
        _ = painter.put_text(canvas, layout.input_label_pt, _LABEL, bg)
        self._input_rect = layout.input_rect
        self.query.paint(canvas, layout.input_rect, True)
        # Listing. The whole multi-select range gets the highlight
        # attribute — when ``anchor == selected`` that's just a single
        # row, when shift+arrow has extended the selection it's a span.
        var sel_lo = self.anchor if self.anchor < self.selected else self.selected
        var sel_hi = self.selected if self.anchor < self.selected else self.anchor
        var top = layout.list_top
        var h = layout.list_height
        for i in range(h):
            var idx = self.scroll + i
            if idx >= len(self.matched):
                break
            var entry = self.entries[self.matched[idx]]
            var attr = sel_attr if sel_lo <= idx and idx <= sel_hi else bg
            painter.fill(
                canvas, Rect(rect.a.x + 1, top + i, rect.b.x - 1, top + i + 1),
                String(" "), attr,
            )
            _ = painter.put_text(
                canvas, Point(rect.a.x + 2, top + i), entry, attr,
            )
        # Bottom hint.
        _ = painter.put_text(
            canvas, Point(rect.a.x + 2, layout.hint_y),
            String(" Enter: open  ESC: cancel "),
            hint_attr,
        )

    # --- events -----------------------------------------------------------

    def handle_key(mut self, event: Event) -> Bool:
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
            self._collect_selected_paths()
            self.submitted = True
            return True
        if picker_nav_key(k, len(self.matched), self.selected):
            # Any deliberate navigation ends the "restore" phase — the
            # next ``_refilter`` (e.g. an in-flight indexer tick) must
            # respect where the user just moved to, not snap back.
            self._pending_restore = False
            # Shift held ⇒ extend the multi-selection (anchor stays
            # pinned, ``selected`` is now the moving end). No shift ⇒
            # collapse to the new cursor position.
            if (event.mods & MOD_SHIFT) == 0:
                self.anchor = self.selected
            self._scroll_to_selection()
            return True
        var r = self.query.handle_key(event)
        if r.consumed:
            if r.changed:
                # Query changed ⇒ the saved row index is meaningless
                # against the new filter; let ``_refilter`` reset.
                self._pending_restore = False
                self._refilter()
            return True
        return True

    def _collect_selected_paths(mut self):
        """Populate ``selected_paths`` from the multi-select range
        ``[min(anchor, selected) … max(anchor, selected)]`` in row order,
        and set ``selected_path`` to the cursor row so Desktop knows
        which file to focus after opening. Always emits at least one
        path; ``selected_path`` is always a member of ``selected_paths``."""
        self.selected_paths = List[String]()
        var lo = self.anchor if self.anchor < self.selected else self.selected
        var hi = self.selected if self.anchor < self.selected else self.anchor
        if lo < 0: lo = 0
        if hi >= len(self.matched): hi = len(self.matched) - 1
        for i in range(lo, hi + 1):
            self.selected_paths.append(self.entries_abs[self.matched[i]])
        self.selected_path = self.entries_abs[self.matched[self.selected]]

    def handle_mouse(mut self, event: Event, container_bounds: Rect) -> Bool:
        if not self.active:
            return False
        if event.kind != EVENT_MOUSE:
            return True
        var rect = self._rect(container_bounds)
        var layout = _build_layout(rect)
        # Standard ``[■]`` close button — equivalent to ESC. Checked
        # before the input/list routing so a click on the chrome glyph
        # always dismisses the dialog.
        if close_button_clicked(rect, event):
            self.close()
            return True
        if self._input_rect.width() > 0 \
                and self.query.handle_mouse(event, self._input_rect):
            return True
        if event.pressed and not event.motion:
            if picker_wheel_scroll(
                event.button, self.scroll, len(self.matched),
                layout.list_height,
            ):
                # Wheel scroll counts as user interaction — end restore
                # mode so the next ``_refilter`` doesn't snap back.
                self._pending_restore = False
                return True
        if event.button != MOUSE_BUTTON_LEFT:
            return True
        if not event.pressed or event.motion:
            return True
        if not rect.contains(event.pos):
            return True
        if event.pos.y < layout.list_top \
                or event.pos.y >= layout.list_top + layout.list_height:
            return True
        var idx = self.scroll + (event.pos.y - layout.list_top)
        if idx < 0 or idx >= len(self.matched):
            return True
        # Shift+click extends the multi-select (anchor stays); plain
        # click collapses to a single-row selection. Click-on-already-
        # selected (with no shift) is the submit shortcut, matching how
        # the picker behaved before multi-select existed.
        self._pending_restore = False
        var shift = (event.mods & MOD_SHIFT) != 0
        if shift:
            self.selected = idx
            return True
        if idx == self.selected and self.anchor == self.selected:
            self.selected = idx
            self.anchor = idx
            self._collect_selected_paths()
            self.submitted = True
            return True
        self.selected = idx
        self.anchor = idx
        return True

    def _scroll_to_selection(mut self):
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


def quick_open_match(path: String, query: String) -> Bool:
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


def _split_query_to_parts(q: String) -> List[String]:
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


def _find_substring_ci(path: String, needle: String, start: Int) -> Int:
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


def _ci_byte_eq(a: UInt8, b: UInt8) -> Bool:
    var ai = Int(a)
    var bi = Int(b)
    if 0x41 <= ai and ai <= 0x5A: ai = ai + 0x20
    if 0x41 <= bi and bi <= 0x5A: bi = bi + 0x20
    return ai == bi
