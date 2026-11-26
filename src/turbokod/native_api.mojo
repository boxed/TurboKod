"""C-ABI surface for the Swift front-end.

The Swift app owns the macOS run loop, windows, menus, and rendering. Each
window holds an opaque handle to a Mojo ``Desktop`` created here; Swift calls
these ``@export``-ed functions to feed events, pull a cell grid to draw, and
run per-frame housekeeping (LSP/DAP/autosave ticks).

The handle is a heap ``Desktop`` pointer: we ``malloc`` storage, construct in
place, and hand the address back as an ``Int``. On later calls we rebuild a
usable pointer with ``Pointer[Desktop, MutUntrackedOrigin](
unsafe_from_address=h)`` — this is how persistent Mojo state survives across
C-ABI calls (Mojo has no module-level mutable globals).

Strings cross as ``(ptr: Int, len: Int)`` UTF-8 byte buffers; the cell grid
crosses as a caller-provided ``UInt32`` buffer, 5 words per cell:
``[codepoint, fg | bg<<8 | style<<16 | color_mode<<24,
   underline_color (0xFFFFFFFF = use fg), fg_rgb, bg_rgb]``.
``color_mode`` bit0/bit1 mark fg/bg as 24-bit truecolor — when set the host
reads ``fg_rgb`` / ``bg_rgb`` (``0xRRGGBB``) instead of the palette index.
"""

from std.ffi import external_call
from std.memory import unsafe_memcpy
from std.sys import size_of

from turbokod.canvas import (
    Canvas, HOST_HSCROLL, HOST_SPLIT, HOST_SURFACE_DIALOG, HOST_SURFACE_GIT,
    HOST_TEST_DETAIL, HOST_TEST_HEADER, HOST_TEST_LIST,
    HOST_SURFACE_MAIN, HOST_SURFACE_PANELS, HOST_SURFACE_SETTINGS,
    HOST_SURFACES, HOST_VSCROLL, SubGrid,
)
from turbokod.events import Event, EVENT_MOUSE, MOD_CTRL, MOD_META
from turbokod.geometry import Point, Rect
from turbokod.local_changes import RightPanel
from turbokod.lsp_shared import new_pool
from turbokod.highlight import new_grammar_store
from turbokod.spell import new_spell_base
from turbokod.json import (
    json_string_array, JsonValue, encode_json, json_array, json_bool, json_int,
    json_object, json_str,
)
from turbokod.posix import (
    getenv_value, prepend_user_bin_dirs_to_path, recover_path_deferred_once,
)
from turbokod.string_utils import escape_drop_paths, split_lines_no_trailing
from turbokod.theme import theme_by_name
from turbokod.desktop import (
    Desktop, APP_QUIT_ACTION, EDITOR_OPEN, EDITOR_PASTE, EDITOR_QUICK_OPEN,
    PROJECT_OPEN, WINDOW_FOCUS_PREFIX, DOCK_DEBUG_PANE, DOCK_FIND_RESULTS_PANE,
    DOCK_TERMINAL, DOCK_TEST_PANE, PANEL_KIND_DEBUG, PANEL_KIND_FIND_RESULTS,
    PANEL_KIND_TERMINAL, PanelSlot,
)
from turbokod.window import BottomDockedPanel, compute_display_titles
from turbokod.debug_pane import (
    PANE_ROW_BLANK, PANE_ROW_FRAME, PANE_ROW_HEADER, PANE_ROW_VARIABLE,
)
from turbokod.file_tree import FileTree
from turbokod.colors import (
    Attr, BG_TRUECOLOR, EDITOR_BG, EDITOR_FG, FG_TRUECOLOR,
)
from turbokod.string_utils import (
    byte_slice, fnv_int, fnv_start, string_from_address,
)
from turbokod.config import (
    chicago_font_label, default_font_label,
)
from turbokod.json import json_get_bool, json_get_int, json_get_string, parse_json
from turbokod.theme import theme_names
from turbokod.ui_grid import UIEvent
from turbokod.ui_tree import ui_to_json
from turbokod.search_options import SearchOptions
from turbokod.git_changes import format_age
from turbokod.diff import REGION_STABLE
from turbokod.posix import wall_clock_ms

from turbokod.host_abi import (
    ACT_CLOSE_WINDOW, ACT_NEW_WINDOW, ACT_NONE, ACT_OPEN_FILE,
    ACT_OPEN_PROJECT, ACT_QUICK_OPEN, ACT_QUIT, ACT_TOGGLE_FLOATING_PANELS,
    pack_canvas, pack_cells, shape_code,
)
from turbokod.app_menus import (
    build_menus, NEW_WINDOW, refresh_menu_visibility, TOGGLE_FLOATING_PANELS,
)


# Host action: close the current window. Returned by "Close project" when
# the host owns the menu (one-project-per-window on macOS). Mirrors
# ``desktop._HOST_CLOSE_WINDOW_ACTION``.
comptime CLOSE_WINDOW = String("app.close_window")

def _desk(h: Int) -> Pointer[Desktop, MutUntrackedOrigin]:
    return Pointer[Desktop, MutUntrackedOrigin](unsafe_from_address=h)


def _mouse_event(
    x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, click_count: UInt8,
) -> Event:
    """The ``Event`` for a host mouse callback (C booleans as ``UInt8``)."""
    return Event.mouse_event(
        Point(x, y), button, pressed != 0, motion != 0, mods, click_count,
    )


def _frame_canvas(h: Int, surface: Int, cols: Int, rows: Int) -> Canvas:
    """The blank canvas for one frame of ``surface``, a surface that can
    hold panes with a cell size of their own: the surface's canvas from
    the last frame, cleared (``Desktop.take_frame_canvas``). Hand it back
    with ``_pack_surface``."""
    return _desk(h)[].take_frame_canvas(surface, cols, rows, True)


def _chrome_canvas(h: Int, surface: Int, cols: Int, rows: Int) -> Canvas:
    """``_frame_canvas`` for a surface of its own (Settings, dialog and git
    windows) whose framework chrome the host may draw in its look."""
    return _desk(h)[].take_frame_canvas(surface, cols, rows, False)


def _pack_surface(
    h: Int, surface: Int, var canvas: Canvas, cols: Int, rows: Int,
    out_ptr: Int, cap: Int,
) -> Int:
    """Pack ``canvas``, keep its host items for ``tk_desktop_host_items``
    and the canvas itself for the surface's next frame."""
    var n = pack_canvas(canvas, cols, rows, out_ptr, cap)
    swap(_desk(h)[].host_items[surface], canvas.host_items)
    _desk(h)[].return_frame_canvas(surface, canvas^)
    return n


def _action_code(action: Optional[String]) -> Int32:
    if not action:
        return ACT_NONE
    var a = action.value()
    if a == APP_QUIT_ACTION:   return ACT_QUIT
    if a == EDITOR_OPEN:       return ACT_OPEN_FILE
    if a == EDITOR_QUICK_OPEN: return ACT_QUICK_OPEN
    if a == PROJECT_OPEN:      return ACT_OPEN_PROJECT
    if a == NEW_WINDOW:        return ACT_NEW_WINDOW
    if a == CLOSE_WINDOW:      return ACT_CLOSE_WINDOW
    if a == TOGGLE_FLOATING_PANELS: return ACT_TOGGLE_FLOATING_PANELS
    return ACT_NONE


def _canon_ctrl_key(key: UInt32, mods: UInt8) -> UInt32:
    """Fold an uppercase ASCII letter to lowercase when Ctrl or Cmd is
    held, so the Mojo core sees a canonical ``Ctrl+<lower>`` chord
    regardless of the host's shift state. Shared by every C-ABI key entry
    point (main desktop, panels, settings, project settings)."""
    if (mods & MOD_CTRL) != 0 or (mods & MOD_META) != 0:
        if key >= UInt32(0x41) and key <= UInt32(0x5A):
            return key + UInt32(0x20)
    return key


# --- C ABI ------------------------------------------------------------------


@export
def tk_recover_user_shell_path() abi("C"):
    """Recover the user's full interactive shell ``$PATH``.

    macOS Dock/launchd launches hand us a stripped ``PATH`` that lacks the
    per-user dirs the user's login shell would add (``~/.cargo/bin``,
    ``~/.pyenv/shims``, custom rc-file entries, …) — the spawn path
    forwards our ``PATH`` verbatim to children, so without this a Dock
    launch can't find ``ty-semantic`` / ``pyright`` / ``rg`` even though
    they're on the user's interactive PATH.

    The slow half of recovery is a ``$SHELL -l -i`` subprocess (~100 ms),
    so the host schedules this *off the first runloop turn* rather than
    inside ``tk_desktop_new`` — the first frame paints immediately and
    this catches up before the user can open a project and trigger a
    spawn. ``tk_desktop_new`` still does the cheap synchronous prepend of
    well-known bin dirs, so an LSP server in a standard location works
    even if a spawn somehow races this. Idempotent (once-guarded), so the
    shell is spawned at most once no matter how often the host calls it."""
    recover_path_deferred_once()


@export
def tk_desktop_new() abi("C") -> Int:
    """Create a Desktop on the heap, load config + standard menus, return the
    opaque handle."""
    # Cheap, synchronous half of GUI-launch PATH recovery: prepend the
    # well-known per-user bin dirs (just ``access(2)`` checks, sub-ms) so
    # LSP servers in standard locations resolve immediately. The slow
    # login-shell half is deferred — the host calls
    # ``tk_recover_user_shell_path`` off the first runloop turn so the
    # ~100 ms ``$SHELL -l -i`` subprocess never blocks the first frame.
    # Idempotent, so multi-window callers re-running it is harmless.
    _ = prepend_user_bin_dirs_to_path()
    var addr = external_call["malloc", Int](size_of[Desktop]())
    if addr == 0:
        return 0
    var p = Pointer[Desktop, MutUntrackedOrigin](unsafe_from_address=addr)
    p.unsafe_write(Desktop())
    p[].load_config_from_disk()
    # ``TK_THEME`` overrides the saved theme for this process only (not
    # persisted) — used to capture doc screenshots in a specific theme, e.g.
    # ``TK_THEME=Dracula TK_CAPTURE=/tmp/x.png ./run_swift.sh``.
    var tk_theme = getenv_value(String("TK_THEME"))
    if len(tk_theme.as_bytes()) > 0:
        p[].active_theme = theme_by_name(tk_theme)
        p[].theme_version += 1
    build_menus(p[], native=True)
    return addr


@export
def tk_lsp_pool_new() abi("C") -> Int:
    """Create the process-wide language-server pool (``LspPool``). The host
    makes one and hands it to every window with ``tk_desktop_set_lsp_pool``,
    so windows share a server that supports multi-root rather than each
    spawning its own. Lives for the process; 0 on allocation failure."""
    return new_pool()


@export
def tk_desktop_set_lsp_pool(h: Int, pool: Int) abi("C"):
    """Give a window the shared pool. Call before its first file opens:
    servers already running stay private."""
    if h == 0:
        return
    _desk(h)[].lsp_pool = pool


@export
def tk_spell_base_new() abi("C") -> Int:
    """Create the process-wide main spelling word set (``SpellBase``). The
    host makes one and hands it to every window with
    ``tk_desktop_set_spell_base``, so the dictionary is loaded once rather
    than once per window. Lives for the process; 0 on allocation failure."""
    return new_spell_base()


@export
def tk_desktop_set_spell_base(h: Int, base: Int) abi("C"):
    """Give a window the shared word set. Call before its first file
    opens: the speller loads its dictionary on first use."""
    if h == 0:
        return
    _desk(h)[].speller.shared = base


@export
def tk_grammar_store_new() abi("C") -> Int:
    """Create the process-wide compiled-grammar store (``GrammarStore``).
    The host makes one and hands it to every window with
    ``tk_desktop_set_grammar_store``, so a language's grammar is compiled
    once rather than once per window. Lives for the process."""
    return new_grammar_store()


@export
def tk_desktop_set_grammar_store(h: Int, store: Int) abi("C"):
    """Give a window the shared grammar store. Call before its first
    file opens."""
    if h == 0:
        return
    _desk(h)[].grammar_registry.share(store)


@export
def tk_desktop_begin_close(h: Int) abi("C"):
    """Start releasing the window's resources without waiting.

    Everything except the LSP close handshake happens now: child processes
    terminated, libonig handles released. The language servers are sent
    ``shutdown`` and left to answer.

    The host calls this the instant the window closes, then polls
    ``tk_desktop_close_poll`` off the runloop and calls ``tk_desktop_free``
    when it reports done. That is what keeps window close instant: the app
    outlives its windows anyway
    (``applicationShouldTerminateAfterLastWindowClosed`` is False), so there
    is a runloop to finish the goodbye on.

    Same precondition as ``tk_desktop_free``: the host must have zeroed its
    view handle first, because no tick or layout may follow.
    """
    if h == 0:
        return
    _desk(h)[].begin_shutdown()


@export
def tk_desktop_close_poll(h: Int) abi("C") -> Int:
    """Advance a close started by ``tk_desktop_begin_close``. Returns 1 once
    every language server has finished its handshake (or run out its grace
    budget), at which point the host calls ``tk_desktop_free``.

    Non-blocking, and safe to call at any rate: the grace budgets are
    wall-clock deadlines, so polling more often doesn't shorten them."""
    if h == 0:
        return 1
    return 1 if _desk(h)[].shutdown_poll() else 0


@export
def tk_desktop_free(h: Int) abi("C"):
    """Release the window's resources and free the handle.

    Safe to call without ``tk_desktop_begin_close`` — it runs the blocking
    teardown, which is what the Cmd+Q cascade and the headless
    ``TK_CAPTURE`` path want (there is no runloop left to drain on). After a
    ``begin_close`` + polls it is the cheap finisher, since the handshakes
    are already done.
    """
    if h == 0:
        return
    var p = _desk(h)
    # Hand back everything this window owns that Mojo's destructor can't:
    # the child processes it spawned (language servers, debug adapter, pty
    # shells, run/install children) with their pipes, and the libonig
    # handles behind its grammars and search regexes — all owned by the
    # Rust shim's registries rather than by Mojo. Without this a closed
    # window left its language servers *running* until app quit, and
    # stranded ~125 KB to 12 MB of compiled pattern set.
    #
    # Safe here because the host zeroes its view handle before calling us
    # — no tick or layout can follow, which is this call's precondition
    # anyway and exactly what ``shutdown``'s grammar release requires.
    p[].shutdown()
    p.unsafe_deinit_pointee()
    _ = external_call["free", Int](h)


