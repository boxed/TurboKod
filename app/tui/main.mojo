"""Terminal frontend (``tk-tui``), driven over the dylib's C ABI.

This is the terminal counterpart to the Swift host (``app/swift/TurboKod.swift``).
Both are thin frontends over the same Mojo core compiled into
``libturbokod.dylib``; neither compiles the core in. Where the Swift host
rasterizes the cell grid with Core Text and feeds AppKit events, this host
renders the grid as ANSI (reusing ``Terminal``'s diff-``present``) and feeds
terminal escape-sequence input — but it reaches the ``Desktop`` *only* through
the C ABI in ``native_api.mojo`` (the ``tk_desktop_*`` functions), exactly like
Swift does.

Why over the C ABI instead of importing ``Desktop`` directly: a binary that
imported the core would statically compile ~4.6 MB of it, and the .app bundle
would then carry the core twice (once here, once in the dylib the Swift host
loads). By linking the single bundled ``libturbokod.dylib`` and calling its C
ABI, this binary stays tiny and shares one copy of the core.

Imports are kept to the light, frontend-side modules only (``app``,
``cell``, ``colors``, ``events``, ``file_dialog``, ``file_io``, ``geometry``,
``posix`` — none of which pull in ``desktop``/``editor``/``highlight``). The
heavy core is behind the dylib.

The per-frame contract mirrors the Swift host: ``tk_desktop_tick`` (which does
external-file reload, menu-visibility, file-tree opens, and LSP/DAP/autosave
ticks *inside* the core), then ``tk_desktop_layout`` to pull the packed cell
grid, then feed input via ``tk_desktop_key``/``mouse``/``mod_key``/``paste``.
The only frontend-side UI is the in-grid ``FileDialog`` for Open / Quick Open /
Open Project (the Swift host uses a native ``NSOpenPanel`` for the same).
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.sys import argv

from turbokod.app import Application
from turbokod.canvas import Canvas
from turbokod.cell import Cell
from turbokod.colors import Attr
from turbokod.events import (
    Event,
    EVENT_KEY, EVENT_MOUSE, EVENT_MOD_KEY, EVENT_OPEN_PATH, EVENT_PASTE,
    EVENT_RESIZE,
)
from turbokod.file_dialog import FileDialog
from turbokod.file_io import stat_file
from turbokod.geometry import Point, Rect
from turbokod.posix import chdir_path, getcwd_path, realpath


# ---------------------------------------------------------------------------
# C ABI action codes — mirror ``native_api.mojo`` (the ``ACT_*`` constants).
# Only the ones this host acts on are listed; everything else is a no-op.
# ---------------------------------------------------------------------------
comptime ACT_QUIT         = Int32(1)
comptime ACT_OPEN_FILE    = Int32(2)
comptime ACT_QUICK_OPEN   = Int32(3)
comptime ACT_OPEN_PROJECT = Int32(4)

# 5 UInt32 per cell in the layout buffer (see ``_pack_canvas`` in native_api):
# [codepoint, fg|bg<<8|style<<16|color_mode<<24, underline_color, fg_rgb, bg_rgb].
comptime CELL_WORDS = 5


# ---------------------------------------------------------------------------
# C ABI wrappers. These resolve against the bundled ``libturbokod.dylib`` at
# link time (``-L .build -lturbokod``); the symbols are the C-named ``@export``
# functions in ``native_api.mojo``. Strings cross the boundary as (ptr, len).
# ---------------------------------------------------------------------------
def _tk_new() -> Int:
    return external_call["tk_desktop_new", Int]()


def _tk_free(h: Int):
    external_call["tk_desktop_free", NoneType](h)


def _tk_recover_user_shell_path():
    external_call["tk_recover_user_shell_path", NoneType]()


def _tk_tick(h: Int, cols: Int, rows: Int):
    external_call["tk_desktop_tick", NoneType](h, cols, rows)


def _tk_layout(h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int) -> Int:
    return external_call["tk_desktop_layout", Int](h, cols, rows, out_ptr, cap)


def _tk_theme_version(h: Int) -> Int:
    return external_call["tk_theme_version", Int](h)


def _tk_theme_palette(h: Int, out_ptr: Int, cap: Int) -> Int:
    return external_call["tk_theme_palette", Int](h, out_ptr, cap)


def _tk_key(h: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int) -> Int32:
    return external_call["tk_desktop_key", Int32](h, key, mods, cols, rows)


def _tk_mod_key(h: Int, mod_id: UInt32, pressed: UInt8) -> Int32:
    return external_call["tk_desktop_mod_key", Int32](h, mod_id, pressed)


def _tk_mouse(
    h: Int, x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, cols: Int, rows: Int, click_count: UInt8,
) -> Int32:
    return external_call["tk_desktop_mouse", Int32](
        h, x, y, button, pressed, motion, mods, cols, rows, click_count,
    )


def _tk_paste(h: Int, ptr: Int, n: Int) -> Int32:
    return external_call["tk_desktop_paste_clipboard_text", Int32](h, ptr, n)


def _tk_open_file(h: Int, ptr: Int, n: Int, cols: Int, rows: Int):
    external_call["tk_desktop_open_file", NoneType](h, ptr, n, cols, rows)


def _tk_open_project(h: Int, ptr: Int, n: Int):
    external_call["tk_desktop_open_project", NoneType](h, ptr, n)


def _tk_open_file_at(
    h: Int, ptr: Int, n: Int, line: Int, character: Int, cols: Int, rows: Int,
):
    external_call["tk_desktop_open_file_at", NoneType](
        h, ptr, n, line, character, cols, rows,
    )


def _tk_pointer_shape(h: Int, x: Int, y: Int, cols: Int, rows: Int) -> Int32:
    return external_call["tk_desktop_pointer_shape", Int32](h, x, y, cols, rows)


# ---------------------------------------------------------------------------
# Open-arg parsing — a path optionally suffixed with ``\x1f<line>`` (1-based),
# which a second ``tk`` invocation / URL forward can carry. Copied from
# ``examples/desktop.mojo`` (byte-only, no core deps).
# ---------------------------------------------------------------------------
def _split_open_arg_path(arg: String) -> String:
    var b = arg.as_bytes()
    for i in range(len(b)):
        if b[i] == 0x1F:
            return String(StringSlice(unsafe_from_utf8=b[:i]))
    return arg


def _split_open_arg_line(arg: String) -> Int:
    var b = arg.as_bytes()
    var sep = -1
    for i in range(len(b)):
        if b[i] == 0x1F:
            sep = i
            break
    if sep < 0:
        return 0
    var n = 0
    var saw = False
    var p = sep + 1
    while p < len(b):
        var c = Int(b[p])
        if c < 0x30 or c > 0x39:
            break
        n = n * 10 + (c - 0x30)
        saw = True
        p += 1
    return n if saw else 0


def _dirname(path: String) -> String:
    """Directory portion of ``path`` (everything before the last ``/``)."""
    var b = path.as_bytes()
    var last = -1
    for i in range(len(b)):
        if b[i] == 0x2F:  # '/'
            last = i
    if last <= 0:
        return String("/")
    return String(StringSlice(unsafe_from_utf8=b[:last]))


def _abspath(path: String) -> String:
    """Resolve ``path`` to an absolute path. Uses ``realpath`` when it exists;
    for a not-yet-created file (``realpath`` fails) fall back to joining the
    process cwd so a relative new-file arg survives the later chdir to the
    bundle's Resources dir."""
    var rp = realpath(path)
    if rp.byte_length() > 0:
        return rp
    if path.byte_length() > 0 and path.as_bytes()[0] == 0x2F:  # already '/'
        return path
    var cwd = getcwd_path()
    if cwd.byte_length() == 0:
        return path
    return cwd + String("/") + path


