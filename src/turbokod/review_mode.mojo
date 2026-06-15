"""ReviewMode: a distraction-free, full-screen changeset reviewer.

Unlike ``LocalChanges`` (a lazygit-style multi-pane modal built for
*staging* individual lines), ReviewMode is built for *reading* a change
file-by-file. The user picks a changeset — unstaged, staged, or a
specific commit — and steps through it with a bottom toolbar:

* a left-aligned ``‹ Previous`` button and a right-aligned ``Next ›``
  button jump between **changes**: the next change within the current
  file, or the first change of the next file once a file's changes run
  out;
* the middle of the toolbar shows ``x of y files, z of w changes`` over
  a progress-bar background that fills as you advance.

The body is a **full-file view**, one file at a time: every line of the
file is shown (not just the hunk windows), with removed lines spliced
inline. Removed (old) lines carry a red ``▌`` left-gutter mark, added
lines a green ``▌``; unchanged context lines have no mark. Line text
keeps its normal syntax colours. A fixed header shows the current file
path and ``file x of y``.

The inline full-file diff is computed with the line-level Myers differ
(`diff_lines` in ``diff.mojo``) over the before/after file texts, which
gives complete context for free — equal ops become context rows, deletes
become removed rows (drawn from the *before* file), inserts become added
rows (drawn from the *after* file). Per-side syntax highlighting then
tokenizes each full side so multi-line scopes resolve correctly: context
and added rows pull from the after-file tokenization, removed rows from
the before-file.

This is a frontend-agnostic, in-grid surface (``Canvas`` out, ``Event``
in) like every other modal, so it works in both the terminal and native
macOS frontends with no host-specific code — the native menu picks the
``git:review`` action up automatically.
"""