@export
def tk_desktop_open_project(h: Int, path_ptr: Int, path_len: Int) abi("C"):
    if h == 0:
        return
    var path = string_from_address(path_ptr, path_len)
    if len(path.as_bytes()) == 0:
        return
    _desk(h)[].open_project(path)


@export
def tk_desktop_open_file(h: Int, path_ptr: Int, path_len: Int, cols: Int, rows: Int) abi("C"):
    if h == 0:
        return
    var path = string_from_address(path_ptr, path_len)
    if len(path.as_bytes()) == 0:
        return
    try:
        _desk(h)[].open_file(path, Rect(0, 0, cols, rows))
    except e:
        print("turbokod: tk_desktop_open_file:", String(e))


@export
def tk_desktop_open_file_at(
    h: Int, path_ptr: Int, path_len: Int, line: Int, character: Int,
    cols: Int, rows: Int,
) abi("C"):
    """Open ``path`` and place the cursor at ``(line, character)`` — both
    0-based. Backs the ``turbokod://open?file=X&line=N`` URL scheme; the
    Swift host converts the URL's 1-based line to 0-based before calling."""
    if h == 0:
        return
    var path = string_from_address(path_ptr, path_len)
    if len(path.as_bytes()) == 0:
        return
    try:
        _desk(h)[].open_file_at(path, line, character, Rect(0, 0, cols, rows))
    except e:
        print("turbokod: tk_desktop_open_file_at:", String(e))


@export
def tk_pty_wake_install(callback: Int) abi("C"):
    """Have the shim call ``callback`` (a ``void (*)(void)``, on a thread
    of the shim's own) when a pty pane's child writes — so a host with a
    run loop shows the output when it arrives rather than on its next
    timer tick. One call per ``tk_pty_wake_ack``. Before the first
    Desktop: only ptys spawned afterwards are watched."""
    _ = external_call["tk_pty_set_wake", Int32](callback)


@export
def tk_pty_wake_ack() abi("C"):
    """The host is about to tick: the next output wakes it again."""
    _ = external_call["tk_pty_ack_wake", Int32]()


@export
def tk_desktop_pty_pending(h: Int) abi("C") -> Int32:
    """1 while one of the Desktop's pty panes has output its next tick
    would read (``Desktop.pty_output_pending``) — which window a pty wake
    is for, and after a tick whether the child is outpacing it."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].pty_output_pending() else 0


@export
def tk_desktop_busy(h: Int) abi("C") -> Int32:
    """1 while the Desktop has frame-sliced work the user is waiting on
    (``Desktop.has_background_work``): a terminal host should then poll
    for input without blocking so the work runs every frame."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].has_background_work() else 0


@export
def tk_desktop_tick(h: Int, cols: Int, rows: Int) abi("C"):
    """Per-frame housekeeping Swift runs before laying out: external-change
    reload, menu visibility, file-tree opens, and the LSP/DAP/autosave
    ticks."""
    if h == 0:
        return
    var screen = Rect(0, 0, cols, rows)
    ref d = _desk(h)[]
    try:
        d.process_external_changes(screen)
    except e:
        print("turbokod: tk_desktop_tick.process_external_changes:", String(e))
    refresh_menu_visibility(d)
    # Stamp the right-aligned shortcut text on each menu item so the
    # host's menu snapshot has it. ``paint`` already does this for
    # per-window Desktops, but the always-on chrome Desktop never
    # paints — without this call its snapshot ships items with empty
    # shortcut fields and the macOS menu shows no Cmd+Q text.
    d._refresh_shortcuts()
    var tree_open = d.file_tree.consume_open()
    if tree_open:
        try:
            d.open_file(tree_open.value(), screen)
        except e:
            print("turbokod: tk_desktop_tick.open_file:", String(e))
    d.lsp_tick(screen)
    d.dap_tick(screen)
    d.terminal_tick()
    d.save_actions_tick()