def _exe_path() -> String:
    """This binary's own path via ``_NSGetExecutablePath`` (macOS)."""
    var buf = List[UInt8]()
    for _ in range(4096):
        buf.append(0)
    var sz = List[UInt32]()
    sz.append(UInt32(4096))
    var rc = external_call["_NSGetExecutablePath", Int32](
        buf.unsafe_ptr(), sz.unsafe_ptr(),
    )
    if Int(rc) != 0:
        return String("")
    var n = 0
    while n < len(buf) and buf[n] != 0:
        n += 1
    return String(StringSlice(unsafe_from_utf8=buf[:n]))


def _chdir_to_resources_if_bundled():
    """When launched from inside ``TurboKod.app`` (binary at
    ``Contents/MacOS/tk-tui``), chdir to ``Contents/Resources`` so the core's
    cwd-relative grammar/data paths resolve — same as the Swift host's
    ``chdirToResourceRoot``. When launched from a dev checkout (no sibling
    Resources tree), leave cwd alone so repo-relative grammars resolve."""
    var exe = _exe_path()
    if exe.byte_length() == 0:
        return
    var real = realpath(exe)
    if real.byte_length() == 0:
        real = exe
    var macos_dir = _dirname(real)  # .../Contents/MacOS
    var resources = realpath(macos_dir + String("/../Resources"))
    if resources.byte_length() == 0:
        return
    # Only adopt the bundle cwd when it actually carries the grammar tree —
    # otherwise a dev run would chdir into a stray ``Resources`` and lose the
    # repo's grammars.
    var probe = stat_file(resources + String("/src/turbokod/grammars"))
    if not (probe.ok and probe.is_dir()):
        return
    _ = chdir_path(resources)