from .canvas import (
    Canvas, paint_drop_shadow, utf8_byte_to_cell, utf8_codepoint_count,
)
from .colors import (
    Attr, BG_TRUECOLOR, BLACK, CYAN, DARK_GRAY, EDITOR_BG, FG_TRUECOLOR, GREEN,
    LIGHT_GRAY, LIGHT_GREEN, LIGHT_RED, SYN_IDENT, WHITE,
)
from .diff import diff_lines
from .events import (
    Event, EVENT_KEY, EVENT_MOUSE,
    KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC, KEY_HOME, KEY_LEFT,
    KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_UP,
    MOD_NONE,
    MOUSE_BUTTON_LEFT, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from .file_io import join_path, read_file
from .geometry import Point, Rect
from .git_changes import (
    compute_staged_diff, compute_unstaged_diff,
    fetch_blob_text, fetch_commit_show, fetch_git_commits,
    parse_unified_diff_files,
)
from .highlight import (
    GrammarRegistry, Highlight, HighlightCache,
    extension_of, highlight_for_extension_cached,
)
from .painter import Painter
from .string_utils import display_columns, split_lines_no_trailing, starts_with


# --- row kinds --------------------------------------------------------------
comptime _RK_CTX:  Int = 0   # unchanged context line
comptime _RK_ADD:  Int = 1   # added line (after file)
comptime _RK_REM:  Int = 2   # removed line (before file)
comptime _RK_INFO: Int = 3   # synthetic message (e.g. binary file)

# --- sub-states -------------------------------------------------------------
comptime _MODE_PICKER: Int = 0
comptime _MODE_REVIEW: Int = 1

# --- changeset sources ------------------------------------------------------
comptime _SRC_UNSTAGED: Int = 0
comptime _SRC_STAGED:   Int = 1
comptime _SRC_COMMIT:   Int = 2

# Skip syntax highlighting on inputs above this size or with any line
# longer than this. The per-line cap is the real guard against minified
# files (one enormous line stalls the libonig grammar walk); the byte cap
# is a coarse backstop, so it's generous enough to cover ordinary source
# files (``LocalChanges`` uses a tighter 64 KB because a commit can touch
# dozens of files at once, but review tokenizes only the picked changeset).
# When skipped the diff still renders — just without the syntax overlay.
comptime _HL_SIZE_CAP:  Int = 1024 * 1024
comptime _HL_LONG_LINE: Int = 2000

# When a change is scrolled into view it's placed at the golden-ratio line
# — ~38% down the viewport — so there's more context below than above,
# which reads more naturally than pinning it to the top.
comptime _GOLDEN_PCT: Int = 38

# Off-change rows are dimmed two ways so the current change pops:
#   * their *background* is shifted toward a contrast target — normally
#     black (darkens Turbo's blue, darkens white toward grey), but toward
#     grey for an already-near-black background (which can't go darker);
#   * their *foreground* is then mixed toward that shifted background so
#     the text reads as low-contrast against it.
# Blending off the *actual* palette RGB means this works for any theme,
# dark or light, with no explicit mode flag. Tune these to taste.
comptime _DIM_PCT: Int = 35   # fg → (shifted) bg
comptime _BG_PCT:  Int = 28   # bg → contrast target
# A background whose brightest channel is below this shifts toward grey
# (lighten) instead of toward black, so a near-black theme still gains
# contrast. Using the max channel (not luminance) keeps saturated-but-dark
# backgrounds like Turbo's blue (0x0021AA) on the darken path.
comptime _DARK_MAX: Int = 40

# Number of recent commits offered in the picker.
comptime _COMMIT_LIMIT: Int = 30


@fieldwise_init
struct ReviewFile(Copyable, Movable):
    """One file's full-file view. ``rows`` / ``kinds`` are parallel: the
    complete file content with removed lines spliced inline, each tagged
    context / added / removed. ``highlights`` is a syntax-colour overlay
    whose ``row`` indexes into ``rows``. ``changes`` holds the ``rows``
    index where each contiguous run of added/removed lines (one
    navigable "change") begins."""
    var path: String
    var rows: List[String]
    var kinds: List[Int]
    var highlights: List[Highlight]
    var changes: List[Int]


def _extract_diff_part(show_text: String) -> String:
    """Slice the multi-file unified diff out of ``git show`` output:
    everything from the first ``diff --git`` line onward. Used only to
    recover the *file list* of a commit (the content comes from blobs);
    empty when the commit has no diff."""
    var lines = split_lines_no_trailing(show_text)
    var diff_start = -1
    for i in range(len(lines)):
        if starts_with(lines[i], String("diff --git ")):
            diff_start = i
            break
    if diff_start < 0:
        return String("")
    var out = List[UInt8]()
    for li in range(diff_start, len(lines)):
        var lb = lines[li].as_bytes()
        for j in range(len(lb)):
            out.append(lb[j])
        out.append(0x0A)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _diff_is_binary(diff_text: String) -> Bool:
    """``True`` when git reported this file as binary (no text diff to
    splice). Such files get a one-line placeholder instead of content."""
    var lines = split_lines_no_trailing(diff_text)
    for i in range(len(lines)):
        if starts_with(lines[i], String("Binary files ")):
            return True
        if starts_with(lines[i], String("GIT binary patch")):
            return True
    return False


def _one_char(b: UInt8) -> String:
    var buf = List[UInt8]()
    buf.append(b)
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _blend_rgb(src: UInt32, dst: UInt32, pct: Int) -> UInt32:
    """Mix ``src`` ``pct``% of the way toward ``dst`` (both ``0xRRGGBB``)."""
    var sr = Int((src >> 16) & 0xFF)
    var sg = Int((src >> 8) & 0xFF)
    var sb = Int(src & 0xFF)
    var dr = Int((dst >> 16) & 0xFF)
    var dg = Int((dst >> 8) & 0xFF)
    var db = Int(dst & 0xFF)
    var rr = (sr * (100 - pct) + dr * pct) // 100
    var rg = (sg * (100 - pct) + dg * pct) // 100
    var rb = (sb * (100 - pct) + db * pct) // 100
    return (UInt32(rr) << 16) | (UInt32(rg) << 8) | UInt32(rb)


def _max_channel(rgb: UInt32) -> Int:
    """Brightest of the three channels of ``0xRRGGBB`` — a proxy for "how
    close to black", used to choose the dim direction without being fooled
    by a saturated-but-dark hue (e.g. pure blue has low luminance but a
    bright blue channel, so it can still darken)."""
    var r = Int((rgb >> 16) & 0xFF)
    var g = Int((rgb >> 8) & 0xFF)
    var b = Int(rgb & 0xFF)
    var m = r
    if g > m:
        m = g
    if b > m:
        m = b
    return m


def _resolve_fg(attr: Attr, palette: List[UInt32], fallback: UInt32) -> UInt32:
    if (attr.color_mode & FG_TRUECOLOR) != 0:
        return attr.fg_rgb
    if Int(attr.fg) < len(palette):
        return palette[Int(attr.fg)]
    return fallback


def _resolve_bg(attr: Attr, palette: List[UInt32], fallback: UInt32) -> UInt32:
    if (attr.color_mode & BG_TRUECOLOR) != 0:
        return attr.bg_rgb
    if Int(attr.bg) < len(palette):
        return palette[Int(attr.bg)]
    return fallback


def _dim_cell(
    attr: Attr, palette: List[UInt32], contrast_target: UInt32,
) -> Attr:
    """Dim one off-change cell: shift its background ``_BG_PCT``% toward
    ``contrast_target``, then mix its foreground ``_DIM_PCT``% toward that
    shifted background so the text recedes into it."""
    var bg = _resolve_bg(attr, palette, contrast_target)
    var new_bg = _blend_rgb(bg, contrast_target, _BG_PCT)
    var fg = _resolve_fg(attr, palette, new_bg)
    var new_fg = _blend_rgb(fg, new_bg, _DIM_PCT)
    return attr.with_fg_rgb(new_fg).with_bg_rgb(new_bg)


struct ReviewMode(Movable):
    var active: Bool
    var mode: Int
    var root: String

    # Picker state. Parallel lists: option label, source kind, commit SHA
    # (empty for the unstaged / staged rows).
    var picker_labels: List[String]
    var picker_kind: List[Int]
    var picker_sha: List[String]
    var picker_cursor: Int

    # Review state. One ``ReviewFile`` per changed file; ``nav_file`` /
    # ``nav_row`` flatten every file's changes into a single ordered list
    # so Prev/Next walk change-to-change across files. ``cur`` indexes
    # that flat list; ``scroll`` is the top row within the current file.
    var title: String
    var files: List[ReviewFile]
    var nav_file: List[Int]
    var nav_row: List[Int]
    var cur: Int
    var scroll: Int
    # The first change is selected at build time, before ``view_h`` is
    # known, so its golden-ratio scroll can't be computed yet — defer it
    # to the first paint.
    var recenter_pending: Bool

    # Geometry stamped by ``paint`` so event handling can hit-test the
    # toolbar buttons and page by the body height. ``-1`` until painted.
    var view_h: Int
    var tb_y: Int
    var tb_prev_lo: Int
    var tb_prev_hi: Int
    var tb_next_lo: Int
    var tb_next_hi: Int
    var pk_y0: Int
    var pk_x0: Int
    var pk_x1: Int

    def __init__(out self):
        self.active = False
        self.mode = _MODE_PICKER
        self.root = String("")
        self.picker_labels = List[String]()
        self.picker_kind = List[Int]()
        self.picker_sha = List[String]()
        self.picker_cursor = 0
        self.title = String("")
        self.files = List[ReviewFile]()
        self.nav_file = List[Int]()
        self.nav_row = List[Int]()
        self.cur = 0
        self.scroll = 0
        self.recenter_pending = False
        self.view_h = 0
        self.tb_y = -1
        self.tb_prev_lo = -1
        self.tb_prev_hi = -1
        self.tb_next_lo = -1
        self.tb_next_hi = -1
        self.pk_y0 = -1
        self.pk_x0 = -1
        self.pk_x1 = -1

    # --- lifecycle --------------------------------------------------------

    def open(mut self, var root: String):
        """Arm the picker for ``root``. The diff isn't built until the
        user chooses a changeset (Enter / click in the picker)."""
        self.root = root^
        self.active = True
        self.mode = _MODE_PICKER
        self.picker_cursor = 0
        self._reset_review()
        self._build_picker()

    def close(mut self):
        self.active = False
        self.picker_labels = List[String]()
        self.picker_kind = List[Int]()
        self.picker_sha = List[String]()
        self._reset_review()

    def _reset_review(mut self):
        self.title = String("")
        self.files = List[ReviewFile]()
        self.nav_file = List[Int]()
        self.nav_row = List[Int]()
        self.cur = 0
        self.scroll = 0
        self.recenter_pending = False

    def _build_picker(mut self):
        self.picker_labels = List[String]()
        self.picker_kind = List[Int]()
        self.picker_sha = List[String]()
        # Only offer the unstaged / staged entries when there's actually a
        # diff on that side — an empty ``git diff`` would just open a blank
        # reviewer, so don't list it.
        if len(compute_unstaged_diff(self.root).as_bytes()) > 0:
            self.picker_labels.append(String("Unstaged changes"))
            self.picker_kind.append(_SRC_UNSTAGED)
            self.picker_sha.append(String(""))
        if len(compute_staged_diff(self.root).as_bytes()) > 0:
            self.picker_labels.append(String("Staged changes"))
            self.picker_kind.append(_SRC_STAGED)
            self.picker_sha.append(String(""))
        var commits = fetch_git_commits(self.root, _COMMIT_LIMIT)
        for i in range(len(commits)):
            var c = commits[i]
            self.picker_labels.append(c.short_sha + String("  ") + c.subject)
            self.picker_kind.append(_SRC_COMMIT)
            self.picker_sha.append(c.short_sha)

    def _start_review(mut self, mut registry: GrammarRegistry):
        if self.picker_cursor < 0 or self.picker_cursor >= len(self.picker_labels):
            return
        var kind = self.picker_kind[self.picker_cursor]
        var sha = self.picker_sha[self.picker_cursor]
        self.title = self.picker_labels[self.picker_cursor]
        self.mode = _MODE_REVIEW
        self._build_model(kind, sha, registry)

    # --- model build ------------------------------------------------------

    def _build_model(
        mut self, src: Int, sha: String, mut registry: GrammarRegistry,
    ):
        self._reset_review()
        var diff_text: String
        if src == _SRC_UNSTAGED:
            diff_text = compute_unstaged_diff(self.root)
        elif src == _SRC_STAGED:
            diff_text = compute_staged_diff(self.root)
        else:
            diff_text = _extract_diff_part(fetch_commit_show(self.root, sha))
        # The diff only tells us *which* files changed; the full content
        # of each side comes from blobs / the worktree so the view shows
        # the whole file, not just the hunk windows.
        var changed = parse_unified_diff_files(diff_text)
        for fi in range(len(changed)):
            var cf = changed[fi]
            var is_binary = _diff_is_binary(cf.diff)
            var before = String("")
            var after = String("")
            if not is_binary:
                if src == _SRC_UNSTAGED:
                    # after = worktree file, before = index blob.
                    before = fetch_blob_text(self.root, String(""), cf.path)
                    try:
                        after = read_file(join_path(self.root, cf.path))
                    except:
                        after = String("")
                elif src == _SRC_STAGED:
                    # after = index blob, before = HEAD blob.
                    before = fetch_blob_text(self.root, String("HEAD"), cf.path)
                    after = fetch_blob_text(self.root, String(""), cf.path)
                else:
                    # after = commit blob, before = parent blob (empty for
                    # a file's first appearance → shows as all-added).
                    before = fetch_blob_text(
                        self.root, sha + String("~1"), cf.path,
                    )
                    after = fetch_blob_text(self.root, sha, cf.path)
            self._add_file(cf.path, before, after, is_binary, registry)
        self._finalize()

    def build_from_pairs(
        mut self,
        paths: List[String], befores: List[String], afters: List[String],
        mut registry: GrammarRegistry,
    ):
        """Build the review model from explicit before/after file texts —
        the deterministic, git-free entry point for tests. ``paths`` /
        ``befores`` / ``afters`` are parallel."""
        self._reset_review()
        for i in range(len(paths)):
            self._add_file(paths[i], befores[i], afters[i], False, registry)
        self._finalize()

    def _add_file(
        mut self,
        path: String, before: String, after: String,
        is_binary: Bool, mut registry: GrammarRegistry,
    ):
        var f = ReviewFile(
            path, List[String](), List[Int](), List[Highlight](), List[Int](),
        )
        if is_binary:
            f.rows.append(String("  (binary file — diff not shown)"))
            f.kinds.append(_RK_INFO)
        else:
            var a_lines = split_lines_no_trailing(before)
            var b_lines = split_lines_no_trailing(after)
            var ops = diff_lines(a_lines, b_lines)
            # Per-row map into each side's full file (0-based line), or -1
            # for rows with no counterpart on that side — feeds the
            # per-side syntax highlighter.
            var d2a = List[Int]()
            var d2b = List[Int]()
            var oi = 0
            while oi < len(ops):
                if ops[oi].kind == 0:   # equal → context (after line)
                    f.rows.append(b_lines[ops[oi].b_index])
                    f.kinds.append(_RK_CTX)
                    d2a.append(ops[oi].b_index)
                    d2b.append(-1)
                    oi += 1
                    continue
                # Start of a change run — gather the consecutive non-equal
                # ops, then emit removed lines *before* added lines so the
                # block reads like a conventional diff (old above new).
                var run_rem = List[Int]()
                var run_add = List[Int]()
                while oi < len(ops) and ops[oi].kind != 0:
                    if ops[oi].kind == 1:
                        run_rem.append(ops[oi].a_index)
                    else:
                        run_add.append(ops[oi].b_index)
                    oi += 1
                f.changes.append(len(f.rows))
                for r in range(len(run_rem)):
                    f.rows.append(a_lines[run_rem[r]])
                    f.kinds.append(_RK_REM)
                    d2a.append(-1)
                    d2b.append(run_rem[r])
                for r in range(len(run_add)):
                    f.rows.append(b_lines[run_add[r]])
                    f.kinds.append(_RK_ADD)
                    d2a.append(run_add[r])
                    d2b.append(-1)
            self._emit_highlights(f, after, path, d2a, registry)
            self._emit_highlights(f, before, path, d2b, registry)
        # Every file stays navigable even with no textual change (mode-only
        # edit, binary) so it isn't silently skipped by Prev/Next.
        if len(f.changes) == 0:
            f.changes.append(0)
        var fidx = len(self.files)
        for ci in range(len(f.changes)):
            self.nav_file.append(fidx)
            self.nav_row.append(f.changes[ci])
        self.files.append(f^)

    def _emit_highlights(
        mut self,
        mut f: ReviewFile,
        side_text: String, file_path: String,
        d2side: List[Int],
        mut registry: GrammarRegistry,
    ):
        """Tokenize one full side of the file and copy each highlight to
        every display row that maps to it. ``d2side[d]`` is the side-file
        line for display row ``d``."""
        if len(side_text.as_bytes()) == 0:
            return
        if len(side_text.as_bytes()) > _HL_SIZE_CAP:
            return
        var side_lines = split_lines_no_trailing(side_text)
        if len(side_lines) == 0:
            return
        for li in range(len(side_lines)):
            if len(side_lines[li].as_bytes()) > _HL_LONG_LINE:
                return
        var ext = extension_of(file_path)
        var cache = HighlightCache()
        var hls = highlight_for_extension_cached(
            ext, side_lines, registry, cache,
        )
        if len(hls) == 0:
            return
        var inv = List[List[Int]]()
        for _ in range(len(side_lines)):
            inv.append(List[Int]())
        for d in range(len(d2side)):
            var r = d2side[d]
            if 0 <= r and r < len(side_lines):
                inv[r].append(d)
        for h in range(len(hls)):
            var hl = hls[h]
            if hl.row < 0 or hl.row >= len(inv):
                continue
            for k in range(len(inv[hl.row])):
                f.highlights.append(
                    Highlight(
                        inv[hl.row][k], hl.col_start, hl.col_end, hl.attr,
                    ),
                )

    def _finalize(mut self):
        self.cur = 0
        self.scroll = 0
        # Defer the golden-ratio scroll of the first change to the first
        # paint, where ``view_h`` is known.
        self.recenter_pending = len(self.nav_row) > 0

    # --- navigation -------------------------------------------------------

    def _cur_file(self) -> Int:
        if self.cur < 0 or self.cur >= len(self.nav_file):
            return -1
        return self.nav_file[self.cur]

    def _scroll_for(self, row: Int) -> Int:
        # Golden-ratio scroll: put the change ~38% down the viewport.
        var s = row - (self.view_h * _GOLDEN_PCT) // 100
        if s < 0:
            s = 0
        return s

    def _goto(mut self, idx: Int):
        if len(self.nav_row) == 0:
            return
        var i = idx
        if i < 0:
            i = 0
        if i >= len(self.nav_row):
            i = len(self.nav_row) - 1
        self.cur = i
        self.scroll = self._scroll_for(self.nav_row[i])
        self._clamp_scroll()

    def _clamp_scroll(mut self):
        var fi = self._cur_file()
        var nrows = len(self.files[fi].rows) if fi >= 0 else 0
        var max_scroll = nrows - self.view_h
        if max_scroll < 0:
            max_scroll = 0
        if self.scroll > max_scroll:
            self.scroll = max_scroll
        if self.scroll < 0:
            self.scroll = 0

    # --- paint ------------------------------------------------------------

    def paint(
        mut self, mut canvas: Canvas, screen: Rect, top_y: Int,
        palette: List[UInt32],
    ):
        if not self.active:
            return
        if self.mode == _MODE_PICKER:
            self._paint_picker(canvas, screen, top_y)
        else:
            self._paint_review(canvas, screen, top_y, palette)

    def _paint_picker(mut self, mut canvas: Canvas, screen: Rect, top_y: Int):
        var dialog_bg = Attr(BLACK, LIGHT_GRAY)
        var cursor_attr = Attr(BLACK, CYAN)
        var title = String(" Review changes ")
        var n = len(self.picker_labels)
        var maxw = display_columns(title)
        for i in range(n):
            var w = display_columns(self.picker_labels[i])
            if w > maxw:
                maxw = w
        var box_w = maxw + 4
        if box_w > screen.width() - 2:
            box_w = screen.width() - 2
        if box_w < 12:
            box_w = 12
        var box_h = n + 2
        var avail = screen.b.y - top_y
        if box_h > avail:
            box_h = avail
        var x0 = screen.a.x + (screen.width() - box_w) // 2
        var y0 = top_y + (avail - box_h) // 2
        if y0 < top_y:
            y0 = top_y
        if x0 < screen.a.x:
            x0 = screen.a.x
        var box = Rect(x0, y0, x0 + box_w, y0 + box_h)
        paint_drop_shadow(canvas, box)
        canvas.fill(box, String(" "), dialog_bg)
        var painter = Painter(box)
        painter.draw_box(canvas, box, dialog_bg)
        var tx = x0 + (box_w - display_columns(title)) // 2
        _ = painter.put_text(canvas, Point(tx, y0), title, dialog_bg)
        self.pk_y0 = y0 + 1
        self.pk_x0 = x0 + 1
        self.pk_x1 = x0 + box_w - 1
        var rows_shown = box_h - 2
        for i in range(n):
            if i >= rows_shown:
                break
            var y = self.pk_y0 + i
            var row_attr = cursor_attr if i == self.picker_cursor else dialog_bg
            painter.fill(
                canvas, Rect(self.pk_x0, y, self.pk_x1, y + 1),
                String(" "), row_attr,
            )
            _ = painter.put_text(
                canvas, Point(x0 + 2, y), self.picker_labels[i], row_attr,
            )

    def _paint_review(
        mut self, mut canvas: Canvas, screen: Rect, top_y: Int,
        palette: List[UInt32],
    ):
        var body_top = top_y + 1   # row top_y is the file header
        var body_bottom = screen.b.y - 1   # bottom row is the toolbar
        var area = Rect(screen.a.x, body_top, screen.b.x, body_bottom)
        self.view_h = area.height()
        if self.recenter_pending and len(self.nav_row) > 0:
            self.scroll = self._scroll_for(self.nav_row[self.cur])
            self.recenter_pending = False
        self._clamp_scroll()
        self._paint_header(
            canvas, Rect(screen.a.x, top_y, screen.b.x, top_y + 1),
        )
        var body_bg = Attr(SYN_IDENT, EDITOR_BG)
        if not area.is_empty():
            canvas.fill(area, String(" "), body_bg)
            var fi = self._cur_file()
            if fi < 0:
                var msg = String("No changes")
                var mx = area.a.x + (area.width() - display_columns(msg)) // 2
                var my = area.a.y + area.height() // 2
                var p = Painter(area)
                _ = p.put_text(
                    canvas, Point(mx, my), msg, Attr(DARK_GRAY, EDITOR_BG),
                )
            else:
                self._paint_body(canvas, area, fi, palette)
        self._paint_toolbar(canvas, screen)

    def _paint_header(self, mut canvas: Canvas, row: Rect):
        var hbg = Attr(BLACK, CYAN)
        canvas.fill(row, String(" "), hbg)
        var p = Painter(row)
        var fi = self._cur_file()
        var path = self.files[fi].path if fi >= 0 else String("Review")
        _ = p.put_text(canvas, Point(row.a.x + 1, row.a.y), path, hbg)
        if fi >= 0:
            var info = (
                String("file ") + String(fi + 1) + String(" of ")
                + String(len(self.files))
            )
            var ix = row.b.x - display_columns(info) - 1
            if ix > row.a.x + display_columns(path) + 2:
                _ = p.put_text(canvas, Point(ix, row.a.y), info, hbg)

    def _paint_body(
        self, mut canvas: Canvas, area: Rect, fi: Int, palette: List[UInt32],
    ):
        var painter = Painter(area)
        var body_bg = Attr(SYN_IDENT, EDITOR_BG)
        var add_gutter = Attr(LIGHT_GREEN, EDITOR_BG)
        var rem_gutter = Attr(LIGHT_RED, EDITOR_BG)
        var dim_attr = Attr(DARK_GRAY, EDITOR_BG)
        var height = area.height()
        var left = area.a.x
        var right = area.b.x
        var body_x = left + 2
        var nrows = len(self.files[fi].rows)
        # The current change's contiguous run of added/removed rows stays at
        # full colour; everything else is dimmed afterwards so it pops.
        var bright_lo = -1
        var bright_hi = -1
        if self.cur >= 0 and self.cur < len(self.nav_row):
            bright_lo = self.nav_row[self.cur]
            bright_hi = bright_lo
            while bright_hi < nrows and (
                self.files[fi].kinds[bright_hi] == _RK_ADD
                or self.files[fi].kinds[bright_hi] == _RK_REM
            ):
                bright_hi += 1
            if bright_hi == bright_lo:   # INFO row / edge: keep one row bright
                bright_hi = bright_lo + 1 if bright_lo < nrows else bright_lo
        # Bucket highlights by visible-row offset once.
        var hl_buckets = List[List[Int]]()
        for _i in range(height):
            hl_buckets.append(List[Int]())
        for h in range(len(self.files[fi].highlights)):
            var bo = self.files[fi].highlights[h].row - self.scroll
            if 0 <= bo and bo < height:
                hl_buckets[bo].append(h)
        for i in range(height):
            var idx = self.scroll + i
            if idx >= nrows:
                break
            var y = area.a.y + i
            var line = self.files[fi].rows[idx]
            var k = self.files[fi].kinds[idx]
            if k == _RK_INFO:
                _ = painter.put_text(canvas, Point(left, y), line, dim_attr)
                continue
            # Context / add / remove: gutter mark, then the line text.
            if k == _RK_ADD:
                _ = painter.put_text(
                    canvas, Point(left, y), String("▌"), add_gutter,
                )
            elif k == _RK_REM:
                _ = painter.put_text(
                    canvas, Point(left, y), String("▌"), rem_gutter,
                )
            _ = painter.put_text(canvas, Point(body_x, y), line, body_bg)
            # Syntax-highlight overlay. ``col_start`` / ``col_end`` are
            # byte offsets into the line; map to cells for multi-byte text.
            if len(hl_buckets[i]) > 0:
                var bytes = line.as_bytes()
                var byte_count = len(bytes)
                var byte_to_cell = utf8_byte_to_cell(line)
                var cell_count = utf8_codepoint_count(line)
                for bi in range(len(hl_buckets[i])):
                    var hl = self.files[fi].highlights[hl_buckets[i][bi]]
                    var lo = hl.col_start
                    var hi = hl.col_end
                    if lo < 0:
                        lo = 0
                    if hi > byte_count:
                        hi = byte_count
                    if lo >= hi:
                        continue
                    var cell_lo = byte_to_cell[lo]
                    var cell_hi = byte_to_cell[hi] if hi < byte_count else cell_count
                    for c in range(cell_lo, cell_hi):
                        var sx = body_x + c
                        if sx >= right:
                            break
                        painter.set_attr(canvas, sx, y, hl.attr)
        # Dim pass: fade every visible row outside the current change —
        # including the empty area past the file's end — so the change pops
        # against a uniformly dimmed backdrop. Runs after painting so it
        # catches gutter marks and syntax-overlay colours alike.
        if bright_lo >= 0:
            var editor_bg = palette[Int(EDITOR_BG)] if Int(EDITOR_BG) < len(palette) else UInt32(0)
            # Shift toward black to darken (Turbo blue, white); but a
            # near-black background can't darken, so shift toward grey.
            var contrast_target = UInt32(0x808080) if _max_channel(editor_bg) < _DARK_MAX else UInt32(0)
            for i in range(height):
                var idx = self.scroll + i
                if idx >= bright_lo and idx < bright_hi:
                    continue
                var y = area.a.y + i
                for x in range(left, right):
                    var dimmed = _dim_cell(
                        canvas.get(x, y).attr, palette, contrast_target,
                    )
                    canvas.set_attr(x, y, dimmed)

    def _paint_toolbar(mut self, mut canvas: Canvas, screen: Rect):
        var y = screen.b.y - 1
        self.tb_y = y
        var row = Rect(screen.a.x, y, screen.b.x, y + 1)
        var bar_bg = Attr(BLACK, LIGHT_GRAY)
        canvas.fill(row, String(" "), bar_bg)
        var painter = Painter(row)
        var total = len(self.nav_row)
        var have_prev = self.cur > 0
        var have_next = total > 0 and self.cur < total - 1
        var enabled = Attr(BLACK, CYAN)
        var disabled = Attr(DARK_GRAY, LIGHT_GRAY)
        var prev_label = String(" ‹ Previous ")
        var next_label = String(" Next › ")
        var prev_w = display_columns(prev_label)
        self.tb_prev_lo = screen.a.x
        self.tb_prev_hi = screen.a.x + prev_w
        _ = painter.put_text(
            canvas, Point(self.tb_prev_lo, y), prev_label,
            enabled if have_prev else disabled,
        )
        var next_w = display_columns(next_label)
        self.tb_next_lo = screen.b.x - next_w
        self.tb_next_hi = screen.b.x
        _ = painter.put_text(
            canvas, Point(self.tb_next_lo, y), next_label,
            enabled if have_next else disabled,
        )
        # Middle progress bar with the counter centred on top.
        var mid_lo = self.tb_prev_hi + 1
        var mid_hi = self.tb_next_lo - 1
        if mid_hi <= mid_lo:
            return
        var mid_w = mid_hi - mid_lo
        var cur_idx = self.cur + 1 if total > 0 else 0
        var cur_file = self._cur_file() + 1 if total > 0 else 0
        var filled = 0
        if total > 0:
            filled = mid_w * cur_idx // total
            if filled > mid_w:
                filled = mid_w
        var filled_bg = Attr(BLACK, GREEN)
        var empty_bg = Attr(WHITE, DARK_GRAY)
        if filled > 0:
            canvas.fill(
                Rect(mid_lo, y, mid_lo + filled, y + 1), String(" "), filled_bg,
            )
        if filled < mid_w:
            canvas.fill(
                Rect(mid_lo + filled, y, mid_hi, y + 1), String(" "), empty_bg,
            )
        var counter = (
            String(cur_file) + String(" of ") + String(len(self.files))
            + String(" files, ") + String(cur_idx) + String(" of ")
            + String(total) + String(" changes")
        )
        var cw = display_columns(counter)
        var cx = mid_lo + (mid_w - cw) // 2
        if cx < mid_lo:
            cx = mid_lo
        var cb = counter.as_bytes()
        var split = mid_lo + filled
        for j in range(len(cb)):
            var sx = cx + j
            if sx < mid_lo:
                continue
            if sx >= mid_hi:
                break
            var on_filled = sx < split
            var attr = Attr(WHITE, GREEN) if on_filled else Attr(BLACK, DARK_GRAY)
            _ = painter.put_text(canvas, Point(sx, y), _one_char(cb[j]), attr)

    # --- input ------------------------------------------------------------

    def handle_event(
        mut self, event: Event, screen: Rect, top_y: Int,
        mut registry: GrammarRegistry,
    ) -> Bool:
        """Route one event. Always returns ``True`` while active so the
        caller treats ReviewMode as modal and consumes the event."""
        if not self.active:
            return False
        if event.kind == EVENT_KEY:
            self._handle_key(event, registry)
        elif event.kind == EVENT_MOUSE:
            self._handle_mouse(event, registry)
        return True

    def _handle_key(mut self, event: Event, mut registry: GrammarRegistry):
        if event.key == KEY_ESC:
            self.close()
            return
        if self.mode == _MODE_PICKER:
            var n = len(self.picker_labels)
            if event.key == KEY_UP:
                if self.picker_cursor > 0:
                    self.picker_cursor -= 1
            elif event.key == KEY_DOWN:
                if self.picker_cursor < n - 1:
                    self.picker_cursor += 1
            elif event.key == KEY_HOME:
                self.picker_cursor = 0
            elif event.key == KEY_END:
                self.picker_cursor = n - 1 if n > 0 else 0
            elif event.key == KEY_ENTER:
                self._start_review(registry)
            return
        # Review mode.
        var no_mod = event.mods == MOD_NONE
        if event.key == KEY_RIGHT or (no_mod and Int(event.key) == 0x6E):    # 'n'
            self._goto(self.cur + 1)
        elif event.key == KEY_LEFT or (no_mod and Int(event.key) == 0x70):   # 'p'
            self._goto(self.cur - 1)
        elif event.key == KEY_HOME:
            self._goto(0)
        elif event.key == KEY_END:
            self._goto(len(self.nav_row) - 1)
        elif event.key == KEY_UP:
            self.scroll -= 1
            self._clamp_scroll()
        elif event.key == KEY_DOWN:
            self.scroll += 1
            self._clamp_scroll()
        elif event.key == KEY_PAGEUP:
            self.scroll -= self.view_h
            self._clamp_scroll()
        elif event.key == KEY_PAGEDOWN:
            self.scroll += self.view_h
            self._clamp_scroll()

    def _handle_mouse(mut self, event: Event, mut registry: GrammarRegistry):
        if self.mode == _MODE_PICKER:
            if event.button == MOUSE_WHEEL_UP:
                if self.picker_cursor > 0:
                    self.picker_cursor -= 1
            elif event.button == MOUSE_WHEEL_DOWN:
                if self.picker_cursor < len(self.picker_labels) - 1:
                    self.picker_cursor += 1
            elif event.button == MOUSE_BUTTON_LEFT and event.pressed \
                    and not event.motion:
                var px = event.pos.x
                var py = event.pos.y
                var n = len(self.picker_labels)
                if self.pk_x0 <= px and px < self.pk_x1 \
                        and self.pk_y0 <= py and py < self.pk_y0 + n:
                    self.picker_cursor = py - self.pk_y0
                    self._start_review(registry)
            return
        # Review mode.
        if event.button == MOUSE_WHEEL_UP:
            self.scroll -= 3
            self._clamp_scroll()
        elif event.button == MOUSE_WHEEL_DOWN:
            self.scroll += 3
            self._clamp_scroll()
        elif event.button == MOUSE_BUTTON_LEFT and event.pressed \
                and not event.motion:
            if event.pos.y == self.tb_y:
                var px = event.pos.x
                if self.tb_prev_lo <= px and px < self.tb_prev_hi:
                    self._goto(self.cur - 1)
                elif self.tb_next_lo <= px and px < self.tb_next_hi:
                    self._goto(self.cur + 1)