@export
def tk_desktop_layout(h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """Paint the Desktop into a ``cols``x``rows`` grid and pack it into the
    caller's buffer (5 u32 per cell). Returns the number of cells written."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var canvas = _frame_canvas(h, HOST_SURFACE_MAIN, cols, rows)
    _desk(h)[].paint(canvas, Rect(0, 0, cols, rows))
    swap(_desk(h)[].sub_grids, canvas.sub_grids)
    return _pack_surface(
        h, HOST_SURFACE_MAIN, canvas^, cols, rows, out_ptr, cap,
    )


@export
def tk_editor_scroll_regions(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int
) abi("C") -> Int:
    """Report the editor windows the host may smooth-scroll this frame.
    Writes N records of 9 Int32 words each into the caller's buffer
    (``cap`` = max records): ``[win_idx, x, y, w, h, sub, frac_milli,
    n_sticky, right_gutter]`` — the window index (passed back to
    ``tk_editor_region_layout`` / ``tk_editor_smooth_*``), the editor interior
    rect in cells, the number of the top buffer line's wrapped segments
    scrolled off the top (``sub``; 0 when not wrapping), the sub-row pixel
    fraction × 1000 (signed), the count of pinned sticky-scroll header rows
    the host leaves fixed at the interior top, and the right-edge minimap
    gutter width the host leaves fixed at the interior right. The host shifts
    the overdraw render up by ``(sub + frac)`` rows, clipped between those
    fixed regions. Returns N (0 when nothing is eligible — focused window
    isn't an editor, an overlay is up, or the completion popup is open)."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0 or cap <= 0:
        return 0
    var regions = _desk(h)[].scroll_regions(Rect(0, 0, cols, rows))
    var op = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=out_ptr)
    var n = len(regions)
    if n > cap:
        n = cap
    for i in range(n):
        var r = regions[i]
        op[unsafe_offset=i * 9] = Int32(r.win_idx)
        op[unsafe_offset=i * 9 + 1] = Int32(r.interior.a.x)
        op[unsafe_offset=i * 9 + 2] = Int32(r.interior.a.y)
        op[unsafe_offset=i * 9 + 3] = Int32(r.interior.width())
        op[unsafe_offset=i * 9 + 4] = Int32(r.interior.height())
        op[unsafe_offset=i * 9 + 5] = Int32(r.sub)
        op[unsafe_offset=i * 9 + 6] = Int32(Int(r.frac * 1000.0))
        op[unsafe_offset=i * 9 + 7] = Int32(r.n_sticky)
        op[unsafe_offset=i * 9 + 8] = Int32(r.right_gutter)
    return n


@export
def tk_editor_region_layout(
    h: Int, win_idx: Int, region_cols: Int, region_rows: Int,
    out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """Render editor ``win_idx``'s body at its current ``scroll_y`` into a
    0-origin grid, ``region_rows`` visual rows tall, and pack it (same
    5-u32-per-cell format as ``tk_desktop_layout``). ``region_rows`` should
    be ``sub + interior_height + 2`` so the rows shifted off the top, the
    partially-visible bottom line, and a rubber-band edge all have content.
    The host composites this clipped to the editor interior, translated up
    by ``(sub + frac) × CELL_H``. Returns the number of cells written."""
    if h == 0 or out_ptr == 0 or region_cols <= 0 or region_rows <= 0:
        return 0
    var canvas = Canvas(region_cols, region_rows)
    _desk(h)[].paint_editor_region(
        win_idx, canvas, region_cols, region_rows, True,
    )
    return pack_canvas(canvas, region_cols, region_rows, out_ptr, cap)


@export
def tk_editor_overlay_bounds(
    h: Int, cols: Int, rows: Int, out_ptr: Int
) abi("C") -> Int:
    """Screen-cell bounds of the focused editor's active screen-anchored
    overlay — the minimap/diagnostic/spell tooltip or the LSP hover popup.
    Writes ``[x, y, w, h]`` (Int32) to ``out_ptr`` and returns 1 when one is up,
    0 otherwise. The host re-blits this rect from the main frame on top of the
    smooth-scroll body overdraw (which suppresses overlays and would otherwise
    erase the popup). Under ``host_owns_shadows`` this is the popup **box only**
    — the host paints the drop shadow as a translucent layer over the body (see
    ``tk_desktop_set_host_owns_shadows``); otherwise it includes the baked cell
    shadow (box + 2 cols right / 1 row below)."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var b = _desk(h)[].focused_overlay_bounds(Rect(0, 0, cols, rows))
    if not b:
        return 0
    var r = b.value()
    var op = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=out_ptr)
    op[unsafe_offset=0] = Int32(r.a.x)
    op[unsafe_offset=1] = Int32(r.a.y)
    op[unsafe_offset=2] = Int32(r.width())
    op[unsafe_offset=3] = Int32(r.height())
    return 1


@export
def tk_editor_smooth_begin(
    h: Int, win_idx: Int, cols: Int, rows: Int, out_ptr: Int
) abi("C") -> Int:
    """Seed a smooth-scroll gesture on editor ``win_idx``. Writes two Int32
    words to ``out_ptr``: ``[cur_vis_milli, max_vis_milli]`` — the current
    vertical position and the maximum, as continuous *visual-row*
    coordinates × 1000. The host seeds its gesture from ``cur`` and clamps
    its rubber-band against ``max``. Returns 1 on success, 0 on bad args."""
    if h == 0 or out_ptr == 0:
        return 0
    var m = _desk(h)[].smooth_begin(win_idx, Rect(0, 0, cols, rows))
    var op = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=out_ptr)
    op[unsafe_offset=0] = Int32(Int(m[0] * 1000.0))
    op[unsafe_offset=1] = Int32(Int(m[1] * 1000.0))
    return 1


@export
def tk_editor_smooth_set(
    h: Int, win_idx: Int, cols: Int, rows: Int, vis_milli: Int
) abi("C"):
    """Apply a host-driven smooth-scroll position to editor ``win_idx``: a
    global visual-row coordinate × 1000 (``vis_milli``). The core clamps the
    integer part to ``[0, max]`` and maps it to a (buffer line, sub-row)
    anchor; the fractional remainder (possibly slightly out of range during
    rubber-band) becomes the sub-row pixel fraction."""
    if h == 0:
        return
    _desk(h)[].smooth_set(
        win_idx, Rect(0, 0, cols, rows), Float64(vis_milli) / 1000.0,
    )


@export
def tk_editor_minimap_to(h: Int, win_idx: Int, frac_micro: Int) abi("C"):
    """Scroll editor ``win_idx`` proportionally from a minimap / scrollbar
    drag: ``frac_micro`` is the pointer's fractional position down the
    minimap × 1,000,000 (0 = top, 1e6 = bottom of the scrollable range). The
    host computes it from the raw sub-cell pointer Y. The unit is micro, not
    milli, so the fraction itself isn't the bottleneck: on a 10k-row file a
    milli fraction (1000 steps) would quantize to ~10-row stops, which read
    as uneven 2-row jumps when the pixel count doesn't divide evenly."""
    if h == 0:
        return
    _desk(h)[].minimap_to(win_idx, Float64(frac_micro) / 1000000.0)


@export
def tk_desktop_hscroll_by(h: Int, cols: Int, screen_cols: Int, screen_rows: Int) abi("C") -> Int:
    """Scroll the focused editor horizontally by ``cols`` columns (negative =
    left). Used by the host for a trackpad horizontal swipe / Shift+wheel.
    Returns 1 if an editor actually scrolled (so the host repaints), else 0."""
    if h == 0:
        return 0
    var moved = _desk(h)[].hscroll_focused(
        cols, Rect(0, 0, screen_cols, screen_rows),
    )
    return 1 if moved else 0


@export
def tk_desktop_vscroll_active(h: Int) abi("C") -> Int:
    """1 while a window-border vertical-scrollbar thumb drag is in progress
    (the press landed on the thumb). The host polls this right after a
    mouse-down to decide whether to route subsequent motion through the
    sub-cell ``tk_desktop_vscroll_drag`` path instead of normal mouse
    events."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].vscroll_dragging() else 0


@export
def tk_desktop_vscroll_drag(h: Int, mouse_y_milli: Int) abi("C") -> Int:
    """Continue the in-progress v-scrollbar thumb drag at a sub-cell pointer
    Y: ``mouse_y_milli`` is the pointer's fractional *cell row* × 1000 (raw
    pointer Y / cell height). Maps every line on a long file instead of the
    integer path's one-thumb-cell (~150-line) minimum. Returns 1 if a drag
    was active and consumed it, 0 otherwise."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].vscroll_drag(Float64(mouse_y_milli) / 1000.0) else 0


@export
def tk_theme_version(h: Int) abi("C") -> Int:
    """Monotonic counter that bumps whenever the active color theme changes.
    The Swift host polls this each frame and refetches the palette only when
    it moves — copying 256 ints every frame would be pointless churn."""
    if h == 0:
        return 0
    return _desk(h)[].theme_version


@export
def tk_theme_palette(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """Write the active theme's 256-entry RGB palette (packed ``0xRRGGBB``)
    into the caller's UInt32 buffer. Returns the number of entries written
    (256, clamped to ``cap``). Swift resolves cell color indices through this
    table, so this is how a theme retints the whole native UI."""
    if h == 0 or out_ptr == 0 or cap <= 0:
        return 0
    var op = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=out_ptr)
    var n = len(_desk(h)[].active_theme.palette)
    if n > cap:
        n = cap
    for i in range(n):
        op[unsafe_offset=i] = _desk(h)[].active_theme.palette[i]
    return n


@export
def tk_desktop_set_font_options(h: Int, ptr: Int, n: Int) abi("C"):
    """Register the monospace font families the host can render cells
    with — newline-separated UTF-8 family names. Their presence is what
    makes the Settings Font section appear; the terminal frontend never
    calls this. The built-in bitmap-font default row is added by the
    Mojo side, so the host passes only real system families."""
    if h == 0:
        return
    var text = string_from_address(ptr, n)
    var names = List[String]()
    var lines = split_lines_no_trailing(text)
    for i in range(len(lines)):
        if len(lines[i].as_bytes()) > 0:
            names.append(lines[i])
    _desk(h)[].host_font_names = names^


@export
def tk_desktop_set_open_projects(h: Int, ptr: Int, n: Int) abi("C"):
    """Tell this Desktop which project roots are open across the whole
    app — newline-separated, canonical (realpath'd) UTF-8 paths, one per
    host window, including this window's own.

    A Desktop is one window and can't see its siblings, so without this
    the Project menu couldn't tell "already open in another window" from
    "just a recent". The host pushes the list every frame; the Mojo side
    early-outs on an unchanged list. The terminal frontend never calls
    it (one project per process), which leaves the marker off there.
    """
    if h == 0:
        return
    var text = string_from_address(ptr, n)
    var paths = List[String]()
    var lines = split_lines_no_trailing(text)
    for i in range(len(lines)):
        if len(lines[i].as_bytes()) > 0:
            paths.append(lines[i])
    _desk(h)[].set_open_projects(paths^)


@export
def tk_font_version(h: Int) abi("C") -> Int:
    """Monotonic counter that bumps whenever ``config.font`` changes.
    The Swift host polls this each frame (like ``tk_theme_version``) and
    refetches the font name + rebuilds its cell font only when it moves."""
    if h == 0:
        return 0
    return _desk(h)[].font_version


@export
def tk_font_name(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """Write the cell font's family name (UTF-8; ``Desktop.cell_font``)
    into the caller's buffer and return the byte count. 0 means "use the
    built-in bitmap font" — the config's empty-string default, and always
    the Turbo Vision look's."""
    if h == 0 or out_ptr == 0 or cap <= 0:
        return 0
    return _write_clamped(_desk(h)[].cell_font(), out_ptr, cap)


@export
def tk_font_area_name(h: Int, slot: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """``tk_font_name`` for the font of area ``slot`` (``FONT_*`` in
    ``cell``, the slot ``pack_canvas`` puts in each cell), resolved by
    ``Desktop.area_font``. Polled with ``tk_font_name``."""
    if h == 0 or out_ptr == 0 or cap <= 0:
        return 0
    return _write_clamped(_desk(h)[].area_font(slot), out_ptr, cap)


@export
def tk_font_area_size(h: Int, slot: Int) abi("C") -> Int:
    """Area ``slot``'s own font size in points (``Desktop.area_font_size``),
    0 when it uses the cell's. Polled with ``tk_font_name``."""
    if h == 0:
        return 0
    return _desk(h)[].area_font_size(slot)


@export
def tk_desktop_set_area_scale(h: Int, slot: Int, w_milli: Int, h_milli: Int) abi("C"):
    """Area ``slot``'s cell in thousandths of the screen's cell, measured by
    the host from the area's font at ``tk_font_area_size`` (1000 x 1000
    when it has no size of its own). Panes in that area lay out a grid of
    those cells (``Canvas.place_sub_grid``)."""
    if h == 0:
        return
    _desk(h)[].set_area_scale(slot, w_milli, h_milli)


@export
def tk_desktop_set_mouse_fine(h: Int, x_milli: Int, y_milli: Int) abi("C"):
    """The pointer for the next mouse call, in thousandths of a cell, so a
    pane on a grid of another cell size can tell which of its cells it's
    over (``Event.fine``)."""
    if h == 0:
        return
    _desk(h)[].set_mouse_fine(x_milli, y_milli)


@export
def tk_desktop_sub_grid_count(h: Int, surface: Int) abi("C") -> Int:
    """How many sub-grids the last frame of ``surface`` (0 the main
    window, 1 the floating panels) placed. Cells of that frame whose word
    0 carries ``sub`` (bits 26..31) = k + 1 show sub-grid k."""
    if h == 0:
        return 0
    if surface == 1:
        return len(_desk(h)[].panel_sub_grids)
    return len(_desk(h)[].sub_grids)


@export
def tk_desktop_sub_grid_info(h: Int, surface: Int, i: Int, out_ptr: Int) abi("C") -> Int:
    """Sub-grid ``i``'s ``[slot, x, y, w, h, cols, rows]`` (Int32 words):
    its font slot, the rect it shows through in screen cells, and its own
    size in the area's cells, drawn from the rect's top-left. 1 on
    success."""
    if h == 0 or out_ptr == 0:
        return 0
    if surface == 1:
        return _sub_grid_info(_desk(h)[].panel_sub_grids, i, out_ptr)
    return _sub_grid_info(_desk(h)[].sub_grids, i, out_ptr)


def _sub_grid_info(imm grids: List[SubGrid], i: Int, out_ptr: Int) -> Int:
    if i < 0 or i >= len(grids):
        return 0
    ref g = grids[i]
    var op = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=out_ptr)
    op[unsafe_offset=0] = Int32(Int(g.slot))
    op[unsafe_offset=1] = Int32(g.rect.a.x)
    op[unsafe_offset=2] = Int32(g.rect.a.y)
    op[unsafe_offset=3] = Int32(g.rect.width())
    op[unsafe_offset=4] = Int32(g.rect.height())
    op[unsafe_offset=5] = Int32(g.cols)
    op[unsafe_offset=6] = Int32(g.rows)
    return 1


@export
def tk_desktop_sub_grid_layout(
    h: Int, surface: Int, i: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """Pack sub-grid ``i``'s cells like ``tk_desktop_layout`` does a
    frame's. Returns the number of cells written."""
    if h == 0 or out_ptr == 0:
        return 0
    if surface == 1:
        return _pack_sub_grid(_desk(h)[].panel_sub_grids, i, out_ptr, cap)
    return _pack_sub_grid(_desk(h)[].sub_grids, i, out_ptr, cap)


def _pack_sub_grid(imm grids: List[SubGrid], i: Int, out_ptr: Int, cap: Int) -> Int:
    if i < 0 or i >= len(grids):
        return 0
    ref g = grids[i]
    return pack_cells(g.cells, g.cols * g.rows, out_ptr, cap)


@export
def tk_font_size(h: Int) abi("C") -> Int:
    """The cell font's point size (``Desktop.cell_font_size``). 0 means
    "the font's default size" — the host picks 16 for the bundled bitmap
    font, 13 for other families. Polled together with ``tk_font_name``
    whenever ``tk_font_version`` moves."""
    if h == 0:
        return 0
    return _desk(h)[].cell_font_size()


@export
def tk_desktop_set_font_size_info(h: Int, effective: Int, ideal: Int) abi("C"):
    """Host reports the active font's live size info after every font
    apply: ``effective`` is the point size actually rendering (resolves
    the 0-means-default config value), ``ideal`` is the font's design
    size — 16 for the bundled bitmap font, the embedded bitmap-strike
    ppem for true bitmap fonts, 0 when unknown. Settings displays the
    effective size in its stepper and gates the "Restore ideal" button
    on the ideal."""
    if h == 0:
        return
    _desk(h)[].host_font_effective_size = effective
    _desk(h)[].host_font_ideal_size = ideal


@export
def tk_desktop_set_panels_detached(h: Int, on: Int) abi("C"):
    """Tell the Desktop its tool panels are rendered on a separate host
    window (the native "Floating panels" feature).

    When ``on`` is non-zero, the main surface (``paint`` / ``workspace_rect``
    / ``handle_event``) ignores the terminal / debug / test panels — the
    editor area reclaims the freed rows — and the host drives the second
    surface via ``tk_desktop_surface_*`` (``HOST_SURFACE_PANELS``). Also
    flips the View ▸ Floating panels checkmark. See docs/floating-panels.md."""
    if h == 0:
        return
    _desk(h)[].panels_detached = on != 0


@export
def tk_desktop_panels_visible_count(h: Int) abi("C") -> Int:
    """Number of tool panels currently open (terminal + debug + test).

    The host polls this to auto-hide the floating panel window when the last
    panel closes and re-show it when one reopens. See docs/floating-panels.md."""
    if h == 0:
        return 0
    return _desk(h)[].panels_visible_count()


@export
def tk_desktop_surface_layout(
    h: Int, surface: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """Paint one of the host's other windows — ``surface`` a
    ``HOST_SURFACE_*``: the floating panels, Settings, the dialog window or
    the git window — and pack it into the caller's buffer like
    ``tk_desktop_layout``. Returns the number of cells written. None of
    them ticks: the main window's ``tk_desktop_tick`` drives the whole
    Desktop's per-frame work."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var screen = Rect(0, 0, cols, rows)
    if surface == HOST_SURFACE_PANELS:
        var canvas = _frame_canvas(h, HOST_SURFACE_PANELS, cols, rows)
        _desk(h)[].paint_panels(canvas, screen)
        swap(_desk(h)[].panel_sub_grids, canvas.sub_grids)
        return _pack_surface(
            h, HOST_SURFACE_PANELS, canvas^, cols, rows, out_ptr, cap,
        )
    if surface != HOST_SURFACE_SETTINGS and surface != HOST_SURFACE_DIALOG \
            and surface != HOST_SURFACE_GIT:
        return 0
    var canvas = _chrome_canvas(h, surface, cols, rows)
    if surface == HOST_SURFACE_SETTINGS:
        _desk(h)[].paint_settings(canvas, screen)
    elif surface == HOST_SURFACE_DIALOG:
        _desk(h)[].paint_dialog_window(canvas, screen)
    else:
        _desk(h)[].paint_git_window(canvas, screen)
    return _pack_surface(h, surface, canvas^, cols, rows, out_ptr, cap)


def _surface_event(h: Int, surface: Int, var ev: Event, cols: Int, rows: Int) -> Int32:
    """Route ``ev`` to the window ``surface``; the host action it makes
    (only the main, panels and dialog windows make one)."""
    var screen = Rect(0, 0, cols, rows)
    var action = Optional[String]()
    try:
        if surface == HOST_SURFACE_MAIN:
            if ev.kind == EVENT_MOUSE:
                _desk(h)[].take_mouse_fine(ev)
            action = _desk(h)[].handle_event(ev, screen)
        elif surface == HOST_SURFACE_PANELS:
            _desk(h)[].take_mouse_fine(ev)
            action = _desk(h)[].handle_panels_event(ev, screen)
        elif surface == HOST_SURFACE_SETTINGS:
            _desk(h)[].handle_settings_event(ev, screen)
        elif surface == HOST_SURFACE_DIALOG:
            action = _desk(h)[].handle_dialog_window_event(ev, screen)
        elif surface == HOST_SURFACE_GIT:
            _desk(h)[].handle_git_window_event(ev, screen)
    except e:
        print("turbokod: surface", surface, "event:", String(e))
    return _action_code(action)


@export
def tk_desktop_surface_key(
    h: Int, surface: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int,
) abi("C") -> Int32:
    """A keystroke in the window ``surface`` (see
    ``tk_desktop_surface_layout``), with ``tk_desktop_key``'s Ctrl/Cmd
    canonicalization."""
    if h == 0:
        return ACT_NONE
    return _surface_event(
        h, surface, Event.key_event(_canon_ctrl_key(key, mods), mods),
        cols, rows,
    )


@export
def tk_desktop_surface_mouse(
    h: Int, surface: Int, x: Int, y: Int, button: UInt8, pressed: UInt8,
    motion: UInt8, mods: UInt8, cols: Int, rows: Int, click_count: UInt8,
) abi("C") -> Int32:
    """A mouse event in the window ``surface``."""
    if h == 0:
        return ACT_NONE
    return _surface_event(
        h, surface, _mouse_event(x, y, button, pressed, motion, mods, click_count),
        cols, rows,
    )








# --- Settings window surface -------------------------------------------------
#
# The macOS host renders Settings in its own native window (like the floating
# panels): the main surface skips the in-grid overlay and stays interactive —
# which is what makes the live theme preview useful — while the host drives
# this surface. The host polls ``tk_desktop_settings_active`` each tick and
# opens/closes the NSWindow on transitions.


@export
def tk_desktop_set_settings_detached(h: Int, on: Int) abi("C"):
    """Tell the Desktop the Settings view is rendered on a separate host
    window. The terminal frontend never sets this — there Settings is a
    movable/resizable in-grid dialog."""
    if h == 0:
        return
    _desk(h)[].set_settings_detached(on != 0)


@export
def tk_desktop_settings_active(h: Int) abi("C") -> Int32:
    """1 while the Settings view is open. The host polls this per tick and
    shows/hides its settings window on transitions (the Mojo side opens via
    the menu action and closes via Esc / the Close button, so the host can't
    know without asking)."""
    if h == 0:
        return Int32(0)
    # The native Settings window (macOS-style UI) stands in for this one.
    if _desk(h)[].settings.active and not _desk(h)[].settings_native():
        return Int32(1)
    return Int32(0)


@export
def tk_desktop_take_attention(h: Int) abi("C") -> Int32:
    """Drain and return the count of attention events (a Claude session
    in a terminal pane finishing its turn, the debugger hitting a stop)
    since the last call. The host polls this every tick and, when the
    app isn't frontmost, bounces the Dock icon and adds the count to
    the badge number. Draining while frontmost discards the events —
    the user is already looking."""
    if h == 0:
        return Int32(0)
    return Int32(_desk(h)[].take_attention_events())


@export
def tk_desktop_attention_unseen(h: Int) abi("C") -> Int32:
    """Pings this Desktop raised that the user hasn't seen yet — summed
    over the project windows, the Dock badge. A ping stays unseen until
    the host calls ``tk_desktop_attention_seen``."""
    if h == 0:
        return Int32(0)
    return Int32(_desk(h)[].attention_unseen())


@export
def tk_desktop_attention_seen(h: Int, flash: Int) abi("C"):
    """The user is looking at this Desktop's window (its main or floating-
    panels window is key in the active app). ``flash=1`` when they just
    switched to it: each pane a ping came from gets an outline that fades
    out over a second (``tk_desktop_attention_flashes``)."""
    if h == 0:
        return
    _desk(h)[].mark_attention_seen(flash != 0)


@export
def tk_desktop_attention_flashes(
    h: Int, panels: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The attention outlines the host draws (macOS and Mac OS 9 looks; the
    core paints them in cells otherwise) on the main window (``panels=0``)
    or the floating-panels window: an array of ``{kind, idx, x, y, w, h,
    age}`` in cells, ``age`` ms into the ``ATTENTION_FLASH_MS`` fade (an
    age lower than last time is a fresh flash of the same pane). 0 when
    none is showing."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.host_pane_headers():
        return 0
    var flashes = d.attention_flashes(Rect(0, 0, cols, rows), panels != 0)
    if len(flashes) == 0:
        return 0
    var a = json_array()
    for ref f in flashes:
        var o = json_object()
        o.put(String("kind"), json_int(f.kind))
        o.put(String("idx"), json_int(f.idx))
        _put_rect(o, f.rect)
        o.put(String("age"), json_int(f.age_ms))
        a.append(o)
    return _write_out(encode_json(a), out_ptr, cap)


@export
def tk_desktop_focus(h: Int, on: Int, cols: Int, rows: Int) abi("C"):
    """The terminal's focus-in / focus-out report (``CSI I`` / ``CSI O``),
    from ``tk-tui``: the same ``EVENT_FOCUS_*`` the standalone terminal
    build feeds ``handle_event`` (autosave on focus-out, forwarding to
    the terminal panes, seeing pings on focus-in)."""
    if h == 0:
        return
    try:
        _ = _desk(h)[].handle_event(
            Event.focus_event(on != 0), Rect(0, 0, cols, rows),
        )
    except e:
        print("turbokod: tk_desktop_focus:", String(e))


comptime _REQ_PANEL_FOCUS = 1
comptime _REQ_PANEL_FRONT = 2
comptime _REQ_MAIN_FOCUS = 4
comptime _REQ_GIT_FRONT = 8


@export
def tk_desktop_take_window_requests(h: Int, mask: Int) abi("C") -> Int32:
    """Drain the one-shot window requests in ``mask``.

    Returns the bits that were set. Each fires once and clears whether
    or not the host acts on it (docked panels have no window to raise),
    so it can't fire stale later. The bits:

    - 1: make the floating panel window key — the user opened a terminal
      pane, and the shell should be typeable without a click.
    - 2: ``orderFront`` the floating panel window, *without* ``makeKey``
      — a target run / test / debug (re)started, and its output should
      surface even when buried while keyboard focus stays in the editor.
    - 4: ``makeKeyAndOrderFront`` the main window — a deliberate
      open-at-line jump (an output-pane link click or a ``turbokod://``
      open) mustn't leave the code behind the panels.
    - 8: bring the git window forward (Git ▸ Local changes while it's up).
    """
    if h == 0:
        return Int32(0)
    ref d = _desk(h)[]
    var out = 0
    if (mask & _REQ_PANEL_FOCUS) != 0 and d.consume_panel_focus_request():
        out |= _REQ_PANEL_FOCUS
    if (mask & _REQ_PANEL_FRONT) != 0 and d.consume_panel_front_request():
        out |= _REQ_PANEL_FRONT
    if (mask & _REQ_MAIN_FOCUS) != 0 and d.consume_main_focus_request():
        out |= _REQ_MAIN_FOCUS
    if (mask & _REQ_GIT_FRONT) != 0 and d.consume_git_front_request():
        out |= _REQ_GIT_FRONT
    return Int32(out)


@export
def tk_desktop_debug_stopped(h: Int) abi("C") -> Int32:
    """1 while a DAP session is active and paused (stopped event received,
    not yet resumed). Backs ``TK_CAPTURE_WHEN=debug-stopped`` — the host's
    scripted-screenshot path polls this to know the debugger has actually
    hit its breakpoint before grabbing the frame (see scripts/screenshots.sh)."""
    if h == 0:
        return Int32(0)
    if _desk(h)[].dap.is_stopped():
        return Int32(1)
    return Int32(0)


@export
def tk_desktop_settings_close(h: Int) abi("C"):
    """Close the Settings view — the host calls this when the user closes
    the settings window via its native close button (the reverse direction
    of ``tk_desktop_settings_active``)."""
    if h == 0:
        return
    _desk(h)[].close_settings()


@export
def tk_desktop_key(h: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int) abi("C") -> Int32:
    """``tk_desktop_surface_key`` on the main surface (tk-tui's entry)."""
    return tk_desktop_surface_key(h, HOST_SURFACE_MAIN, key, mods, cols, rows)


@export
def tk_desktop_mod_key(h: Int, mod_id: UInt32, pressed: UInt8) abi("C") -> Int32:
    """Bare modifier-key transition (press/release of a lone modifier,
    e.g. Option/Alt) from the AppKit host's ``flagsChanged``. The
    terminal frontend synthesizes these from ``CSI ... z`` sequences;
    the native host has to report them explicitly. Drives the editor's
    Alt-tap (selection⇄column toggle) and tap-then-hold (column-draw)
    gestures. ``mod_id`` is one of the ``MOD_KEY_*`` constants. The
    Desktop routes this straight to the focused editor and ignores the
    screen rect, so we pass an empty one."""
    if h == 0:
        return ACT_NONE
    return _surface_event(
        h, HOST_SURFACE_MAIN, Event.mod_key_event(mod_id, pressed != 0), 0, 0,
    )


@export
def tk_desktop_mouse(
    h: Int, x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, cols: Int, rows: Int, click_count: UInt8,
) abi("C") -> Int32:
    """``tk_desktop_surface_mouse`` on the main surface."""
    return tk_desktop_surface_mouse(
        h, HOST_SURFACE_MAIN, x, y, button, pressed, motion, mods, cols, rows,
        click_count,
    )


@export
def tk_desktop_pointer_shape(h: Int, x: Int, y: Int, cols: Int, rows: Int) abi("C") -> Int32:
    """``tk_desktop_surface_pointer_shape`` on the main surface (tk-tui's
    entry)."""
    return tk_desktop_surface_pointer_shape(h, HOST_SURFACE_MAIN, x, y, cols, rows)


@export
def tk_desktop_surface_pointer_shape(
    h: Int, surface: Int, x: Int, y: Int, cols: Int, rows: Int,
) abi("C") -> Int32:
    """A ``host_abi.SHAPE_*`` code for the pointer at ``(x, y)`` on the main
    surface, the floating panels or the git window; the default arrow
    elsewhere."""
    if h == 0:
        return Int32(0)
    var pos = Point(x, y)
    var screen = Rect(0, 0, cols, rows)
    if surface == HOST_SURFACE_MAIN:
        return shape_code(_desk(h)[].pointer_shape_at(pos, screen))
    if surface == HOST_SURFACE_PANELS:
        return shape_code(_desk(h)[].pointer_shape_panels(pos, screen))
    if surface == HOST_SURFACE_GIT and _desk(h)[].local_changes.active:
        return shape_code(_desk(h)[].local_changes.pointer_shape(pos))
    return Int32(0)


@export
def tk_desktop_surface_drop_paths(
    h: Int, surface: Int, x: Int, y: Int, paths_ptr: Int, paths_len: Int,
    cols: Int, rows: Int,
) abi("C") -> Int32:
    """Host drag-and-drop of files onto the main surface or the floating
    panels. ``paths`` is a newline-separated list of absolute paths. If a
    terminal pane sits under cell ``(x, y)``, they're shell-escaped,
    space-joined (``escape_drop_paths``) and injected as a bracketed paste —
    so a shell or Claude session there receives them exactly as a terminal
    emulator's drag-to-insert would. 1 when a pane consumed the drop, else 0
    (the host then leaves the OS drag unhandled)."""
    if h == 0 or (surface != HOST_SURFACE_MAIN and surface != HOST_SURFACE_PANELS):
        return Int32(0)
    var text = escape_drop_paths(string_from_address(paths_ptr, paths_len))
    if len(text.as_bytes()) == 0:
        return Int32(0)
    var pos = Point(x, y)
    var screen = Rect(0, 0, cols, rows)
    var done = _desk(h)[].drop_text_on_pane(text, pos, screen) \
        if surface == HOST_SURFACE_MAIN \
        else _desk(h)[].drop_text_on_panel(text, pos, screen)
    return Int32(1) if done else Int32(0)


@export
def tk_desktop_surface_drop_target(
    h: Int, surface: Int, x: Int, y: Int, cols: Int, rows: Int,
) abi("C") -> Int32:
    """Classify a drag-and-drop landing at cell ``(x, y)``: 1 = terminal
    pane, 2 = editor body (main surface only), 0 = nothing droppable. The
    host polls it during the drag (the copy / no-drop cursor) and on drop
    (terminal paste vs the editor's format-choice menu)."""
    if h == 0:
        return Int32(0)
    var pos = Point(x, y)
    var screen = Rect(0, 0, cols, rows)
    if surface == HOST_SURFACE_MAIN:
        return Int32(_desk(h)[].drop_target_at(pos, screen))
    if surface == HOST_SURFACE_PANELS:
        return Int32(_desk(h)[].drop_target_panel_at(pos, screen))
    return Int32(0)






@export
def tk_desktop_insert_text(
    h: Int, x: Int, y: Int, text_ptr: Int, text_len: Int, cols: Int, rows: Int,
) abi("C") -> Int32:
    """Insert ``text`` verbatim into the editor window under cell ``(x, y)``,
    placing the caret at the drop point first. Backs the editor branch of
    drag-and-drop: the host has already formatted the dropped path (full path /
    filename / project-relative) per the menu choice, so no escaping happens
    here. Returns 1 when an editor consumed it, else 0."""
    if h == 0:
        return Int32(0)
    var text = string_from_address(text_ptr, text_len)
    if len(text.as_bytes()) == 0:
        return Int32(0)
    try:
        if _desk(h)[].drop_text_on_editor(text, Point(x, y), Rect(0, 0, cols, rows)):
            return Int32(1)
    except e:
        print("turbokod: tk_desktop_insert_text:", String(e))
    return Int32(0)


@export
def tk_desktop_paste_target_is_editor(h: Int) abi("C") -> Int32:
    """1 when a paste should go to an editor (an editor window is focused and
    no terminal pane / file tree has keyboard focus). The host checks this
    before offering the file-path paste menu — see ``tk_desktop_paste_text``."""
    if h == 0:
        return Int32(0)
    return Int32(1) if _desk(h)[].paste_target_is_editor() else Int32(0)


@export
def tk_desktop_paste_text(h: Int, text_ptr: Int, text_len: Int) abi("C") -> Int32:
    """Insert ``text`` verbatim at the focused editor's caret. Backs the
    file-path paste menu (Cmd+V of a file copied in Finder): the host has
    formatted the path per the menu choice, like the editor drop branch but at
    the current cursor rather than a drop point. Returns 1 when handled."""
    if h == 0:
        return Int32(0)
    var text = string_from_address(text_ptr, text_len)
    if len(text.as_bytes()) == 0:
        return Int32(0)
    try:
        if _desk(h)[].insert_text_focused_editor(text):
            return Int32(1)
    except e:
        print("turbokod: tk_desktop_paste_text:", String(e))
    return Int32(0)


@export
def tk_desktop_paste_clipboard_text(h: Int, text_ptr: Int, text_len: Int) abi("C") -> Int32:
    """Paste ``text`` into whatever owns keyboard focus — the host-driven
    counterpart to the in-core ``Cmd+V`` (``EDITOR_PASTE``) path. The Swift host
    reads the system pasteboard and Unicode-normalizes it to NFC before calling
    this, because macOS routinely hands out decomposed text (e.g. ``a`` + U+030A
    combining ring for ``å``); the bitmap font has no glyph for a lone combining
    mark, so an unnormalized paste renders as ``?``. Routes through the same
    focus logic as ``EDITOR_PASTE`` (terminal pane first, then editor, with
    line-clipboard handling). Returns 1 when something consumed the paste."""
    if h == 0:
        return Int32(0)
    var text = string_from_address(text_ptr, text_len)
    return Int32(1) if _desk(h)[].paste_text_into_focus(text) else Int32(0)


@export
def tk_desktop_set_host_owns_menu(h: Int, on: Int) abi("C"):
    """Tell the Desktop a host frontend owns the menu surface.

    When ``on`` is non-zero, Desktop stops painting the in-grid menu bar
    and stops routing top-row mouse / Alt-letter mnemonic / Esc-prefix
    key events to it. The host is expected to mirror ``menu_bar`` into a
    native menu (via ``tk_desktop_menu_snapshot``) and dispatch picks
    via ``tk_desktop_menu_invoke``. Idempotent; call once after
    ``tk_desktop_new``.
    """
    if h == 0:
        return
    _desk(h)[].host_owns_menu = on != 0


@export
def tk_desktop_set_host_owns_shadows(h: Int, on: Int) abi("C"):
    """Tell the Desktop a host frontend draws the editor body popups' drop
    shadows itself, as a real translucent layer over the live (smooth-scrolled)
    text. When ``on`` is non-zero the core stops baking the cell-darkening
    shadow under the minimap tooltip / LSP hover popup, and
    ``tk_editor_overlay_bounds`` reports the popup *box only* (no shadow strips)
    so the host can re-blit the box and paint the shadow over the body beneath
    it. Without it the baked shadow tears away from the body during a sub-cell
    smooth-scroll gesture. Idempotent; call once after ``tk_desktop_new``.
    """
    if h == 0:
        return
    _desk(h)[].host_owns_shadows = on != 0


@export
def tk_desktop_set_panels_focused(h: Int, on: Int) abi("C"):
    """Tell the Desktop whether its floating panels' window is the key
    window, per frame like ``tk_desktop_set_host_focused``: the window's
    Turbo Vision frame is drawn with double lines while it is."""
    if h == 0:
        return
    _desk(h)[].panels_host_focused = on != 0


@export
def tk_desktop_set_host_focused(h: Int, on: Int) abi("C"):
    """Tell the Desktop whether its host window currently owns the OS
    keyboard focus (is the key window).

    Each open project runs its own Desktop in its own native window; the
    caret should only blink in the key window. The host calls this
    per-frame for every view with ``on=1`` for the key window and ``0``
    for the rest, so background projects show a steady (non-blinking)
    caret. Defaults to focused, so the terminal frontend (single window)
    need not call it.
    """
    if h == 0:
        return
    _desk(h)[].host_focused = on != 0


@export
def tk_desktop_refresh_git(h: Int) abi("C"):
    """Force a git-state refresh: invalidate every editor's cached HEAD
    baseline so the change gutter re-diffs on the next paint, regardless of
    the cheap 1 Hz mtime poll. The host calls this on focus-gain (Cmd+Tab
    back) — the user may have run git operations or edited files in another
    app while we were backgrounded, and a worktree-only change doesn't move
    the ``.git/HEAD``/``.git/index`` mtimes the poll watches."""
    if h == 0:
        return
    _desk(h)[].force_git_refresh()


def _snap_field(mut buf: List[UInt8], text: String):
    """One TAB-led field of a ``tk_desktop_menu_snapshot`` record."""
    buf.append(UInt8(0x09))
    buf.extend(text.as_bytes())


def _snap_flag(mut buf: List[UInt8], v: Bool):
    """A boolean field, ``0`` / ``1``."""
    buf.append(UInt8(0x09))
    buf.append(UInt8(0x31) if v else UInt8(0x30))


@export
def tk_desktop_menu_snapshot(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """Serialize the current ``menu_bar`` into a flat TSV-shaped buffer.

    The host re-reads this every tick and rebuilds its native menu when
    the content changes (the cheap detection is a hash over the buffer).
    Format is one record per line, fields TAB-separated, all ASCII-safe:

      ``M\\t<label>\\t<visible>\\t<is_system>\\t<right_aligned>\\n``
      ``I\\t<label>\\t<action>\\t<is_separator>\\t<checkable>\\t<checked>\\t<shortcut>\\t<mark>\\t<icon>\\n``

    Booleans render as ``0``/``1``; ``mark`` is the decimal
    ``MENU_MARK_*`` code (0 = none) for the alternate glyph in the check
    column; ``icon`` is an SF Symbol name or empty; missing strings render
    as empty fields. Items belong to the
    most-recently-emitted M record. Returns
    the length; one larger than ``cap`` means nothing was written and
    the host should grow its buffer and retry (``_write_bytes``).
    """
    if h == 0:
        return 0
    ref bar = _desk(h)[].menu_bar
    # Bytes, appended once: the host polls this every tick, and
    # ``text = text + …`` recopied the whole snapshot per field, on top of
    # a deep copy of each menu.
    var buf = List[UInt8]()
    # Emit visible menus in painted left-to-right order — same rank-sorted
    # sequence the terminal frontend's MenuBar uses (system first, then
    # rank-ordered left-aligned, then right-aligned at the end). The host
    # appends them to NSMenu in this order, which puts e.g. Window second-
    # to-last (rank 90) and the project menu rightmost (right_aligned).
    var order = bar._display_order_indices()
    for k in range(len(order)):
        ref m = bar.menus[order[k]]
        buf.append(UInt8(0x4D))  # 'M'
        _snap_field(buf, m.label)
        _snap_flag(buf, m.visible)
        _snap_flag(buf, m.is_system)
        _snap_flag(buf, m.right_aligned)
        buf.append(UInt8(0x0A))
        for ii in range(len(m.items)):
            ref it = m.items[ii]
            buf.append(UInt8(0x49))  # 'I'
            _snap_field(buf, it.label)
            _snap_field(buf, it.action)
            _snap_flag(buf, it.is_separator)
            _snap_flag(buf, it.checkable)
            _snap_flag(buf, it.checked)
            _snap_field(buf, it.shortcut)
            _snap_field(buf, String(Int(it.mark)))
            _snap_field(buf, it.icon)
            buf.append(UInt8(0x0A))
    return _write_bytes(Span(buf), out_ptr, cap)


@export
def tk_desktop_menu_invoke(
    h: Int, action_ptr: Int, action_len: Int, cols: Int, rows: Int,
) abi("C") -> Int32:
    """Run the menu action identified by its action string.

    Mirrors what ``MenuBar.handle_event`` would have produced when the
    user clicked the item in the in-grid menu: routes through
    ``Desktop.dispatch_action`` and returns the host action code that
    ``handle_event``'s Swift caller already understands (see
    ``_action_code``). 0 means the action ran entirely inside the
    Desktop (no host follow-up needed).
    """
    if h == 0:
        return ACT_NONE
    var action = string_from_address(action_ptr, action_len)
    if len(action.as_bytes()) == 0:
        return ACT_NONE
    var result = _desk(h)[].dispatch_action(action, Rect(0, 0, cols, rows))
    # ``dispatch_action`` returns the *unhandled* action string back to
    # the host (so it can route framework-level actions like Quit / Open
    # via its own UI). Map that the same way handle_event does.
    return _action_code(result)


# --- macOS-style UI: native dialogs ---------------------------------------


def _native_dialog_json(ref d: Desktop) -> String:
    """The dialog the host should be showing natively, as JSON, or empty."""
    if not d.native_dialog_active():
        return String("")
    var o = json_object()
    if d.confirm_dialog.active:
        o.put(String("kind"), json_str(String("confirm")))
        o.put(String("message"), json_str(d.confirm_dialog.message))
        o.put(String("buttons"), json_string_array(d.confirm_dialog.labels))
        o.put(String("default"), json_int(d.confirm_dialog.default_index))
        o.put(
            String("destructive"),
            json_int(d.confirm_dialog.destructive_index()),
        )
    elif d.color_picker.active:
        o.put(String("kind"), json_str(String("color")))
        o.put(String("rgb"), json_int(d.color_picker.current_rgb_packed()))
        o.put(String("mode"), json_int(d.color_picker.mode))
    elif d.message_request_dialog.active:
        o.put(String("kind"), json_str(String("choice")))
        o.put(String("message"), json_str(d.message_request_dialog.message))
        o.put(
            String("actions"),
            json_string_array(d.message_request_dialog.actions),
        )
    elif d.native_prompt_active():
        o.put(String("kind"), json_str(String("prompt")))
        o.put(String("label"), json_str(d.prompt.label))
        o.put(String("text"), json_str(d.prompt.input.text))
        o.put(String("action"), json_str(d.native_prompt_action()))
    else:
        o.put(String("kind"), json_str(String("save_as")))
        o.put(String("dir"), json_str(d.save_as_dialog.browser.dir))
        o.put(String("name"), json_str(d.save_as_dialog.filename.text))
    return encode_json(o)


@export
def tk_desktop_native_dialog(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """Describe the dialog the host should show as a native sheet (the
    macOS-style UI), as UTF-8 JSON with a ``kind`` of ``confirm`` /
    ``prompt`` / ``save_as``. Returns the byte length: 0 when no such
    dialog is up, and a length larger than ``cap`` (nothing written) when
    the buffer is too small, so the host can grow it and retry."""
    if h == 0:
        return 0
    return _write_out(_native_dialog_json(_desk(h)[]), out_ptr, cap)


@export
def tk_desktop_native_dialog_up(h: Int) abi("C") -> Int32:
    """1 when ``tk_desktop_native_dialog`` has a dialog to describe — the
    question without building its JSON."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].native_dialog_active() else 0


def _copy_out(bytes: Span[UInt8, _], n: Int, out_ptr: Int):
    """The first ``n`` of ``bytes`` into the host's buffer at ``out_ptr``."""
    if n <= 0 or out_ptr == 0:
        return
    unsafe_memcpy(
        dest=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=out_ptr),
        src=bytes.unsafe_ptr(),
        count=n,
    )


def _write_clamped(text: String, out_ptr: Int, cap: Int) -> Int:
    """Copy as much of ``text`` as fits into the host's ``cap``-byte buffer
    and return how many bytes that was — for short values (a font name)
    the host reads into a fixed buffer without a retry."""
    var bytes = text.as_bytes()
    var n = min(len(bytes), cap)
    _copy_out(bytes, n, out_ptr)
    return max(n, 0)


def _write_bytes(bytes: Span[UInt8, _], out_ptr: Int, cap: Int) -> Int:
    """Copy ``bytes`` into the host's buffer. Returns their length; a
    length larger than ``cap`` means nothing was written and the host
    should grow the buffer and retry (Swift's ``readCoreData``)."""
    var n = len(bytes)
    if n == 0 or n > cap or out_ptr == 0:
        return n
    _copy_out(bytes, n, out_ptr)
    return n


def _write_out(text: String, out_ptr: Int, cap: Int) -> Int:
    """``_write_bytes`` for a string: the buffer contract every
    JSON-returning call shares."""
    return _write_bytes(text.as_bytes(), out_ptr, cap)


def _json_span(a: Int, b: Int) -> JsonValue:
    """``[a, b]``: a span of cells as the host reads it."""
    var r = json_array()
    r.append(json_int(a))
    r.append(json_int(b))
    return r^


@export
def tk_desktop_native_ui(h: Int) abi("C") -> Int32:
    """1 while the macOS-style UI is on for this window's Desktop — the
    host shows its native tab strip only then."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].native_ui() else 0


@export
def tk_desktop_platinum_ui(h: Int) abi("C") -> Int32:
    """1 while the Mac OS 9 look is on for this window's Desktop — the host
    then draws the declarative dialogs, the confirms, the window chrome,
    the tab strip and the editor's scroll bar Platinum-style."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].platinum_ui() else 0


@export
def tk_desktop_tv_frame(h: Int) abi("C") -> Int32:
    """1 while this window's Desktop wants the Turbo Vision project frame
    (``Desktop.tv_frame``): the host makes the window borderless and lays
    the grid inside a ``tk_desktop_layout_frame`` ring."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].tv_frame() else 0


@export
def tk_desktop_dialog_window(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The Turbo Vision look's dialog window (``Desktop.dialog_window``):
    the git view or a declarative dialog in a borderless window of its own,
    as JSON ``{"kind", "title", "cols", "rows", "resizable"}`` — its size
    in cells for a ``cols`` × ``rows`` project window. Nothing (0) while
    there's none. Same buffer contract as ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    var kind = d.dialog_window()
    if len(kind.as_bytes()) == 0:
        return 0
    var size = d.dialog_window_size(Rect(0, 0, cols, rows))
    var o = json_object()
    o.put(String("kind"), json_str(kind))
    o.put(String("title"), json_str(d.dialog_window_title()))
    o.put(String("cols"), json_int(size[0]))
    o.put(String("rows"), json_int(size[1]))
    o.put(String("resizable"), json_bool(size[2]))
    return _write_out(encode_json(o), out_ptr, cap)


# --- the git view's window -----------------------------------------------------
#
# In the native app the git view is a non-modal window of its own. The macOS
# and Mac OS 9 looks draw it from ``tk_desktop_git``; the Turbo Vision look's
# is a borderless cell window the core paints, frame and all.


@export
def tk_desktop_git_window(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The Turbo Vision look's git window (``Desktop.git_window``) as JSON
    ``{"title"}``; nothing (0) while it isn't up. Same buffer contract as
    ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.git_window():
        return 0
    var o = json_object()
    o.put(String("title"), json_str(d.git_window_title()))
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_set_key_surface(h: Int, surface: Int) abi("C"):
    """Which of the project's surfaces has the key window:
    ``HOST_SURFACE_MAIN``, ``HOST_SURFACE_PANELS``, or -1 for anything
    else (one of its dialog windows). The host reports it before
    dispatching an Edit-menu action, so a dialog open in a window of its
    own (Find / Replace, Settings) only takes Paste / Undo / … typed
    there, and a menu-bar chord replayed into the core reaches the
    focused tool pane in the floating panels."""
    if h == 0:
        return
    _desk(h)[].project_window_key = surface == HOST_SURFACE_MAIN \
        or surface == HOST_SURFACE_PANELS
    _desk(h)[].panels_window_key = surface == HOST_SURFACE_PANELS


@export
def tk_desktop_set_git_window_key(h: Int, on: Int) abi("C"):
    """Whether the git window (any look) is the key window."""
    if h == 0:
        return
    _desk(h)[].set_git_window_key(on != 0)


@export
def tk_desktop_set_git_docked(h: Int, on: Int) abi("C"):
    """Whether the git window is docked over the project window rather
    than floating: the Turbo Vision look's dock box shows it."""
    if h == 0:
        return
    _desk(h)[].git_window_docked = on != 0


@export
def tk_desktop_layout_frame(
    h: Int, cols: Int, rows: Int, zoomed: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """Paint the project frame on the window's whole ``cols``x``rows`` grid
    (``Desktop.paint_frame``) and pack it like ``tk_desktop_layout``. Only
    the ring is meant to show; the Desktop's grid covers the rest."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var canvas = Canvas(cols, rows)
    _desk(h)[].paint_frame(canvas, Rect(0, 0, cols, rows), zoomed != 0)
    return pack_canvas(canvas, cols, rows, out_ptr, cap)


@export
def tk_desktop_frame_info(h: Int, cols: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The project frame's title row for a ``cols``-wide window, as JSON:
    ``{"path", "icon", "title": [a, b]}`` — the proxy icon's file (empty:
    none), the first of its two cells (-1: not painted) and the title's
    cell span. Same buffer contract as ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    var span = d.frame_title_span(cols)
    var o = json_object()
    o.put(String("path"), json_str(d.frame_path()))
    o.put(String("icon"), json_int(span[0]))
    o.put(String("title"), _json_span(span[1], span[2]))
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_tabs(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The windows as tabs for the host's native tab strip, as JSON:
    ``{"focused": i, "tabs": [{"title", "path", "dirty"}, …]}`` in window
    index order (the index ``tk_desktop_tab_select`` / ``_close`` take).
    ``dirty`` means unsaved. Same buffer contract as
    ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    # Review hosts its changeset in a transient window that mustn't be a
    # tab (focusing another tab would suspend the review): no strip.
    if d.review.active:
        return 0
    var titles = compute_display_titles(d.windows.windows)
    var tabs = json_array()
    for i in range(len(d.windows.windows)):
        ref w = d.windows.windows[i]
        var t = json_object()
        t.put(String("title"), json_str(titles[i]))
        t.put(
            String("path"),
            json_str(w.editor.file_path if w.is_editor else String("")),
        )
        t.put(String("dirty"), json_bool(w.is_editor and w.editor.dirty))
        tabs.append(t)
    var o = json_object()
    o.put(String("focused"), json_int(d.windows.focused))
    o.put(String("tabs"), tabs)
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_status_layout(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """Where the last paint put the status bar's parts, in cell columns
    on the bottom row, so the host can redraw them as controls without
    moving a click target: ``{"git": [a, b], "message": [a, b],
    "targets": [[a, b, active], …]}``, each span ``[a, b)``, empty when
    nothing was painted. 0 while a full-screen modal covers the bar."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if d._fullscreen_modal_active():
        return 0
    ref sb = d.status_bar
    var targets = json_array()
    for i in range(len(sb._tab_hits)):
        ref t = sb._tab_hits[i]
        var r = json_array()
        r.append(json_int(t.a_x))
        r.append(json_int(t.b_x))
        r.append(json_bool(t.index == sb.active_tab))
        targets.append(r)
    var git = _json_span(sb._git_a_x, sb._git_b_x)
    var msg = _json_span(sb._msg_a_x, sb._msg_b_x)
    var o = json_object()
    o.put(String("git"), git)
    o.put(String("message"), msg)
    o.put(String("targets"), targets)
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_tab_select(
    h: Int, idx: Int, cols: Int, rows: Int,
) abi("C") -> Int32:
    """Focus window ``idx`` (a click on its tab)."""
    if h == 0:
        return ACT_NONE
    return _action_code(_desk(h)[].dispatch_action(
        WINDOW_FOCUS_PREFIX + String(idx), Rect(0, 0, cols, rows),
    ))


@export
def tk_desktop_tab_close(h: Int, idx: Int) abi("C"):
    """Close window ``idx`` (its tab's close button); unsaved work raises
    the usual Cancel / Delete / Save question first."""
    if h == 0:
        return
    _desk(h)[].close_tab(idx)


# --- macOS-style UI: merge (file changed on disk under unsaved edits) --------


@export
def tk_desktop_merge(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The merge view for the native sheet: ``{file, current, conflicts:
    [{ours, theirs, before, after, choice, edited}]}`` — line lists, with
    up to three agreed lines of context either side. 0 when it isn't up
    natively."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.native_merge_active():
        return 0
    ref m = d.merge_view
    var o = json_object()
    o.put(String("file"), json_str(m.file_path))
    o.put(String("current"), json_int(m.current))
    var cs = json_array()
    var ci = 0
    for ri in range(len(m.regions)):
        if m.regions[ri].kind == REGION_STABLE:
            continue
        var c = json_object()
        c.put(String("ours"), json_string_array(m.regions[ri].ours_lines))
        c.put(String("theirs"), json_string_array(m.regions[ri].theirs_lines))
        var before = json_array()
        if ri > 0 and m.regions[ri - 1].kind == REGION_STABLE:
            ref ls = m.regions[ri - 1].lines
            before = json_string_array(ls[max(0, len(ls) - 3):])
        var after = json_array()
        if ri + 1 < len(m.regions) and m.regions[ri + 1].kind == REGION_STABLE:
            ref ls = m.regions[ri + 1].lines
            after = json_string_array(ls[:min(3, len(ls))])
        c.put(String("before"), before)
        c.put(String("after"), after)
        c.put(String("choice"), json_int(m.states[ci].choice))
        c.put(String("edited"), json_string_array(m.states[ci].edited_lines))
        cs.append(c)
        ci += 1
    o.put(String("conflicts"), cs)
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_merge_choose(
    h: Int, ci: Int, choice: Int, ptr: Int, n: Int,
) abi("C"):
    """Resolve conflict ``ci``: 1 yours, 2 on disk, 3 both, 4 edited (the
    JSON string array carries the edited lines)."""
    if h == 0:
        return
    var edited = List[String]()
    if choice == 4:
        try:
            var a = parse_json(string_from_address(ptr, n))
            for i in range(a.array_len()):
                edited.append(a.array_at(i).as_str())
        except:
            return
    _desk(h)[].merge_view.native_choose(ci, choice, edited^)


@export
def tk_desktop_merge_finish(
    h: Int, apply: Int, cols: Int, rows: Int,
) abi("C") -> Int32:
    """Apply (1) or postpone (0). Returns 0 when Apply was refused because
    a conflict has no choice yet."""
    if h == 0:
        return 0
    try:
        return 1 if _desk(h)[].native_merge_finish(
            apply != 0, Rect(0, 0, cols, rows),
        ) else 0
    except:
        return 0


# --- macOS-style UI: Git history ----------------------------------------------


@export
def tk_desktop_history(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """Git ▸ History (of a file or a selection) for the native sheet:
    ``{title, selected, entries: [[sha, author, date, subject, pushed]]}``
    — patches come one at a time from ``tk_desktop_history_patch``. 0 when
    it isn't up natively."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.native_history_active():
        return 0
    ref hs = d.history
    var o = json_object()
    o.put(String("title"), json_str(hs.title))
    o.put(String("selected"), json_int(hs.list.selected))
    var es = json_array()
    for i in range(len(hs.entries)):
        ref e = hs.entries[i]
        var r = json_array()
        r.append(json_str(e.short_sha))
        r.append(json_str(e.author))
        r.append(json_str(e.date))
        r.append(json_str(e.subject))
        r.append(json_bool(e.is_pushed))
        es.append(r)
    o.put(String("entries"), es)
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_history_patch(
    h: Int, idx: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """Entry ``idx``'s patch text (raw ``git log -p`` output)."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.native_history_active() or idx < 0 \
            or idx >= len(d.history.entries):
        return 0
    return _write_out(d.history.entries[idx].patch, out_ptr, cap)


@export
def tk_desktop_history_act(h: Int, op: Int, idx: Int) abi("C"):
    """``op`` 0 selects entry ``idx``, 1 closes the history."""
    if h == 0:
        return
    ref d = _desk(h)[]
    if op == 0:
        d.native_history_select(idx)
    elif op == 1:
        d.history.close()


# --- macOS-style UI: file tree ------------------------------------------------


def _tree_json(ref t: FileTree, screen: Rect) -> String:
    var r = t.content_rect(screen)
    var o = json_object()
    _put_rect(o, r)
    o.put(String("root"), json_str(t.root))
    o.put(String("selected"), json_int(t.selected))
    o.put(String("focused"), json_bool(t.focused))
    var es = json_array()
    for i in range(len(t.entries)):
        ref e = t.entries[i]
        var row = json_array()
        row.append(json_str(e.name))
        row.append(json_int(e.depth))
        row.append(json_bool(e.is_dir))
        row.append(json_bool(e.is_expanded))
        row.append(json_bool(t.is_modified(e.path)))
        row.append(json_str(e.path))
        es.append(row)
    o.put(String("entries"), es)
    return encode_json(o)


def _review_tree_shown(ref d: Desktop) -> Bool:
    return d.native_review_reviewing() and d.review_tree.visible


def _tree_stamp(ref t: FileTree, screen: Rect, which: Int) -> Int:
    """Folds everything ``_tree_json`` reads into one Int (FNV-1a over
    the fields): the listing's version, selection, focus and rect."""
    var r = t.content_rect(screen)
    var hsh = fnv_int(fnv_start(), which)
    hsh = fnv_int(hsh, t.entries_version)
    hsh = fnv_int(hsh, t.selected)
    hsh = fnv_int(hsh, 1 if t.focused else 0)
    hsh = fnv_int(hsh, r.a.x)
    hsh = fnv_int(hsh, r.a.y)
    hsh = fnv_int(hsh, r.width())
    hsh = fnv_int(hsh, r.height())
    # Never 0: that's "no tree".
    return Int(hsh | 1)


@export
def tk_desktop_tree_stamp(h: Int, cols: Int, rows: Int) abi("C") -> Int:
    """A stamp of the tree ``tk_desktop_tree`` would return: equal stamps
    mean an equal payload, so the host skips the fetch. 0 when no tree is
    shown natively."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    var screen = Rect(0, 0, cols, rows)
    if _review_tree_shown(d):
        return _tree_stamp(d.review_tree, screen, 2)
    if not d.native_tree_shown():
        return 0
    return _tree_stamp(d.file_tree, screen, 1)


@export
def tk_desktop_tree(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The file tree for the native source list laid over its cells —
    the project tree, or while reviewing the changeset's file list:
    ``{x, y, w, h}`` (the listing's cell rect, separator excluded),
    ``root``, ``selected``, ``focused`` and ``entries: [[name, depth,
    is_dir, expanded, modified, path]]``. 0 when no tree is shown
    natively. Same buffer contract as ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    var screen = Rect(0, 0, cols, rows)
    if _review_tree_shown(d):
        return _write_out(_tree_json(d.review_tree, screen), out_ptr, cap)
    if not d.native_tree_shown():
        return 0
    return _write_out(_tree_json(d.file_tree, screen), out_ptr, cap)


@export
def tk_desktop_tree_act(h: Int, op: Int, idx: Int, x: Int, y: Int) abi("C"):
    """A native tree row was acted on: ``op`` 0 select, 1 expand / collapse,
    2 open (file) or toggle (directory), 3 context menu anchored at cell
    ``x``, ``y``. While reviewing it acts on the changeset's file list
    (opening a file reviews it; there is no context menu)."""
    if h == 0:
        return
    ref d = _desk(h)[]
    if _review_tree_shown(d):
        if op == 0:
            d.review_tree.native_select(idx)
        elif op == 1:
            d.review_tree.native_toggle(idx)
        elif op == 2:
            d.review_tree.native_open(idx)
            d._review_tree_drain()
        return
    if op == 0:
        d.file_tree.native_select(idx)
        d.native_tree_focus()
    elif op == 1:
        d.file_tree.native_toggle(idx)
    elif op == 2:
        d.file_tree.native_open(idx)
    elif op == 3:
        d.native_tree_menu(idx, Point(x, y))


# --- macOS-style / Mac OS 9 UI: host-drawn framework chrome ---------------------


@export
def tk_desktop_host_items(
    h: Int, surface: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The last frame's framework chrome on ``surface`` (``HOST_SURFACE_*``:
    0 project window, 1 floating panels, 2 Settings, 3 dialog, 4 git) for
    the host to draw in its look (``canvas.HostItem``): an array of
    ``{kind, x, y, w, h, side, active, ka, kb, fg, bg}`` — ``kind``
    ``"split"`` / ``"vscroll"`` / ``"hscroll"``; the rect in thousandths of
    a cell; a split's orientation (``side``: halves left / right) and
    whether it's dragged; a scroll bar's thumb span along it (``ka`` ..
    ``kb``, same units); the colors the core would have used (0xRRGGBB).
    Draw-only: the cells under an item take the mouse. 0 when none."""
    if h == 0 or surface < 0 or surface >= HOST_SURFACES:
        return 0
    ref d = _desk(h)[]
    var arr = json_array()
    for i in range(len(d.host_items[surface])):
        var it = d.host_items[surface][i].copy()
        var o = json_object()
        if it.kind == HOST_SPLIT:
            o.put(String("kind"), json_str(String("split")))
        elif it.kind == HOST_TEST_HEADER:
            o.put(String("kind"), json_str(String("test_header")))
        elif it.kind == HOST_TEST_LIST:
            o.put(String("kind"), json_str(String("test_list")))
        elif it.kind == HOST_TEST_DETAIL:
            o.put(String("kind"), json_str(String("test_detail")))
        elif it.kind == HOST_VSCROLL:
            o.put(String("kind"), json_str(String("vscroll")))
        elif it.kind == HOST_HSCROLL:
            o.put(String("kind"), json_str(String("hscroll")))
        else:
            continue
        o.put(String("x"), json_int(it.x))
        o.put(String("y"), json_int(it.y))
        o.put(String("w"), json_int(it.w))
        o.put(String("h"), json_int(it.h))
        o.put(String("side"), json_bool(it.side_by_side))
        o.put(String("active"), json_bool(it.active))
        o.put(String("ka"), json_int(it.knob_a))
        o.put(String("kb"), json_int(it.knob_b))
        o.put(String("fg"), json_int(_attr_rgb(d, it.attr, True)))
        o.put(String("bg"), json_int(_attr_rgb(d, it.attr, False)))
        o.put(String("tag"), json_int(it.tag))
        arr.append(o)
    if arr.array_len() == 0:
        return 0
    return _write_out(encode_json(arr), out_ptr, cap)


def _put_rect(mut o: JsonValue, r: Rect):
    """``r`` as cell ``x`` / ``y`` / ``w`` / ``h`` fields of ``o``."""
    o.put(String("x"), json_int(r.a.x))
    o.put(String("y"), json_int(r.a.y))
    o.put(String("w"), json_int(r.width()))
    o.put(String("h"), json_int(r.height()))


def _attr_rgb(ref d: Desktop, attr: Attr, fg: Bool) -> Int:
    """``attr``'s foreground or background as 0xRRGGBB, through the theme."""
    if fg:
        if (attr.color_mode & FG_TRUECOLOR) != 0:
            return Int(attr.fg_rgb)
        return Int(d.active_theme.palette[Int(attr.fg)])
    if (attr.color_mode & BG_TRUECOLOR) != 0:
        return Int(attr.bg_rgb)
    return Int(d.active_theme.palette[Int(attr.bg)])


# --- macOS-style / Mac OS 9 UI: the test results view -------------------------


@export
def tk_desktop_test_results(
    h: Int, tag: Int, generation: Int, version: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The test results view ``tag`` (from its host items) for the native
    header and list: ``TestResultsView.native_state`` — the tests changed
    since ``version`` of run ``generation`` the host already has (pass -1
    for everything), with the progress and selection. 0 when there's no
    such view."""
    if h == 0:
        return 0
    var o = _desk(h)[].native_test_state(tag, generation, version)
    if o.is_null():
        return 0
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_test_detail(h: Int, tag: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The selected test of results view ``tag`` for the native detail
    (``TestResultsView.native_detail``). 0 when there's no such view."""
    if h == 0:
        return 0
    var o = _desk(h)[].native_test_detail(tag)
    if o.is_null():
        return 0
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_test_results_act(
    h: Int, tag: Int, op: Int, index: Int, ptr: Int, n: Int,
) abi("C"):
    """A native results view's action: ``op`` 0 select test ``index``, 1
    open test ``index``, 2 open the file (string) at line ``index``, 3 open
    the URL (string). The pane takes the keyboard either way."""
    if h == 0:
        return
    _desk(h)[].native_test_act(tag, op, index, string_from_address(ptr, n))


# --- macOS-style UI: editor scroller --------------------------------------------


@export
def tk_desktop_editor_scroller(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The focused editor's vertical scroll for a native overlay scroller
    (frameless tabbed editors have no grid scroll bar): ``{win, x, y, w, h,
    cur, max}`` — the editor's interior cells and its position / maximum
    in visual rows × 1000 (wrap-aware). Drive it with
    ``tk_editor_minimap_to``. 0 when there's nothing to show."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.host_tabs() or not d.windows.tabbed \
            or not d.windows.focused_is_editor() \
            or d._fullscreen_modal_active() or d.history.active \
            or d.merge_view.active or d.review.active:
        return 0
    var win = d.windows.focused
    var r = d.windows.windows[win].interior()
    var m = d.smooth_begin(win, Rect(0, 0, cols, rows))
    var o = json_object()
    o.put(String("win"), json_int(win))
    _put_rect(o, r)
    o.put(String("cur"), json_int(Int(m[0] * 1000.0)))
    o.put(String("max"), json_int(Int(m[1] * 1000.0)))
    # The editor background, so the knob can contrast with it.
    o.put(String("bg"), json_int(Int(d.active_theme.palette[Int(EDITOR_BG)])))
    return _write_out(encode_json(o), out_ptr, cap)


# --- macOS-style UI: tool-pane headers -----------------------------------------


def _pane_json(
    kind: Int, idx: Int, r: Rect, title: String, focused: Bool,
    ref dock: BottomDockedPanel, hint: String,
) -> JsonValue:
    var o = json_object()
    o.put(String("kind"), json_int(kind))
    o.put(String("idx"), json_int(idx))
    o.put(String("x"), json_int(r.a.x))
    o.put(String("y"), json_int(r.a.y))
    o.put(String("w"), json_int(r.width()))
    o.put(String("h"), json_int(min(dock.header_rows(), r.height())))
    o.put(String("title"), json_str(title))
    o.put(String("focused"), json_bool(focused))
    o.put(String("state"), json_int(Int(dock.state)))
    o.put(String("hint"), json_str(hint))
    o.put(String("close"), json_bool(len(dock.close_button_id.as_bytes()) > 0))
    var cmds = json_array()
    for i in range(len(dock.commands)):
        # The grid draws ``[Label]``; a native button wants just the label.
        var label = dock.commands[i].label
        var b = label.as_bytes()
        if len(b) >= 2 and b[0] == 0x5B and b[len(b) - 1] == 0x5D:
            label = byte_slice(label, 1, len(b) - 1)
        var c = json_array()
        c.append(json_str(label))
        c.append(json_str(dock.commands[i].id))
        cmds.append(c)
    o.put(String("commands"), cmds)
    return o^


def _pane_slot_json(ref d: Desktop, s: PanelSlot) -> JsonValue:
    if s.kind == PANEL_KIND_TERMINAL:
        ref t = d.terminal_panes[s.idx]
        return _pane_json(
            Int(DOCK_TERMINAL), s.idx, s.rect, t.header_title(), t.focused,
            t.dock, String("T"),
        )
    if s.kind == PANEL_KIND_DEBUG:
        return _pane_json(
            Int(DOCK_DEBUG_PANE), 0, s.rect, d.debug_pane.header_title(),
            d.debug_pane.focused, d.debug_pane.dock, String("9"),
        )
    if s.kind == PANEL_KIND_FIND_RESULTS:
        return _pane_json(
            Int(DOCK_FIND_RESULTS_PANE), 0, s.rect,
            d.find_results_pane.header_title(), d.find_results_pane.focused,
            d.find_results_pane.dock, String(""),
        )
    return _pane_json(
        Int(DOCK_TEST_PANE), 0, s.rect, d.test_pane.header_title(),
        d.test_pane.focused, d.test_pane.dock, String(""),
    )


def _write_panes(
    ref d: Desktop, slots: List[PanelSlot], out_ptr: Int, cap: Int,
) -> Int:
    var a = json_array()
    for ref s in slots:
        if not s.rect.is_empty():
            a.append(_pane_slot_json(d, s))
    if a.array_len() == 0:
        return 0
    return _write_out(encode_json(a), out_ptr, cap)


@export
def tk_desktop_panes(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The docked tool panes' headers for the native overlay: an array of
    ``{kind, idx, x, y, w, h, title, focused, state, hint, close, commands:
    [[label, id]]}`` (the header is the ``h`` rows from ``y``). 0 when panes
    don't get native headers."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.native_panes_shown():
        return 0
    return _write_panes(d, d._dock_slots(Rect(0, 0, cols, rows)), out_ptr, cap)


@export
def tk_desktop_panels_panes(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """``tk_desktop_panes`` for the floating-panels window: the same
    headers, at the panes' rows in that window's ``cols`` × ``rows``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.native_panels_shown():
        return 0
    return _write_panes(
        d, d._panel_window_slots(Rect(0, 0, cols, rows)), out_ptr, cap,
    )


@export
def tk_desktop_pane_act(
    h: Int, kind: Int, idx: Int, op: Int, ptr: Int, n: Int,
) abi("C"):
    """A native pane header control: ``op`` 0 focus, 1 close, 2 minimize /
    restore, 3 maximize / restore, 4 run the command whose id is the
    string."""
    if h == 0:
        return
    _desk(h)[].native_pane_act(UInt8(kind), idx, op, string_from_address(ptr, n))


# --- macOS-style UI: debug pane inspect tables ---------------------------------


def _split_at(text: String, sep: String) -> Tuple[String, String]:
    """``text`` cut at the first ``sep``: (before, after), or (text, "")."""
    var at = text.find(sep)
    if at < 0:
        return (text, String(""))
    var n = len(text.as_bytes())
    return (
        byte_slice(text, 0, at),
        byte_slice(text, at + len(sep.as_bytes()), n),
    )


@export
def tk_desktop_debug_inspect(
    h: Int, panels: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The debug pane's Stack / Locals / Watches for native tables laid
    over their cells: ``{x, y, w, h, output, focused, status, frames: [[row, name,
    location, subtle, current]], vars: [[row, kind, name, value, type,
    depth, expandable, expanded]]}``. ``row`` indexes the pane's rows (for
    ``tk_desktop_debug_inspect_act``); ``kind`` is 0 a section title, 2 a
    variable, 3 a watch; ``output`` says the rect's last row is the
    Output divider; the first row is the status caption when ``status``
    isn't empty. ``panels`` 1 asks for the floating-panels window, 0 for
    the main one; ``cols`` × ``rows`` is that surface. 0 when the grid
    draws them, or the pane is on the other surface."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    ref p = d.debug_pane
    var r = p.native_rect
    if not p.visible or not p.host_inspect or r.is_empty() \
            or d.panels_detached != (panels != 0):
        return 0
    var pane_bottom = d.debug_pane_rect(Rect(0, 0, cols, rows)).b.y
    if panels != 0:
        var slots = d._panel_window_slots(Rect(0, 0, cols, rows))
        for ref s in slots:
            if s.kind == PANEL_KIND_DEBUG:
                pane_bottom = s.rect.b.y
    var o = json_object()
    _put_rect(o, r)
    o.put(String("output"), json_bool(r.b.y < pane_bottom))
    o.put(String("focused"), json_bool(p.focused))
    o.put(String("status"), json_str(p.status_text))
    var frames = json_array()
    var vars = json_array()
    var stack_section = True
    var seen_header = False
    for i in range(len(p.rows)):
        ref row = p.rows[i]
        if row.kind == PANE_ROW_BLANK:
            continue
        if row.kind == PANE_ROW_HEADER:
            if not seen_header:
                seen_header = True     # "Stack" — the table's own header
                continue
            stack_section = False
        if row.kind == PANE_ROW_FRAME and stack_section:
            # ``text`` is the padded name, two spaces, then the location.
            var loc = String("")
            var at = row.text.rfind(String("  "))
            if at >= 0:
                loc = String(byte_slice(
                    row.text, at + 2, len(row.text.as_bytes()),
                ).strip())
            var f = json_array()
            f.append(json_int(i))
            f.append(json_str(row.type_name))
            f.append(json_str(loc))
            f.append(json_bool(row.expanded))
            f.append(json_bool(row.depth == p.current_frame_index))
            frames.append(f)
            continue
        stack_section = False
        var v = json_array()
        v.append(json_int(i))
        v.append(json_int(Int(row.kind)))
        if row.kind == PANE_ROW_HEADER:
            v.append(json_str(row.text))
            v.append(json_str(String("")))
        else:
            var parts = _split_at(row.text, String(" = "))
            v.append(json_str(parts[0]))
            v.append(json_str(parts[1]))
        v.append(json_str(row.type_name))
        v.append(json_int(row.depth))
        v.append(json_bool(row.kind == PANE_ROW_VARIABLE and row.ref_id != 0))
        v.append(json_bool(row.expanded))
        vars.append(v)
    o.put(String("frames"), frames)
    o.put(String("vars"), vars)
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_debug_inspect_act(
    h: Int, op: Int, row: Int, ptr: Int, n: Int,
) abi("C"):
    """A native inspect table's action: ``op`` 0 select the frame at
    ``row``, 1 expand / collapse the variable at ``row``, 2 remove the
    watch at ``row``, 3 add the string as a watch, 4 just focus the
    pane."""
    if h == 0:
        return
    _desk(h)[].native_debug_act(op, row, string_from_address(ptr, n))


# --- macOS-style UI: review mode ----------------------------------------------


@export
def tk_desktop_review(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """Review mode for the native host. Picking: ``{mode: "picker", tab,
    labels, pushed, cursor}`` (``pushed[i]`` false for a commit that isn't
    on a remote). Reviewing: ``{mode: "reviewing", title, files:
    [[path, added, deleted]], cur_file, change_index, change_total, num,
    den, editable, bar: {x, y, w, h}}`` with ``bar`` the toolbar row's
    cells to overlay. 0 when review isn't up natively."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    ref rv = d.review
    var o = json_object()
    if d.native_review_picker():
        o.put(String("mode"), json_str(String("picker")))
        o.put(String("tab"), json_int(rv.picker_tab))
        o.put(String("labels"), json_string_array(rv.picker_labels))
        var pushed = json_array()
        for i in range(len(rv.picker_pushed)):
            pushed.append(json_bool(rv.picker_pushed[i]))
        o.put(String("pushed"), pushed)
        o.put(String("cursor"), json_int(max(rv.picker_list.selected, 0)))
        return _write_out(encode_json(o), out_ptr, cap)
    if not d.native_review_reviewing():
        return 0
    o.put(String("mode"), json_str(String("reviewing")))
    o.put(String("title"), json_str(rv.title))
    var files = json_array()
    for i in range(rv.file_count()):
        var f = json_array()
        f.append(json_str(rv.files[i].path))
        f.append(json_bool(rv.files[i].added))
        f.append(json_bool(rv.files[i].deleted))
        files.append(f)
    o.put(String("files"), files)
    o.put(String("cur_file"), json_int(rv.cur_file))
    o.put(String("change_index"), json_int(rv.change_index))
    o.put(String("change_total"), json_int(rv.change_total))
    var p = d.native_review_progress()
    o.put(String("num"), json_int(p[0]))
    o.put(String("den"), json_int(p[1]))
    o.put(String("editable"), json_bool(rv.is_editable()))
    var bar = json_object()
    bar.put(String("x"), json_int(0))
    # Two rows: the toolbar row plus the one ``_review_body_rect`` keeps
    # free above it for the native bar's controls.
    bar.put(String("y"), json_int(rows - 2))
    bar.put(String("w"), json_int(cols))
    bar.put(String("h"), json_int(2))
    o.put(String("bar"), bar)
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_review_act(h: Int, op: Int, arg: Int) abi("C"):
    """Review actions: ``op`` 0 show picker tab ``arg``, 1 review picker
    row ``arg``, 2 cancel / end the review, 3 next change, 4 previous
    change, 5 review changeset file ``arg``."""
    if h == 0:
        return
    ref d = _desk(h)[]
    if op == 0:
        d.native_review_tab(arg)
    elif op == 1:
        d.native_review_pick(arg)
    elif op == 2:
        d.native_review_close()
    elif op == 3:
        d.native_review_nav(1)
    elif op == 4:
        d.native_review_nav(-1)
    elif op == 5:
        d.native_review_file(arg)


# --- macOS-style UI: find bar -----------------------------------------------


@export
def tk_desktop_take_find_request(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """One-shot: Find / Replace was asked for, so show the find bar —
    ``{mode: find|replace, seed, case, word, regex}``. 0 when nothing is
    pending; the request is kept until it fits the buffer."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if len(d.native_find_request.as_bytes()) == 0:
        return 0
    var o = json_object()
    o.put(String("mode"), json_str(d.native_find_request))
    o.put(String("seed"), json_str(d.native_find_seed))
    o.put(String("case"), json_bool(d._last_search_opts.case_sensitive))
    o.put(String("word"), json_bool(d._last_search_opts.whole_word))
    o.put(String("regex"), json_bool(d._last_search_opts.regex))
    var n = _write_out(encode_json(o), out_ptr, cap)
    if n > 0 and n <= cap:
        d.native_find_request = String("")
    return n


@export
def tk_desktop_find(h: Int, ptr: Int, n: Int) abi("C"):
    """Run a find bar button: ``{op, find, replace, case, word, regex}``."""
    if h == 0:
        return
    try:
        var o = parse_json(string_from_address(ptr, n))
        var opts = SearchOptions(
            json_get_bool(o, String("case"), False),
            json_get_bool(o, String("word"), False),
            json_get_bool(o, String("regex"), False),
        )
        _desk(h)[].native_find(
            json_get_string(o, String("op")),
            json_get_string(o, String("find")),
            json_get_string(o, String("replace")),
            opts,
        )
    except:
        pass


# --- macOS-style UI: popup menus --------------------------------------------


@export
def tk_desktop_popup(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The anchored popup (editor / tab context menu, spelling, test
    gutter, diagnostic, LSP status) the host shows as an ``NSMenu``:
    ``{kind, x, y, items: [{label, code, enabled, separator?}]}`` with ``x`` / ``y``
    the anchor cell. 0 when none is up. Same buffer contract as
    ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    var kind = d.native_popup_kind()
    if len(kind.as_bytes()) == 0:
        return 0
    var o = json_object()
    o.put(String("kind"), json_str(kind))
    var at = d.native_popup_anchor()
    o.put(String("x"), json_int(at.x))
    o.put(String("y"), json_int(at.y))
    var items = json_array()
    var rows = d.native_popup_items()
    for i in range(len(rows)):
        var it = json_object()
        it.put(String("label"), json_str(rows[i].label))
        it.put(String("code"), json_int(rows[i].code))
        it.put(String("enabled"), json_bool(rows[i].enabled))
        if rows[i].is_separator():
            it.put(String("separator"), json_bool(True))
        items.append(it)
    o.put(String("items"), items)
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_popup_choose(h: Int, code: Int) abi("C") -> Int32:
    """The native popup closed with item ``code`` picked (0 = dismissed).
    Returns a host action code."""
    if h == 0:
        return ACT_NONE
    try:
        return _action_code(_desk(h)[].native_popup_choose(code))
    except:
        return ACT_NONE


# --- macOS-style UI: the git view ---------------------------------------------


def _git_state_json(mut d: Desktop) -> String:
    if not d.native_git_active():
        return String("")
    ref g = d.local_changes
    var o = json_object()
    o.put(String("look"), json_str(
        String("platinum") if d.platinum_ui() else String("macos"),
    ))
    o.put(String("root"), json_str(g.root))
    o.put(String("title"), json_str(d.git_window_title()))
    var files = json_array()
    for i in range(len(g.files)):
        var f = json_object()
        f.put(String("path"), json_str(g.files[i].path))
        f.put(String("x"), json_str(String(chr(Int(g.files[i].staged)))))
        f.put(String("y"), json_str(String(chr(Int(g.files[i].worktree)))))
        files.append(f)
    o.put(String("files"), files)
    var now = wall_clock_ms() // 1000
    var current = String("")
    var branches = json_array()
    for i in range(len(g.branches)):
        ref b = g.branches[i]
        if b.is_current:
            current = b.name
        var r = json_object()
        r.put(String("name"), json_str(b.name))
        r.put(String("current"), json_bool(b.is_current))
        r.put(String("remote"), json_bool(b.is_remote()))
        r.put(String("subject"), json_str(b.subject))
        r.put(String("age"), json_str(
            format_age(now - b.committer_unix) if now > 0 else String("")
        ))
        branches.append(r)
    o.put(String("branches"), branches)
    o.put(String("branch"), json_str(current))
    var commits = json_array()
    for i in range(len(g.commits)):
        ref c = g.commits[i]
        var r = json_object()
        r.put(String("sha"), json_str(c.short_sha))
        r.put(String("subject"), json_str(c.subject))
        r.put(String("author"), json_str(c.author))
        r.put(String("date"), json_str(c.date))
        r.put(String("pushed"), json_bool(c.is_pushed))
        r.put(String("tags"), json_str(c.tags))
        commits.append(r)
    o.put(String("commits"), commits)
    o.put(String("sel_file"), json_int(g.sel_file))
    o.put(String("sel_branch"), json_int(g.sel_branch))
    o.put(String("sel_commit"), json_int(g.sel_commit))
    o.put(String("focus"), json_int(g.focus))
    o.put(String("busy"), json_bool(g.native_busy()))
    o.put(String("busy_label"), json_str(
        g.git_runner.label if g.native_busy() else String("")
    ))
    o.put(String("flash"), json_str(g.flash_message))
    var hints = json_array()
    var hl = g.hints()
    for i in range(len(hl)):
        var r = json_array()
        r.append(json_str(hl[i].keys))
        r.append(json_str(hl[i].label))
        r.append(json_int(Int(hl[i].key)))
        r.append(json_int(Int(hl[i].mods)))
        r.append(json_bool(hl[i].button))
        hints.append(r)
    o.put(String("hints"), hints)
    o.put(String("status"), json_str(g.status_message))
    var ov = json_object()
    ov.put(String("kind"), json_str(g.native_overlay_kind()))
    ov.put(String("message"), json_str(g.overlay_message))
    ov.put(String("action"), json_str(g.overlay_action))
    ov.put(String("text"), json_str(g.native_overlay_text()))
    ov.put(String("output"), json_str(g.overlay_output))
    ov.put(String("remotes"), json_string_array(g._remotes))
    ov.put(String("remote_sel"), json_int(g._remote_sel))
    ov.put(String("prefix"), json_str(g.native_typed_prefix()))
    ov.put(String("into_main"), json_bool(g.native_merge_into_main()))
    o.put(String("overlay"), ov)
    return encode_json(o)


def _panel_json(ref d: Desktop, ref p: RightPanel, pane: Int) -> JsonValue:
    var o = json_object()
    o.put(String("pane"), json_int(pane))
    o.put(String("cursor"), json_int(p.cursor))
    var rows = json_array()
    for i in range(len(p.lines)):
        var r = json_array()
        r.append(json_int(p.kind[i]))
        r.append(json_str(p.lines[i]))
        rows.append(r)
    o.put(String("rows"), rows)
    var spans = json_array()
    for i in range(len(p.highlights)):
        ref h = p.highlights[i]
        var sp = json_array()
        sp.append(json_int(h.row))
        sp.append(json_int(h.col_start))
        sp.append(json_int(h.col_end))
        sp.append(json_int(_attr_rgb(d, h.attr, True)))
        spans.append(sp)
    o.put(String("spans"), spans)
    return o^


@export
def tk_desktop_git(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The git view as JSON for the host (``look``: the macOS sheet or the
    Platinum window): files (``x`` / ``y`` porcelain columns), branches, commits, selections, focus, busy /
    flash / status lines and the open overlay. 0 when the view isn't up
    natively. Same buffer contract as ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    return _write_out(_git_state_json(_desk(h)[]), out_ptr, cap)


@export
def tk_desktop_git_panels(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """The right side for the current selection: ``{panels: [{pane,
    cursor, rows: [[kind, text]], spans: [[row, byte_start, byte_end,
    rgb]]}], bg, fg}`` — Unstaged + Staged for a file, one info panel for
    a branch or commit. Row kinds are ``LocalChanges``' ``_LINE_*``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d.native_git_active():
        return 0
    d.local_changes.native_panels(d.grammar_registry, Rect(0, 0, cols, rows))
    var panels = json_array()
    if d.local_changes.native_shows_file():
        panels.append(_panel_json(d, d.local_changes.unstaged, 3))
        panels.append(_panel_json(d, d.local_changes.staged, 4))
    else:
        panels.append(_panel_json(d, d.local_changes.info, 5))
    var o = json_object()
    o.put(String("panels"), panels)
    o.put(String("bg"), json_int(Int(d.active_theme.palette[Int(EDITOR_BG)])))
    o.put(String("fg"), json_int(Int(d.active_theme.palette[Int(EDITOR_FG)])))
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_git_select(
    h: Int, pane: Int, idx: Int, cols: Int, rows: Int,
) abi("C"):
    """Select row ``idx`` of a sidebar list (0 files, 1 branches, 2
    commits)."""
    if h == 0:
        return
    _desk(h)[].native_git_select(pane, idx, Rect(0, 0, cols, rows))


@export
def tk_desktop_git_cursor(h: Int, pane: Int, row: Int) abi("C"):
    """Put a right-panel cursor (3 unstaged, 4 staged, 5 info) on ``row``."""
    if h == 0:
        return
    _desk(h)[].native_git_cursor(pane, row)


@export
def tk_desktop_git_key(
    h: Int, pane: Int, key: Int, mods: Int, cols: Int, rows: Int,
) abi("C") -> Int32:
    """Run the git view's operation for ``key`` with ``pane`` focused (-1
    keeps it): Space stage / unstage / checkout, ``d`` discard / delete,
    ``M`` merge, ``r`` rebase, ``o`` compare, ``e`` reword, ``A`` amend,
    ``p`` pull, ``P`` push, Ctrl+P push to a remote. Returns a host action
    code."""
    if h == 0:
        return ACT_NONE
    try:
        _desk(h)[].native_git_key(
            pane, UInt32(key), UInt8(mods), Rect(0, 0, cols, rows),
        )
    except:
        pass
    return ACT_NONE


@export
def tk_desktop_git_open(
    h: Int, pane: Int, row: Int, cols: Int, rows: Int,
) abi("C"):
    """Open a file row (pane 0) or a diff / info row's jump target."""
    if h == 0:
        return
    try:
        _desk(h)[].native_git_open(pane, row, Rect(0, 0, cols, rows))
    except:
        pass


@export
def tk_desktop_git_answer(
    h: Int, cptr: Int, clen: Int, tptr: Int, tlen: Int,
) abi("C"):
    """Answer the git view's overlay: ``ok`` / ``cancel`` / ``merge`` /
    ``rebase``, with the message, remote index or typed prefix as text."""
    if h == 0:
        return
    _desk(h)[].native_git_answer(
        string_from_address(cptr, clen), string_from_address(tptr, tlen),
    )


@export
def tk_desktop_git_close(h: Int) abi("C") -> Int32:
    """Close the git view; 0 when refused because a git op is running."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].native_git_close() else 0


# --- first-launch welcome window ---------------------------------------------


@export
def tk_desktop_welcome_needed(h: Int) abi("C") -> Int32:
    """1 until the welcome window (look / theme / font) has been answered
    once; the host shows it after the first frame."""
    if h == 0:
        return 0
    return 0 if _desk(h)[].config.welcome_done else 1


@export
def tk_desktop_welcome_options(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """What the welcome window offers, and what's set now:
    ``{themes, builtin_fonts: [bitmap, classic, chicago], native_ui, platinum_ui,
    theme, font, font_size}``. The host adds the system's monospace families to the
    built-in fonts. Same buffer contract as ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    var o = json_object()
    o.put(String("themes"), json_string_array(theme_names()))
    var fonts = json_array()
    fonts.append(json_str(default_font_label()))
    fonts.append(json_str(chicago_font_label()))
    o.put(String("builtin_fonts"), fonts)
    o.put(String("native_ui"), json_bool(d.config.native_ui))
    o.put(String("platinum_ui"), json_bool(d.config.platinum_ui))
    o.put(String("theme"), json_str(d.config.theme))
    o.put(String("font"), json_str(d.font_label()))
    o.put(String("font_size"), json_int(d.config.font_size))
    return _write_out(encode_json(o), out_ptr, cap)


@export
def tk_desktop_welcome_apply(h: Int, ptr: Int, n: Int, done: Int) abi("C"):
    """Apply the welcome window's ``{native_ui, platinum_ui, theme, font,
    font_size}`` (live while it's open; ``done`` = 1 when it's closed for
    good)."""
    if h == 0:
        return
    try:
        var o = parse_json(string_from_address(ptr, n))
        _desk(h)[].apply_welcome(
            json_get_bool(o, String("native_ui"), False),
            json_get_bool(o, String("platinum_ui"), False),
            json_get_string(o, String("theme")),
            json_get_string(o, String("font")),
            json_get_int(o, String("font_size"), 0),
            done != 0,
        )
    except:
        pass


# --- macOS-style UI: native pickers ----------------------------------------


@export
def tk_desktop_native_confirm_answer(h: Int, choice: Int) abi("C") -> Int32:
    """Answer the native confirm sheet: the pressed button's index, or -1
    when it was dismissed. Returns a host action code, like a menu invoke."""
    if h == 0:
        return ACT_NONE
    return _action_code(_desk(h)[].native_confirm_answer(choice))


@export
def tk_desktop_native_color_answer(
    h: Int, rgb: Int, mode: Int, ok: Int,
) abi("C"):
    """Answer the ``color`` sheet: ``0xRRGGBB``, the notation (0 OkLab, 1
    RGB, 2 HSL), and ``ok`` = 0 when cancelled."""
    if h == 0:
        return
    _desk(h)[].native_color_answer(rgb, mode, ok != 0)


@export
def tk_desktop_ui(h: Int, out_ptr: Int, cap: Int) abi("C") -> Int:
    """The open declarative dialogs for the native projector, bottom first:
    ``{stack: [{name, tree}], window: [{name, tree}], look}`` with ``tree`` the
    ``ui_to_json`` of each one's ``ui()``. ``stack`` holds the modal
    dialogs (sheets on the window), ``window`` Settings and what it opened
    (its own window, the workspace staying usable). ``look`` is
    ``"macos"`` (AppKit views) or ``"platinum"`` (the Mac OS 9 projector).
    0 when neither is up natively. Same buffer contract as
    ``tk_desktop_native_dialog``."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    var modal = d.ui_surfaces() if d.native_ui_surface_active() else List[String]()
    var window = d.settings_surfaces() if d.settings_native() else List[String]()
    if len(modal) == 0 and len(window) == 0:
        return 0
    var out = json_object()
    out.put(String("stack"), _ui_stack_json(d, modal))
    out.put(String("window"), _ui_stack_json(d, window))
    out.put(String("look"), json_str(
        String("platinum") if d.platinum_ui() else String("macos"),
    ))
    return _write_out(encode_json(out), out_ptr, cap)


def _ui_stack_json(mut d: Desktop, names: List[String]) -> JsonValue:
    var stack = json_array()
    for i in range(len(names)):
        var o = json_object()
        o.put(String("name"), json_str(names[i]))
        o.put(String("tree"), ui_to_json(d.ui_tree(names[i])))
        stack.append(o)
    return stack^


@export
def tk_desktop_ui_event(h: Int, ptr: Int, n: Int) abi("C") -> Int32:
    """What the user did in the native projection of dialog ``name`` (or,
    for scripted screenshots, what to do in either projection):
    ``{name, events: [[is_action, key, value]]}`` — applied exactly as the
    grid projector's events are (``Desktop.ui_apply``). Returns a host
    action code (a picker opening a project in a new window)."""
    if h == 0:
        return ACT_NONE
    ref d = _desk(h)[]
    try:
        var o = parse_json(string_from_address(ptr, n))
        var name = json_get_string(o, String("name"))
        var window = d.settings_surfaces()
        if name != d.ui_surface() and not (
            len(window) > 0 and name == window[len(window) - 1]
        ):
            return ACT_NONE   # it closed (or another took over) meanwhile
        var evs = List[UIEvent]()
        var a = o.object_get(String("events"))
        if a:
            var arr = a.value().copy()
            for i in range(arr.array_len()):
                var e = arr.array_at(i)
                evs.append(UIEvent(
                    e.array_at(0).as_bool(), e.array_at(1).as_str(),
                    e.array_at(2).as_str(),
                ))
        return _action_code(d.ui_apply(name, evs))
    except:
        return ACT_NONE


@export
def tk_desktop_native_choice_answer(h: Int, index: Int) abi("C"):
    """Answer a ``choice`` dialog (an LSP message request, or a color
    presentation): the picked action's index, -1 when dismissed."""
    if h == 0:
        return
    _desk(h)[].native_choice_answer(index)


@export
def tk_desktop_native_prompt_answer(
    h: Int, ptr: Int, n: Int, ok: Int,
) abi("C") -> Int32:
    """Answer the native prompt sheet with the entered text (``ok`` = 0
    when cancelled). Returns a host action code."""
    if h == 0:
        return ACT_NONE
    return _action_code(
        _desk(h)[].native_prompt_answer(string_from_address(ptr, n), ok != 0)
    )


@export
def tk_desktop_native_save_as_answer(h: Int, ptr: Int, n: Int) abi("C"):
    """Answer the native save panel with the chosen absolute path, or an
    empty one (``n`` = 0) when cancelled."""
    if h == 0:
        return
    _desk(h)[].native_save_as_answer(string_from_address(ptr, n))


@export
def tk_desktop_take_pending_new_window_project(
    h: Int, out_ptr: Int, cap: Int,
) abi("C") -> Int:
    """Drain the "open this project in a new window" path queued by the
    Project menu's inline recent-project picks. The ``_write_out``
    contract: 0 when nothing is queued, and the path stays queued until
    it fits the buffer.

    The host calls this right after receiving ``ACT_NEW_WINDOW`` from
    ``tk_desktop_menu_invoke`` to discover whether the new-window
    request was a plain "File ▸ New window" pick (returns 0) or a
    recent-project pick that should land in a project-loaded window
    (returns the path)."""
    if h == 0:
        return 0
    ref d = _desk(h)[]
    if not d._pending_new_window_project:
        return 0
    var n = _write_out(d._pending_new_window_project.value(), out_ptr, cap)
    if n > 0 and n <= cap:
        d._pending_new_window_project = Optional[String]()
    return n