def _push_palette(h: Int, mut app: Application):
    """Fetch the active theme's 256-entry RGB palette and hand it to the
    terminal so its truecolor renderer paints the theme (not the user's
    terminal scheme), matching the native app pixel-for-pixel."""
    var pal = List[UInt32]()
    for _ in range(256):
        pal.append(UInt32(0))
    _ = _tk_theme_palette(h, Int(pal.unsafe_ptr()), 256)
    app.set_palette(pal)


def _shape_name(code: Int32) -> String:
    if code == Int32(1):
        return String("text")
    if code == Int32(2):
        return String("pointer")
    return String("default")


def _unpack_into(buf: List[UInt32], n: Int, mut canvas: Canvas):
    """Reconstruct the back canvas from the packed layout buffer.

    The pack drops ``Cell.width`` (it only carries a codepoint), so we
    recompute it: ``Cell(glyph, attr)`` derives width via ``cell_width`` (2 for
    emoji), and we force the cell *after* a width-2 glyph to be a width-0
    continuation — exactly the shape ``Terminal.present`` expects (it skips
    width-0 cells and advances two columns for width-2). Attr fields are set
    directly (not via the ``with_*_rgb`` builders) so we mirror precisely what
    the core packed, with no re-derivation."""
    var ci = 0
    while ci < n:
        var base = ci * CELL_WORDS
        var cp = Int(buf[base])
        if cp <= 0:
            cp = 0x20
        var w1 = buf[base + 1]
        var w2 = buf[base + 2]
        var attr = Attr()
        attr.fg = UInt8(w1 & 0xFF)
        attr.bg = UInt8((w1 >> 8) & 0xFF)
        attr.style = UInt8((w1 >> 16) & 0xFF)
        attr.color_mode = UInt8((w1 >> 24) & 0xFF)
        if w2 == UInt32(0xFFFFFFFF):
            attr.underline_color = Int16(-1)
        else:
            attr.underline_color = Int16(Int(w2 & 0xFFFF))
        attr.fg_rgb = buf[base + 3]
        attr.bg_rgb = buf[base + 4]
        var cell = Cell(chr(cp), attr)
        canvas.cells[ci] = cell
        if cell.width == 2:
            if ci + 1 < n:
                canvas.cells[ci + 1] = Cell(String(""), attr, 0)
            ci += 2
        else:
            ci += 1


def main() raises:
    # Absolutize file args against the launch cwd *before* we chdir into the
    # bundle's Resources dir; keep the optional ``\x1f<line>`` jump suffix.
    var open_args = List[String]()
    var all_args = argv()
    for i in range(1, len(all_args)):
        var raw = String(all_args[i])
        var path = _split_open_arg_path(raw)
        var line = _split_open_arg_line(raw)
        var ap = _abspath(path)
        if line > 0:
            open_args.append(ap + chr(0x1F) + String(line))
        else:
            open_args.append(ap)

    _chdir_to_resources_if_bundled()

    var app = Application()
    app.start()
    var h = _tk_new()
    if h == 0:
        app.stop()
        print("tk-tui: failed to create desktop (tk_desktop_new returned 0)")
        return

    # Best-effort: recover the user's login-shell PATH so spawned LSP/DAP tools
    # resolve even when launched from a minimal environment.
    _tk_recover_user_shell_path()

    var file_dialog = FileDialog()
    var last_project = Optional[String]()
    var last_theme_version = _tk_theme_version(h)
    _push_palette(h, app)

    # Open any startup args (dir -> project, file -> editor, ...#line -> jump).
    for i in range(len(open_args)):
        _open_arg(h, open_args[i], app.back.width, app.back.height, last_project)

    var layout_buf = List[UInt32]()
    var buf_cells = -1

    while app.running:
        var cols = app.back.width
        var rows = app.back.height
        var n = cols * rows

        # Core housekeeping: external reload, menu visibility, file-tree opens,
        # LSP/DAP/autosave ticks — all inside the dylib, like the Swift host.
        _tk_tick(h, cols, rows)

        var tv = _tk_theme_version(h)
        if tv != last_theme_version:
            _push_palette(h, app)
            last_theme_version = tv

        # (Re)allocate the layout buffer when the grid size changes.
        if n != buf_cells:
            layout_buf = List[UInt32]()
            for _ in range(n * CELL_WORDS):
                layout_buf.append(UInt32(0))
            buf_cells = n

        var written = _tk_layout(h, cols, rows, Int(layout_buf.unsafe_ptr()), n)
        _unpack_into(layout_buf, written, app.back)

        if file_dialog.active:
            file_dialog.paint(app.back, app.screen())

        app.present()

        var maybe_ev = app.next_event(50)
        if not maybe_ev:
            continue
        var ev = maybe_ev.value()

        # next_event already resized app.back; relayout next frame.
        if ev.kind == EVENT_RESIZE:
            continue

        # Pointer-shape hint. ``set_pointer_shape`` is a no-op unless launched
        # under the native app's PTY (TURBOKOD_HOST=1); harmless otherwise.
        if ev.kind == EVENT_MOUSE and not file_dialog.active:
            try:
                app.terminal.set_pointer_shape(
                    _shape_name(_tk_pointer_shape(h, ev.pos.x, ev.pos.y, cols, rows))
                )
            except:
                pass

        # A path forwarded from a second invocation (same treatment as argv).
        if ev.kind == EVENT_OPEN_PATH:
            if ev.text.byte_length() > 0:
                var info = stat_file(ev.text)
                if info.ok and info.is_dir():
                    _tk_open_project(h, Int(ev.text.unsafe_ptr()), len(ev.text.as_bytes()))
                    last_project = Optional[String](ev.text)
                else:
                    var line = ev.pos.y
                    if line > 0:
                        _tk_open_file_at(
                            h, Int(ev.text.unsafe_ptr()), len(ev.text.as_bytes()),
                            line - 1, 0, cols, rows,
                        )
                    else:
                        _tk_open_file(
                            h, Int(ev.text.unsafe_ptr()), len(ev.text.as_bytes()),
                            cols, rows,
                        )
            continue

        # Modal: the file dialog eats every event while open.
        if file_dialog.active:
            if ev.kind == EVENT_KEY:
                _ = file_dialog.handle_key(ev)
            else:
                _ = file_dialog.handle_mouse(ev, app.screen())
            if file_dialog.submitted:
                var path = file_dialog.selected_path
                var picks_project = file_dialog.dirs_only
                file_dialog.close()
                if picks_project:
                    _tk_open_project(h, Int(path.unsafe_ptr()), len(path.as_bytes()))
                    last_project = Optional[String](path)
                else:
                    _tk_open_file(h, Int(path.unsafe_ptr()), len(path.as_bytes()), cols, rows)
            continue

        # Feed the event to the core; act on the returned host-action code.
        var action = Int32(0)
        if ev.kind == EVENT_KEY:
            action = _tk_key(h, ev.key, ev.mods, cols, rows)
        elif ev.kind == EVENT_MOUSE:
            action = _tk_mouse(
                h, ev.pos.x, ev.pos.y, ev.button,
                UInt8(1) if ev.pressed else UInt8(0),
                UInt8(1) if ev.motion else UInt8(0),
                ev.mods, cols, rows, ev.click_count,
            )
        elif ev.kind == EVENT_MOD_KEY:
            action = _tk_mod_key(h, ev.key, UInt8(1) if ev.pressed else UInt8(0))
        elif ev.kind == EVENT_PASTE:
            action = _tk_paste(h, Int(ev.text.unsafe_ptr()), len(ev.text.as_bytes()))

        if action == ACT_QUIT:
            app.quit()
        elif action == ACT_OPEN_FILE or action == ACT_QUICK_OPEN:
            file_dialog.open(_dialog_start(last_project))
            file_dialog.set_project(last_project)
        elif action == ACT_OPEN_PROJECT:
            file_dialog.open_directory(_dialog_start(last_project))
            file_dialog.set_project(last_project)

    app.stop()
    _tk_free(h)


def _dialog_start(project: Optional[String]) -> String:
    if project:
        return project.value()
    return String(".")


def _open_arg(
    h: Int, raw: String, cols: Int, rows: Int, mut last_project: Optional[String],
):
    var path = _split_open_arg_path(raw)
    var line = _split_open_arg_line(raw)
    var info = stat_file(path)
    if info.ok and info.is_dir():
        _tk_open_project(h, Int(path.unsafe_ptr()), len(path.as_bytes()))
        last_project = Optional[String](path)
        return
    var pp = Int(path.unsafe_ptr())
    var pl = len(path.as_bytes())
    if line > 0:
        _tk_open_file_at(h, pp, pl, line - 1, 0, cols, rows)
    else:
        _tk_open_file(h, pp, pl, cols, rows)
