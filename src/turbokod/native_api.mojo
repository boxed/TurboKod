"""C-ABI surface for the Swift front-end.

The Swift app owns the macOS run loop, windows, menus, and rendering. Each
window holds an opaque handle to a Mojo ``Desktop`` created here; Swift calls
these ``@export``-ed functions to feed events, pull a cell grid to draw, and
run per-frame housekeeping (LSP/DAP/autosave ticks).

The handle is a heap ``Desktop`` pointer: we ``malloc`` storage, construct in
place, and hand the address back as an ``Int``. On later calls we rebuild a
usable pointer with ``UnsafePointer[Desktop, MutExternalOrigin](
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
from std.sys import size_of

from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.events import (
    Event, MOD_ALT, MOD_CTRL, MOD_META, MOD_SHIFT,
    KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_UP,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT,
    MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN,
)
from turbokod.geometry import Point, Rect
from turbokod.menu import Menu, MenuItem
from turbokod.posix import (
    getenv_value, prepend_user_bin_dirs_to_path, recover_path_deferred_once,
)
from turbokod.string_utils import (
    codepoint_at, escape_drop_paths, split_lines_no_trailing,
)
from turbokod.theme import theme_by_name
from turbokod.desktop import (
    Desktop,
    APP_QUIT_ACTION, APP_SETTINGS,
    DEBUG_ADD_WATCH, DEBUG_CONDITIONAL_BP, DEBUG_START_OR_CONTINUE,
    DEBUG_STEP_IN, DEBUG_STEP_OUT, DEBUG_STEP_OVER, DEBUG_STOP,
    DEBUG_TOGGLE_BREAKPOINT, DEBUG_TOGGLE_RAISED,
    DEBUG_FOCUS_PANE,
    EDITOR_COMPARE_CLIPBOARD, EDITOR_COPY, EDITOR_CUT, EDITOR_FILL,
    EDITOR_FIND, EDITOR_FIND_NEXT, EDITOR_FIND_PREV, EDITOR_FIND_SYMBOL,
    EDITOR_GOTO,
    EDITOR_GOTO_SYMBOL, EDITOR_LOOKUP_DOCS, EDITOR_NEW, EDITOR_OPEN,
    EDITOR_FORMAT_DOCUMENT, EDITOR_FORMAT_SELECTION,
    EDITOR_GOTO_DECL, EDITOR_GOTO_IMPL, EDITOR_GOTO_TYPE_DEF,
    EDITOR_NAV_BACK, EDITOR_NAV_FORWARD,
    EDITOR_OPEN_RECENT, EDITOR_PASTE, EDITOR_QUICK_OPEN, EDITOR_REDO,
    EDITOR_RENAME_SYMBOL,
    EDITOR_REPLACE, EDITOR_SAVE, EDITOR_SAVE_AS, EDITOR_TOGGLE_BLAME,
    EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT, EDITOR_TOGGLE_COMPRESS_KWARGS,
    EDITOR_TOGGLE_GIT_CHANGES,
    EDITOR_TOGGLE_LINE_NUMBERS, EDITOR_TOGGLE_MINIMAP,
    EDITOR_TOGGLE_STICKY_SCROLL,
    EDITOR_TOGGLE_TAB_BAR, EDITOR_UNDO,
    FILE_TREE_FOCUS, FILE_TREE_REVEAL,
    GIT_LOCAL_CHANGES, GIT_OPEN_ALL_CHANGED, GIT_REVIEW,
    HELP_HOTKEYS,
    PROJECT_FIND, PROJECT_OPEN, PROJECT_REPLACE, PROJECT_TREE_ACTION,
    TARGET_RUN, TARGET_TEST, TERMINAL_CLAUDE, TERMINAL_NEW,
    WINDOW_CLOSE, WINDOW_CLOSE_ALL,
    WINDOW_ROTATE_NEXT, WINDOW_ROTATE_PREV,
    synth_key_action,
)


# Host action: open a new Desktop window (Desktop returns it unclaimed).
comptime NEW_WINDOW = String("app.new_window")
# Host action: close the current window. Returned by "Close project" when
# the host owns the menu (one-project-per-window on macOS). Mirrors
# ``desktop._HOST_CLOSE_WINDOW_ACTION``.
comptime CLOSE_WINDOW = String("app.close_window")
# Host action: toggle the native "Floating panels" feature for this window.
# The host owns the windowing (it creates/destroys the separate panel
# window) and then calls ``tk_desktop_set_panels_detached`` to update the
# Desktop flag that drives the View-menu checkmark. See docs/floating-panels.md.
comptime TOGGLE_FLOATING_PANELS = String("app.toggle_floating_panels")

# Action codes returned to Swift. Everything else is handled inside Desktop.
comptime ACT_NONE                   = Int32(0)
comptime ACT_QUIT                   = Int32(1)
comptime ACT_OPEN_FILE              = Int32(2)
comptime ACT_QUICK_OPEN             = Int32(3)
comptime ACT_OPEN_PROJECT           = Int32(4)
comptime ACT_NEW_WINDOW             = Int32(5)
comptime ACT_CLOSE_WINDOW           = Int32(6)
comptime ACT_TOGGLE_FLOATING_PANELS = Int32(7)

# Mouse-button ids Swift passes (match events.mojo MOUSE_*).
comptime _MB_LEFT       = UInt8(1)
comptime _MB_MIDDLE     = UInt8(2)
comptime _MB_RIGHT      = UInt8(3)
comptime _MB_WHEEL_UP   = UInt8(4)
comptime _MB_WHEEL_DOWN = UInt8(5)


def _desk(h: Int) -> UnsafePointer[Desktop, MutExternalOrigin]:
    return UnsafePointer[Desktop, MutExternalOrigin](unsafe_from_address=h)


def _string_from(ptr: Int, n: Int) -> String:
    if ptr == 0 or n <= 0:
        return String("")
    var p = UnsafePointer[UInt8, MutExternalOrigin](unsafe_from_address=ptr)
    return String(StringSlice(ptr=p, length=n))


def _mk_menu(var label: String, *items: Tuple[String, String]) -> Menu:
    var list = List[MenuItem]()
    for it in items:
        list.append(MenuItem(it[0], it[1]))
    return Menu(label^, list^)


def _build_edit_items(has_extra_carets: Bool) -> List[MenuItem]:
    var e = List[MenuItem]()
    e.append(MenuItem(String("Undo"),  EDITOR_UNDO))
    e.append(MenuItem(String("Redo"),  EDITOR_REDO))
    e.append(MenuItem.separator())
    e.append(MenuItem(String("Cut"),   EDITOR_CUT))
    e.append(MenuItem(String("Copy"),  EDITOR_COPY))
    e.append(MenuItem(String("Paste"), EDITOR_PASTE))
    e.append(MenuItem(String("Compare selection with clipboard"), EDITOR_COMPARE_CLIPBOARD))
    if has_extra_carets:
        e.append(MenuItem(String("Fill..."), EDITOR_FILL))
    e.append(MenuItem.separator())
    e.append(MenuItem(String("Find..."),               EDITOR_FIND))
    e.append(MenuItem(String("Find Next"),             EDITOR_FIND_NEXT))
    e.append(MenuItem(String("Find Previous"),         EDITOR_FIND_PREV))
    e.append(MenuItem(String("Replace..."),            EDITOR_REPLACE))
    e.append(MenuItem(String("Find in project..."),    PROJECT_FIND))
    e.append(MenuItem(String("Replace in project..."), PROJECT_REPLACE))
    e.append(MenuItem(String("Go to Line..."),         EDITOR_GOTO))
    e.append(MenuItem(String("Go to Symbol..."),       EDITOR_GOTO_SYMBOL))
    e.append(MenuItem(String("Go to Type Definition"), EDITOR_GOTO_TYPE_DEF))
    e.append(MenuItem(String("Go to Implementation"),  EDITOR_GOTO_IMPL))
    e.append(MenuItem(String("Go to Declaration"),     EDITOR_GOTO_DECL))
    e.append(MenuItem(String("Rename Symbol..."),      EDITOR_RENAME_SYMBOL))
    e.append(MenuItem(String("Format Document"),       EDITOR_FORMAT_DOCUMENT))
    e.append(MenuItem(String("Format Selection"),      EDITOR_FORMAT_SELECTION))
    e.append(MenuItem(String("Look up in docs..."),    EDITOR_LOOKUP_DOCS))
    e.append(MenuItem(String("Toggle Comment"),        EDITOR_TOGGLE_COMMENT))
    e.append(MenuItem(String("Toggle Case"),           EDITOR_TOGGLE_CASE))
    return e^


def _build_menus(mut d: Desktop):
    var ham = List[MenuItem]()
    ham.append(MenuItem(String("Settings"), APP_SETTINGS))
    ham.append(MenuItem.separator())
    ham.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    d.menu_bar.add(Menu(String("≡"), ham^, is_system=True))
    d.menu_bar.add(_mk_menu(String("File"),
        (String("New"), EDITOR_NEW),
        (String("New window"), NEW_WINDOW),
        (String("New terminal pane"), TERMINAL_NEW),
        (String("New Claude pane"), TERMINAL_CLAUDE),
        (String("Open..."), EDITOR_OPEN),
        (String("Open project..."), PROJECT_OPEN),
        (String("Quick open..."), EDITOR_QUICK_OPEN),
        (String("Open recent..."), EDITOR_OPEN_RECENT),
        (String("Close"), WINDOW_CLOSE),
        (String("Close all"), WINDOW_CLOSE_ALL),
        (String("Save"), EDITOR_SAVE),
        (String("Save as..."), EDITOR_SAVE_AS),
    ))
    d.menu_bar.add(Menu(String("Edit"), _build_edit_items(False)))
    var v = List[MenuItem]()
    v.append(MenuItem(String("Line Numbers"), EDITOR_TOGGLE_LINE_NUMBERS, checkable=True))
    v.append(MenuItem(String("Git Changes"), EDITOR_TOGGLE_GIT_CHANGES, checkable=True))
    v.append(MenuItem(String("Tab Bar"), EDITOR_TOGGLE_TAB_BAR, checkable=True))
    v.append(MenuItem(String("Minimap"), EDITOR_TOGGLE_MINIMAP, checkable=True))
    v.append(MenuItem(
        String("Sticky Scroll"), EDITOR_TOGGLE_STICKY_SCROLL, checkable=True,
    ))
    v.append(MenuItem(
        String("Compress Keyword Args"), EDITOR_TOGGLE_COMPRESS_KWARGS,
        checkable=True,
    ))
    v.append(MenuItem.separator())
    # Three-way cycle (hidden → right → left); the label is re-stamped
    # from the live state every paint by ``_apply_view_config``, so this
    # initial text only has to match the no-tree default.
    v.append(MenuItem(String("File tree: hidden"), PROJECT_TREE_ACTION))
    v.append(MenuItem(String("Show in file tree"), FILE_TREE_REVEAL))
    # Native-only: float the tool panels (terminal / debug / test) into a
    # separate window. The terminal frontend builds its own menus
    # (examples/desktop.mojo), so this item is Swift-only by construction.
    v.append(MenuItem(String("Floating panels"), TOGGLE_FLOATING_PANELS, checkable=True))
    d.menu_bar.add(Menu(String("View"), v^))
    # Navigation — surfaces the cursor / window / symbol navigation hotkeys.
    # Items backed by a real action (Go to Line, Navigate Back, …) dispatch
    # directly; the editor-movement chords (Word Left, Grow Selection, …) use
    # ``synth_key_action`` so clicking them re-injects the chord into the
    # focused editor. Shortcut text auto-populates from ``_hotkeys`` via
    # ``_refresh_shortcuts``. Every item here matches a registered hotkey, so
    # the Keyboard Shortcuts page and this menu can't drift apart.
    var nav = List[MenuItem]()
    nav.append(MenuItem(String("Go to Line..."),    EDITOR_GOTO))
    nav.append(MenuItem(String("Go to Symbol..."),  EDITOR_GOTO_SYMBOL))
    nav.append(MenuItem(String("Find Symbol..."),   EDITOR_FIND_SYMBOL))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Find Next"),        EDITOR_FIND_NEXT))
    nav.append(MenuItem(String("Find Previous"),    EDITOR_FIND_PREV))
    nav.append(MenuItem(String("Navigate Back"),    EDITOR_NAV_BACK))
    nav.append(MenuItem(String("Navigate Forward"), EDITOR_NAV_FORWARD))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Word Left"),
        synth_key_action(KEY_LEFT, MOD_ALT)))
    nav.append(MenuItem(String("Word Right"),
        synth_key_action(KEY_RIGHT, MOD_ALT)))
    nav.append(MenuItem(String("Line Start"),
        synth_key_action(KEY_LEFT, MOD_META)))
    nav.append(MenuItem(String("Line End"),
        synth_key_action(KEY_RIGHT, MOD_META)))
    nav.append(MenuItem(String("Grow Selection"),
        synth_key_action(KEY_UP, MOD_META)))
    nav.append(MenuItem(String("Shrink Selection"),
        synth_key_action(KEY_DOWN, MOD_META)))
    nav.append(MenuItem(String("Add Caret Above"),
        synth_key_action(KEY_UP, MOD_CTRL | MOD_ALT)))
    nav.append(MenuItem(String("Add Caret Below"),
        synth_key_action(KEY_DOWN, MOD_CTRL | MOD_ALT)))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Previous Change"),
        synth_key_action(KEY_UP, MOD_CTRL | MOD_SHIFT)))
    nav.append(MenuItem(String("Next Change"),
        synth_key_action(KEY_DOWN, MOD_CTRL | MOD_SHIFT)))
    nav.append(MenuItem.separator())
    nav.append(MenuItem(String("Previous Window"), WINDOW_ROTATE_PREV))
    nav.append(MenuItem(String("Next Window"),     WINDOW_ROTATE_NEXT))
    nav.append(MenuItem(String("Focus File Tree"), FILE_TREE_FOCUS))
    nav.append(MenuItem(String("Focus Debug Pane"), DEBUG_FOCUS_PANE))
    d.menu_bar.add(Menu(String("Navigation"), nav^))
    d.menu_bar.add(_mk_menu(String("Git"),
        (String("Toggle Blame"), EDITOR_TOGGLE_BLAME),
        (String("Show diff viewer"), GIT_LOCAL_CHANGES),
        (String("Review changes…"), GIT_REVIEW),
        (String("Open all with changes"), GIT_OPEN_ALL_CHANGED),
    ))
    var dbg = List[MenuItem]()
    dbg.append(MenuItem(String("Run"), TARGET_RUN))
    dbg.append(MenuItem(String("Test"), TARGET_TEST))
    dbg.append(MenuItem.separator())
    dbg.append(MenuItem(String("Start / Continue"), DEBUG_START_OR_CONTINUE))
    dbg.append(MenuItem(String("Stop"), DEBUG_STOP))
    dbg.append(MenuItem(String("Toggle Breakpoint"), DEBUG_TOGGLE_BREAKPOINT))
    dbg.append(MenuItem(String("Conditional Breakpoint..."), DEBUG_CONDITIONAL_BP))
    dbg.append(MenuItem(String("Step Over"), DEBUG_STEP_OVER))
    dbg.append(MenuItem(String("Step Into"), DEBUG_STEP_IN))
    dbg.append(MenuItem(String("Step Out"), DEBUG_STEP_OUT))
    dbg.append(MenuItem(String("Add Watch..."), DEBUG_ADD_WATCH))
    dbg.append(MenuItem(String("Toggle Break on Raised"), DEBUG_TOGGLE_RAISED))
    d.menu_bar.add(Menu(String("Debug"), dbg^))
    # Help — rank 100, so it lands rightmost (see ``_menu_rank``). The
    # native frontend turns a menu titled "Help" into the standard macOS
    # Help menu (with the built-in menu-search field); see ``installMenu``
    # in TurboKod.swift. "Keyboard Shortcuts" opens the read-only
    # reference covering every binding, including the editor-level chords
    # (Cmd+Up/Down, …) that have no menu item of their own.
    d.menu_bar.add(_mk_menu(String("Help"),
        (String("Keyboard Shortcuts"), HELP_HOTKEYS),
    ))


def _refresh_menu_visibility(mut d: Desktop):
    # While a session restore is pending, the editor windows don't exist
    # yet — they're created in the first ``paint``/``_restore_session``,
    # which runs *after* this tick. Computing visibility now would see
    # ``focused_is_editor() == False`` and hide the Edit menu for one
    # frame, then the next tick re-shows it: a visible menu-bar flicker
    # right after the project window appears. Leave the menu in its built
    # default (Edit visible) until restore has run; the next tick computes
    # real visibility against the now-restored editor.
    if d._pending_restore:
        return
    var is_editor = d.windows.focused_is_editor()
    d.menu_bar.set_visible_by_label(String("Edit"), is_editor)
    # View stays reachable whenever a project is open (even with no
    # editor focused) — the file-tree cycle lives there now.
    var view_visible = is_editor
    if not view_visible and d.project:
        view_visible = True
    d.menu_bar.set_visible_by_label(String("View"), view_visible)
    # Keep the Floating-panels checkmark in lockstep with the live state.
    # The Desktop owns the flag, the host owns the window; this is the one
    # per-tick place both are reachable for the native menu snapshot.
    d.menu_bar.set_item_checked(TOGGLE_FLOATING_PANELS, d.panels_detached)
    var git_visible = is_editor
    if not git_visible and d.project:
        git_visible = True
    d.menu_bar.set_visible_by_label(String("Git"), git_visible)
    if not d.menu_bar.is_open():
        var has_extras = d.focused_editor_has_extra_carets()
        for i in range(len(d.menu_bar.menus)):
            if d.menu_bar.menus[i].label == String("Edit"):
                # Only rebuild when the Fill item's presence actually
                # changes. Swapping in fresh items every tick would drop
                # the shortcut text ``_refresh_shortcuts`` stamped on the
                # previous pass — and that stamper short-circuits when the
                # action set is unchanged, so it never re-applies them.
                var has_fill = False
                for it in range(len(d.menu_bar.menus[i].items)):
                    if d.menu_bar.menus[i].items[it].action == EDITOR_FILL:
                        has_fill = True
                        break
                if has_fill != has_extras:
                    d.menu_bar.menus[i].items = _build_edit_items(has_extras)
                break


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
def tk_recover_user_shell_path():
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
def tk_desktop_new() -> Int:
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
    var p = UnsafePointer[Desktop, MutExternalOrigin](unsafe_from_address=addr)
    p.init_pointee_move(Desktop())
    p[].load_config_from_disk()
    # ``TK_THEME`` overrides the saved theme for this process only (not
    # persisted) — used to capture doc screenshots in a specific theme, e.g.
    # ``TK_THEME=Dracula TK_CAPTURE=/tmp/x.png ./run_swift.sh``.
    var tk_theme = getenv_value(String("TK_THEME"))
    if len(tk_theme.as_bytes()) > 0:
        p[].active_theme = theme_by_name(tk_theme)
        p[].theme_version += 1
    _build_menus(p[])
    return addr


@export
def tk_desktop_free(h: Int):
    if h == 0:
        return
    var p = _desk(h)
    p.destroy_pointee()
    _ = external_call["free", Int](h)


@export
def tk_desktop_open_project(h: Int, path_ptr: Int, path_len: Int):
    if h == 0:
        return
    var path = _string_from(path_ptr, path_len)
    if len(path.as_bytes()) == 0:
        return
    _desk(h)[].open_project(path)


@export
def tk_desktop_open_file(h: Int, path_ptr: Int, path_len: Int, cols: Int, rows: Int):
    if h == 0:
        return
    var path = _string_from(path_ptr, path_len)
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
):
    """Open ``path`` and place the cursor at ``(line, character)`` — both
    0-based. Backs the ``turbokod://open?file=X&line=N`` URL scheme; the
    Swift host converts the URL's 1-based line to 0-based before calling."""
    if h == 0:
        return
    var path = _string_from(path_ptr, path_len)
    if len(path.as_bytes()) == 0:
        return
    try:
        _desk(h)[].open_file_at(path, line, character, Rect(0, 0, cols, rows))
    except e:
        print("turbokod: tk_desktop_open_file_at:", String(e))


@export
def tk_desktop_tick(h: Int, cols: Int, rows: Int):
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
    _refresh_menu_visibility(d)
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


def _pack_canvas(read canvas: Canvas, cols: Int, rows: Int, out_ptr: Int, cap: Int) -> Int:
    """Pack a laid-out canvas into the caller's ``UInt32`` buffer, 5 words
    per cell (``[codepoint, fg|bg<<8|style<<16|color_mode<<24, underline,
    fg_rgb, bg_rgb]``). Returns the number of cells written (clamped to
    ``cap``). Shared by the main and the floating-panels layout entry points
    so the packing format stays in one place."""
    var op = UnsafePointer[UInt32, MutExternalOrigin](unsafe_from_address=out_ptr)
    var n = cols * rows
    if n > cap:
        n = cap
    for i in range(n):
        var cell = canvas.cells[i]
        var cp = codepoint_at(cell.glyph, 0)[0]
        if cp <= 0:
            cp = 0x20
        var attr = cell.attr
        var w1 = UInt32(Int(attr.fg)) \
            | (UInt32(Int(attr.bg)) << 8) \
            | (UInt32(Int(attr.style)) << 16) \
            | (UInt32(Int(attr.color_mode)) << 24)
        var w2: UInt32
        if attr.underline_color < 0:
            w2 = UInt32(0xFFFFFFFF)
        else:
            w2 = UInt32(Int(attr.underline_color))
        op[i * 5] = UInt32(cp)
        op[i * 5 + 1] = w1
        op[i * 5 + 2] = w2
        op[i * 5 + 3] = attr.fg_rgb
        op[i * 5 + 4] = attr.bg_rgb
    return n


@export
def tk_desktop_layout(h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int) -> Int:
    """Paint the Desktop into a ``cols``x``rows`` grid and pack it into the
    caller's buffer (5 u32 per cell). Returns the number of cells written."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var canvas = Canvas(cols, rows)
    canvas.clear(default_attr())
    _desk(h)[].paint(canvas, Rect(0, 0, cols, rows))
    return _pack_canvas(canvas, cols, rows, out_ptr, cap)


@export
def tk_editor_scroll_regions(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int
) -> Int:
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
    var op = UnsafePointer[Int32, MutExternalOrigin](unsafe_from_address=out_ptr)
    var n = len(regions)
    if n > cap:
        n = cap
    for i in range(n):
        var r = regions[i]
        op[i * 9] = Int32(r.win_idx)
        op[i * 9 + 1] = Int32(r.interior.a.x)
        op[i * 9 + 2] = Int32(r.interior.a.y)
        op[i * 9 + 3] = Int32(r.interior.width())
        op[i * 9 + 4] = Int32(r.interior.height())
        op[i * 9 + 5] = Int32(r.sub)
        op[i * 9 + 6] = Int32(Int(r.frac * 1000.0))
        op[i * 9 + 7] = Int32(r.n_sticky)
        op[i * 9 + 8] = Int32(r.right_gutter)
    return n


@export
def tk_editor_region_layout(
    h: Int, win_idx: Int, region_cols: Int, region_rows: Int,
    out_ptr: Int, cap: Int,
) -> Int:
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
    canvas.clear(default_attr())
    _desk(h)[].paint_editor_region(
        win_idx, canvas, region_cols, region_rows, True,
    )
    return _pack_canvas(canvas, region_cols, region_rows, out_ptr, cap)


@export
def tk_editor_overlay_bounds(
    h: Int, cols: Int, rows: Int, out_ptr: Int
) -> Int:
    """Screen-cell bounds (box + drop shadow) of the focused editor's active
    screen-anchored overlay — the minimap/diagnostic/spell tooltip or the LSP
    hover popup. Writes ``[x, y, w, h]`` (Int32) to ``out_ptr`` and returns 1
    when one is up, 0 otherwise. The host re-blits this rect from the main
    frame on top of the smooth-scroll body overdraw (which suppresses overlays
    and would otherwise erase the popup)."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var b = _desk(h)[].focused_overlay_bounds(Rect(0, 0, cols, rows))
    if not b:
        return 0
    var r = b.value()
    var op = UnsafePointer[Int32, MutExternalOrigin](unsafe_from_address=out_ptr)
    op[0] = Int32(r.a.x)
    op[1] = Int32(r.a.y)
    op[2] = Int32(r.width())
    op[3] = Int32(r.height())
    return 1


@export
def tk_editor_smooth_begin(
    h: Int, win_idx: Int, cols: Int, rows: Int, out_ptr: Int
) -> Int:
    """Seed a smooth-scroll gesture on editor ``win_idx``. Writes two Int32
    words to ``out_ptr``: ``[cur_vis_milli, max_vis_milli]`` — the current
    vertical position and the maximum, as continuous *visual-row*
    coordinates × 1000. The host seeds its gesture from ``cur`` and clamps
    its rubber-band against ``max``. Returns 1 on success, 0 on bad args."""
    if h == 0 or out_ptr == 0:
        return 0
    var m = _desk(h)[].smooth_begin(win_idx, Rect(0, 0, cols, rows))
    var op = UnsafePointer[Int32, MutExternalOrigin](unsafe_from_address=out_ptr)
    op[0] = Int32(Int(m[0] * 1000.0))
    op[1] = Int32(Int(m[1] * 1000.0))
    return 1


@export
def tk_editor_smooth_set(
    h: Int, win_idx: Int, cols: Int, rows: Int, vis_milli: Int
):
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
def tk_editor_minimap_to(h: Int, win_idx: Int, frac_micro: Int):
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
def tk_desktop_vscroll_active(h: Int) -> Int:
    """1 while a window-border vertical-scrollbar thumb drag is in progress
    (the press landed on the thumb). The host polls this right after a
    mouse-down to decide whether to route subsequent motion through the
    sub-cell ``tk_desktop_vscroll_drag`` path instead of normal mouse
    events."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].vscroll_dragging() else 0


@export
def tk_desktop_vscroll_drag(h: Int, mouse_y_milli: Int) -> Int:
    """Continue the in-progress v-scrollbar thumb drag at a sub-cell pointer
    Y: ``mouse_y_milli`` is the pointer's fractional *cell row* × 1000 (raw
    pointer Y / cell height). Maps every line on a long file instead of the
    integer path's one-thumb-cell (~150-line) minimum. Returns 1 if a drag
    was active and consumed it, 0 otherwise."""
    if h == 0:
        return 0
    return 1 if _desk(h)[].vscroll_drag(Float64(mouse_y_milli) / 1000.0) else 0


@export
def tk_theme_version(h: Int) -> Int:
    """Monotonic counter that bumps whenever the active color theme changes.
    The Swift host polls this each frame and refetches the palette only when
    it moves — copying 256 ints every frame would be pointless churn."""
    if h == 0:
        return 0
    return _desk(h)[].theme_version


@export
def tk_theme_palette(h: Int, out_ptr: Int, cap: Int) -> Int:
    """Write the active theme's 256-entry RGB palette (packed ``0xRRGGBB``)
    into the caller's UInt32 buffer. Returns the number of entries written
    (256, clamped to ``cap``). Swift resolves cell color indices through this
    table, so this is how a theme retints the whole native UI."""
    if h == 0 or out_ptr == 0 or cap <= 0:
        return 0
    var op = UnsafePointer[UInt32, MutExternalOrigin](unsafe_from_address=out_ptr)
    var n = len(_desk(h)[].active_theme.palette)
    if n > cap:
        n = cap
    for i in range(n):
        op[i] = _desk(h)[].active_theme.palette[i]
    return n


@export
def tk_desktop_set_font_options(h: Int, ptr: Int, n: Int):
    """Register the monospace font families the host can render cells
    with — newline-separated UTF-8 family names. Their presence is what
    makes the Settings Font section appear; the terminal frontend never
    calls this. The built-in bitmap-font default row is added by the
    Mojo side, so the host passes only real system families."""
    if h == 0:
        return
    var text = _string_from(ptr, n)
    var names = List[String]()
    var lines = split_lines_no_trailing(text)
    for i in range(len(lines)):
        if len(lines[i].as_bytes()) > 0:
            names.append(lines[i])
    _desk(h)[].host_font_names = names^


@export
def tk_font_version(h: Int) -> Int:
    """Monotonic counter that bumps whenever ``config.font`` changes.
    The Swift host polls this each frame (like ``tk_theme_version``) and
    refetches the font name + rebuilds its cell font only when it moves."""
    if h == 0:
        return 0
    return _desk(h)[].font_version


@export
def tk_font_name(h: Int, out_ptr: Int, cap: Int) -> Int:
    """Write the configured font family name (UTF-8) into the caller's
    buffer and return the byte count. 0 means "use the built-in bitmap
    font" — the config's empty-string default."""
    if h == 0 or out_ptr == 0 or cap <= 0:
        return 0
    var bytes = _desk(h)[].config.font.as_bytes()
    var n = len(bytes)
    if n > cap:
        n = cap
    var op = UnsafePointer[UInt8, MutExternalOrigin](unsafe_from_address=out_ptr)
    for i in range(n):
        op[i] = bytes[i]
    return n


@export
def tk_font_size(h: Int) -> Int:
    """The configured cell-font point size. 0 means "the font's default
    size" — the host picks 16 for the bundled bitmap font, 13 for system
    monospace families. Polled together with ``tk_font_name`` whenever
    ``tk_font_version`` moves."""
    if h == 0:
        return 0
    return _desk(h)[].config.font_size


@export
def tk_desktop_set_font_size_info(h: Int, effective: Int, ideal: Int):
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
def tk_desktop_set_panels_detached(h: Int, on: Int):
    """Tell the Desktop its tool panels are rendered on a separate host
    window (the native "Floating panels" feature).

    When ``on`` is non-zero, the main surface (``paint`` / ``workspace_rect``
    / ``handle_event``) ignores the terminal / debug / test panels — the
    editor area reclaims the freed rows — and the host drives the second
    surface via ``tk_desktop_layout_panels`` + ``tk_desktop_panels_*``. Also
    flips the View ▸ Floating panels checkmark. See docs/floating-panels.md."""
    if h == 0:
        return
    _desk(h)[].panels_detached = on != 0


@export
def tk_desktop_panels_visible_count(h: Int) -> Int:
    """Number of tool panels currently open (terminal + debug + test).

    The host polls this to auto-hide the floating panel window when the last
    panel closes and re-show it when one reopens. See docs/floating-panels.md."""
    if h == 0:
        return 0
    return _desk(h)[].panels_visible_count()


@export
def tk_desktop_layout_panels(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) -> Int:
    """Paint *only* the tool panels into the host's separate panel window and
    pack them into the caller's buffer (same 5-u32-per-cell format as
    ``tk_desktop_layout``). Returns the number of cells written. The panel
    window does not run its own tick — the main window's ``tk_desktop_tick``
    drives the whole Desktop's per-frame work for both surfaces."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var canvas = Canvas(cols, rows)
    canvas.clear(default_attr())
    _desk(h)[].paint_panels(canvas, Rect(0, 0, cols, rows))
    return _pack_canvas(canvas, cols, rows, out_ptr, cap)


@export
def tk_desktop_panels_key(
    h: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int,
) -> Int32:
    """Route a keystroke from the panel window into the tool panels.
    Mirrors ``tk_desktop_key`` (same Ctrl/Cmd canonicalization and action
    codes), but dispatches through ``handle_panels_event``."""
    if h == 0:
        return ACT_NONE
    var k = _canon_ctrl_key(key, mods)
    var action: Optional[String]
    try:
        action = _desk(h)[].handle_panels_event(
            Event.key_event(k, mods), Rect(0, 0, cols, rows),
        )
    except e:
        print("turbokod: tk_desktop_panels_key:", String(e))
        action = Optional[String]()
    return _action_code(action)


@export
def tk_desktop_panels_mouse(
    h: Int, x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, cols: Int, rows: Int, click_count: UInt8,
) -> Int32:
    """Route a mouse event from the panel window into the tool panels.
    Mirrors ``tk_desktop_mouse`` but dispatches through
    ``handle_panels_event``."""
    if h == 0:
        return ACT_NONE
    var ev = Event.mouse_event(
        Point(x, y), button, pressed != 0, motion != 0, mods, click_count,
    )
    var action: Optional[String]
    try:
        action = _desk(h)[].handle_panels_event(ev, Rect(0, 0, cols, rows))
    except e:
        print("turbokod: tk_desktop_panels_mouse:", String(e))
        action = Optional[String]()
    return _action_code(action)


@export
def tk_desktop_panels_pointer_shape(
    h: Int, x: Int, y: Int, cols: Int, rows: Int,
) -> Int32:
    """0 = default, 1 = text, 2 = pointer — for the panel window."""
    if h == 0:
        return Int32(0)
    var shape = _desk(h)[].pointer_shape_panels(Point(x, y), Rect(0, 0, cols, rows))
    if shape == String("text"):
        return Int32(1)
    if shape == String("pointer"):
        return Int32(2)
    return Int32(0)


@export
def tk_desktop_panels_drop_paths(
    h: Int, x: Int, y: Int, paths_ptr: Int, paths_len: Int, cols: Int, rows: Int,
) -> Int32:
    """Host drag-and-drop onto the detached floating-panels window. Mirrors
    ``tk_desktop_drop_paths`` but routes through ``drop_text_on_panel`` (the
    panel-window layout)."""
    if h == 0:
        return Int32(0)
    var text = escape_drop_paths(_string_from(paths_ptr, paths_len))
    if len(text.as_bytes()) == 0:
        return Int32(0)
    if _desk(h)[].drop_text_on_panel(text, Point(x, y), Rect(0, 0, cols, rows)):
        return Int32(1)
    return Int32(0)


@export
def tk_desktop_panels_drop_target(
    h: Int, x: Int, y: Int, cols: Int, rows: Int,
) -> Int32:
    """Classify a drag-and-drop on the detached floating-panels window: 1 =
    terminal pane, 0 = nothing (the panels window has no editors, so never 2).
    Companion to ``tk_desktop_drop_target``."""
    if h == 0:
        return Int32(0)
    return Int32(
        _desk(h)[].drop_target_panel_at(Point(x, y), Rect(0, 0, cols, rows))
    )


# --- Settings window surface -------------------------------------------------
#
# The macOS host renders Settings in its own native window (like the floating
# panels): the main surface skips the in-grid overlay and stays interactive —
# which is what makes the live theme preview useful — while the host drives
# this surface. The host polls ``tk_desktop_settings_active`` each tick and
# opens/closes the NSWindow on transitions.


@export
def tk_desktop_set_settings_detached(h: Int, on: Int):
    """Tell the Desktop the Settings view is rendered on a separate host
    window. The terminal frontend never sets this — there Settings is a
    movable/resizable in-grid dialog."""
    if h == 0:
        return
    _desk(h)[].set_settings_detached(on != 0)


@export
def tk_desktop_settings_active(h: Int) -> Int32:
    """1 while the Settings view is open. The host polls this per tick and
    shows/hides its settings window on transitions (the Mojo side opens via
    the menu action and closes via Esc / the Close button, so the host can't
    know without asking)."""
    if h == 0:
        return Int32(0)
    if _desk(h)[].settings.active:
        return Int32(1)
    return Int32(0)


@export
def tk_desktop_take_attention(h: Int) -> Int32:
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
def tk_desktop_take_panel_focus_request(h: Int) -> Int32:
    """Drain the one-shot "focus the panel window" request. Returns 1
    exactly once after the user explicitly opens a new terminal pane,
    0 otherwise. When the tool panels float on their own window the host
    uses this to make that window key so the fresh shell is typeable
    without a click (the auto-show poll only ``orderFront``s). Harmless
    to poll while docked — the flag just clears."""
    if h == 0:
        return Int32(0)
    return Int32(1) if _desk(h)[].consume_panel_focus_request() else Int32(0)


@export
def tk_desktop_take_main_focus_request(h: Int) -> Int32:
    """Drain the one-shot "raise the main window" request. Returns 1
    exactly once after a deliberate open-at-line jump (an output-pane
    link click or a ``turbokod://`` command-line open), 0 otherwise. The
    host uses it to ``makeKeyAndOrderFront`` the editor's main window so a
    link clicked in the floating panels window doesn't leave the jumped-to
    code behind the panels. Harmless to poll while docked — the flag just
    clears."""
    if h == 0:
        return Int32(0)
    return Int32(1) if _desk(h)[].consume_main_focus_request() else Int32(0)


@export
def tk_desktop_debug_stopped(h: Int) -> Int32:
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
def tk_desktop_settings_close(h: Int):
    """Close the Settings view — the host calls this when the user closes
    the settings window via its native close button (the reverse direction
    of ``tk_desktop_settings_active``)."""
    if h == 0:
        return
    _desk(h)[].settings.close()


@export
def tk_desktop_layout_settings(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) -> Int:
    """Paint the Settings view into the host's settings window and pack it
    into the caller's buffer (same 5-u32-per-cell format as
    ``tk_desktop_layout``). Returns the number of cells written."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var canvas = Canvas(cols, rows)
    canvas.clear(default_attr())
    _desk(h)[].paint_settings(canvas, Rect(0, 0, cols, rows))
    return _pack_canvas(canvas, cols, rows, out_ptr, cap)


@export
def tk_desktop_settings_key(
    h: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int,
) -> Int32:
    """Route a keystroke from the settings window into the Settings view.
    Mirrors ``tk_desktop_key``'s Ctrl/Cmd canonicalization; Settings never
    produces host actions, so this always returns ACT_NONE."""
    if h == 0:
        return ACT_NONE
    var k = _canon_ctrl_key(key, mods)
    _desk(h)[].handle_settings_event(
        Event.key_event(k, mods), Rect(0, 0, cols, rows),
    )
    return ACT_NONE


@export
def tk_desktop_settings_mouse(
    h: Int, x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, cols: Int, rows: Int, click_count: UInt8,
) -> Int32:
    """Route a mouse event from the settings window into the Settings view."""
    if h == 0:
        return ACT_NONE
    var ev = Event.mouse_event(
        Point(x, y), button, pressed != 0, motion != 0, mods, click_count,
    )
    _desk(h)[].handle_settings_event(ev, Rect(0, 0, cols, rows))
    return ACT_NONE


# --- Project Settings window surface -----------------------------------------
#
# Twin of the Settings surface above: the macOS host renders Project Settings
# (On save / Targets / Grammars) in its own native window. The host polls
# ``tk_desktop_project_settings_active`` each tick and opens/closes the NSWindow
# on transitions. Keep this block in lock-step with the Settings block above.


@export
def tk_desktop_set_project_settings_detached(h: Int, on: Int):
    """Tell the Desktop the Project Settings view renders on a separate host
    window. The terminal frontend never sets this — there it's a
    movable/resizable in-grid dialog."""
    if h == 0:
        return
    _desk(h)[].set_project_settings_detached(on != 0)


@export
def tk_desktop_project_settings_active(h: Int) -> Int32:
    """1 while the Project Settings view is open. The host polls this per tick
    and shows/hides its window on transitions."""
    if h == 0:
        return Int32(0)
    if _desk(h)[].project_settings.active:
        return Int32(1)
    return Int32(0)


@export
def tk_desktop_project_settings_close(h: Int):
    """Close the Project Settings view — the host calls this when the user
    closes the window via its native close button."""
    if h == 0:
        return
    _desk(h)[].project_settings.close()


@export
def tk_desktop_layout_project_settings(
    h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) -> Int:
    """Paint the Project Settings view into the host's window and pack it into
    the caller's buffer (same 5-u32-per-cell format as ``tk_desktop_layout``).
    Returns the number of cells written."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var canvas = Canvas(cols, rows)
    canvas.clear(default_attr())
    _desk(h)[].paint_project_settings(canvas, Rect(0, 0, cols, rows))
    return _pack_canvas(canvas, cols, rows, out_ptr, cap)


@export
def tk_desktop_project_settings_key(
    h: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int,
) -> Int32:
    """Route a keystroke from the Project Settings window into the view.
    Project Settings never produces host actions, so this returns ACT_NONE."""
    if h == 0:
        return ACT_NONE
    var k = _canon_ctrl_key(key, mods)
    _desk(h)[].handle_project_settings_event(
        Event.key_event(k, mods), Rect(0, 0, cols, rows),
    )
    return ACT_NONE


@export
def tk_desktop_project_settings_mouse(
    h: Int, x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, cols: Int, rows: Int, click_count: UInt8,
) -> Int32:
    """Route a mouse event from the Project Settings window into the view."""
    if h == 0:
        return ACT_NONE
    var ev = Event.mouse_event(
        Point(x, y), button, pressed != 0, motion != 0, mods, click_count,
    )
    _desk(h)[].handle_project_settings_event(ev, Rect(0, 0, cols, rows))
    return ACT_NONE


@export
def tk_desktop_key(h: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int) -> Int32:
    if h == 0:
        return ACT_NONE
    # Canonicalize Ctrl/Cmd + uppercase letter to lowercase (matches the
    # terminal path so hotkey tables match regardless of frontend).
    var k = _canon_ctrl_key(key, mods)
    var action: Optional[String]
    try:
        action = _desk(h)[].handle_event(Event.key_event(k, mods), Rect(0, 0, cols, rows))
    except e:
        print("turbokod: tk_desktop_key:", String(e))
        action = Optional[String]()
    return _action_code(action)


@export
def tk_desktop_mod_key(h: Int, mod_id: UInt32, pressed: UInt8) -> Int32:
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
    var action: Optional[String]
    try:
        action = _desk(h)[].handle_event(
            Event.mod_key_event(mod_id, pressed != 0), Rect(0, 0, 0, 0),
        )
    except e:
        print("turbokod: tk_desktop_mod_key:", String(e))
        action = Optional[String]()
    return _action_code(action)


@export
def tk_desktop_mouse(
    h: Int, x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, cols: Int, rows: Int, click_count: UInt8,
) -> Int32:
    if h == 0:
        return ACT_NONE
    var ev = Event.mouse_event(
        Point(x, y), button, pressed != 0, motion != 0, mods, click_count,
    )
    var action: Optional[String]
    try:
        action = _desk(h)[].handle_event(ev, Rect(0, 0, cols, rows))
    except e:
        print("turbokod: tk_desktop_mouse:", String(e))
        action = Optional[String]()
    return _action_code(action)


@export
def tk_desktop_pointer_shape(h: Int, x: Int, y: Int, cols: Int, rows: Int) -> Int32:
    """0 = default, 1 = text, 2 = pointer."""
    if h == 0:
        return Int32(0)
    var shape = _desk(h)[].pointer_shape_at(Point(x, y), Rect(0, 0, cols, rows))
    if shape == String("text"):
        return Int32(1)
    if shape == String("pointer"):
        return Int32(2)
    return Int32(0)


@export
def tk_desktop_drop_paths(
    h: Int, x: Int, y: Int, paths_ptr: Int, paths_len: Int, cols: Int, rows: Int,
) -> Int32:
    """Host drag-and-drop of one or more files onto the *main* window.
    ``paths`` is a newline-separated list of absolute file paths. If a terminal
    pane sits under cell ``(x, y)``, the paths are shell-escaped, space-joined
    (``escape_drop_paths``) and injected as a bracketed paste — so a shell or
    Claude session running in that pane receives them exactly as a terminal
    emulator's drag-to-insert would. Returns 1 when a pane consumed the drop,
    else 0 (the host then leaves the OS drag unhandled)."""
    if h == 0:
        return Int32(0)
    var text = escape_drop_paths(_string_from(paths_ptr, paths_len))
    if len(text.as_bytes()) == 0:
        return Int32(0)
    if _desk(h)[].drop_text_on_pane(text, Point(x, y), Rect(0, 0, cols, rows)):
        return Int32(1)
    return Int32(0)


@export
def tk_desktop_drop_target(h: Int, x: Int, y: Int, cols: Int, rows: Int) -> Int32:
    """Classify a drag-and-drop landing at cell ``(x, y)`` on the *main*
    window: 1 = terminal pane, 2 = editor window body, 0 = nothing droppable.
    The host polls this during the drag (to set the copy/no-drop cursor) and on
    drop (to choose between the terminal paste path and the editor format-choice
    menu)."""
    if h == 0:
        return Int32(0)
    return Int32(_desk(h)[].drop_target_at(Point(x, y), Rect(0, 0, cols, rows)))


@export
def tk_desktop_insert_text(
    h: Int, x: Int, y: Int, text_ptr: Int, text_len: Int, cols: Int, rows: Int,
) -> Int32:
    """Insert ``text`` verbatim into the editor window under cell ``(x, y)``,
    placing the caret at the drop point first. Backs the editor branch of
    drag-and-drop: the host has already formatted the dropped path (full path /
    filename / project-relative) per the menu choice, so no escaping happens
    here. Returns 1 when an editor consumed it, else 0."""
    if h == 0:
        return Int32(0)
    var text = _string_from(text_ptr, text_len)
    if len(text.as_bytes()) == 0:
        return Int32(0)
    try:
        if _desk(h)[].drop_text_on_editor(text, Point(x, y), Rect(0, 0, cols, rows)):
            return Int32(1)
    except e:
        print("turbokod: tk_desktop_insert_text:", String(e))
    return Int32(0)


@export
def tk_desktop_paste_target_is_editor(h: Int) -> Int32:
    """1 when a paste should go to an editor (an editor window is focused and
    no terminal pane / file tree has keyboard focus). The host checks this
    before offering the file-path paste menu — see ``tk_desktop_paste_text``."""
    if h == 0:
        return Int32(0)
    return Int32(1) if _desk(h)[].paste_target_is_editor() else Int32(0)


@export
def tk_desktop_paste_text(h: Int, text_ptr: Int, text_len: Int) -> Int32:
    """Insert ``text`` verbatim at the focused editor's caret. Backs the
    file-path paste menu (Cmd+V of a file copied in Finder): the host has
    formatted the path per the menu choice, like the editor drop branch but at
    the current cursor rather than a drop point. Returns 1 when handled."""
    if h == 0:
        return Int32(0)
    var text = _string_from(text_ptr, text_len)
    if len(text.as_bytes()) == 0:
        return Int32(0)
    try:
        if _desk(h)[].insert_text_focused_editor(text):
            return Int32(1)
    except e:
        print("turbokod: tk_desktop_paste_text:", String(e))
    return Int32(0)


@export
def tk_desktop_paste_clipboard_text(h: Int, text_ptr: Int, text_len: Int) -> Int32:
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
    var text = _string_from(text_ptr, text_len)
    return Int32(1) if _desk(h)[].paste_text_into_focus(text) else Int32(0)


@export
def tk_desktop_has_project(h: Int) -> Int32:
    if h == 0:
        return Int32(0)
    return Int32(1) if _desk(h)[].project else Int32(0)


@export
def tk_desktop_set_host_owns_menu(h: Int, on: Int):
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
def tk_desktop_set_host_focused(h: Int, on: Int):
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
def tk_desktop_refresh_git(h: Int):
    """Force a git-state refresh: invalidate every editor's cached HEAD
    baseline so the change gutter re-diffs on the next paint, regardless of
    the cheap 1 Hz mtime poll. The host calls this on focus-gain (Cmd+Tab
    back) — the user may have run git operations or edited files in another
    app while we were backgrounded, and a worktree-only change doesn't move
    the ``.git/HEAD``/``.git/index`` mtimes the poll watches."""
    if h == 0:
        return
    _desk(h)[].force_git_refresh()


def _b(v: Bool) -> String:
    return String("1") if v else String("0")


@export
def tk_desktop_menu_snapshot(h: Int, out_ptr: Int, cap: Int) -> Int:
    """Serialize the current ``menu_bar`` into a flat TSV-shaped buffer.

    The host re-reads this every tick and rebuilds its native menu when
    the content changes (the cheap detection is a hash over the buffer).
    Format is one record per line, fields TAB-separated, all ASCII-safe:

      ``M\\t<label>\\t<visible>\\t<is_system>\\t<right_aligned>\\n``
      ``I\\t<label>\\t<action>\\t<is_separator>\\t<checkable>\\t<checked>\\t<shortcut>\\n``

    Booleans render as ``0``/``1``; missing strings render as empty
    fields. Items belong to the most-recently-emitted M record. Returns
    the number of bytes written; if it would exceed ``cap`` the buffer
    is truncated to ``cap`` and the host should grow its allocation
    and retry.
    """
    if h == 0 or out_ptr == 0 or cap <= 0:
        return 0
    ref bar = _desk(h)[].menu_bar
    var TAB = String("\t")
    var NL = String("\n")
    var text = String("")
    # Emit visible menus in painted left-to-right order — same rank-sorted
    # sequence the terminal frontend's MenuBar uses (system first, then
    # rank-ordered left-aligned, then right-aligned at the end). The host
    # appends them to NSMenu in this order, which puts e.g. Window second-
    # to-last (rank 90) and the project menu rightmost (right_aligned).
    var order = bar._display_order_indices()
    for k in range(len(order)):
        var mi = order[k]
        var m = bar.menus[mi].copy()
        text = text + String("M") + TAB + m.label + TAB \
             + _b(m.visible) + TAB + _b(m.is_system) + TAB \
             + _b(m.right_aligned) + NL
        for ii in range(len(m.items)):
            var it = m.items[ii]
            text = text + String("I") + TAB + it.label + TAB + it.action + TAB \
                 + _b(it.is_separator) + TAB + _b(it.checkable) + TAB \
                 + _b(it.checked) + TAB + it.shortcut + NL
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > cap:
        n = cap
    var op = UnsafePointer[UInt8, MutExternalOrigin](unsafe_from_address=out_ptr)
    for i in range(n):
        op[i] = bytes[i]
    return n


@export
def tk_desktop_menu_invoke(
    h: Int, action_ptr: Int, action_len: Int, cols: Int, rows: Int,
) -> Int32:
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
    var action = _string_from(action_ptr, action_len)
    if len(action.as_bytes()) == 0:
        return ACT_NONE
    var result = _desk(h)[].dispatch_action(action, Rect(0, 0, cols, rows))
    # ``dispatch_action`` returns the *unhandled* action string back to
    # the host (so it can route framework-level actions like Quit / Open
    # via its own UI). Map that the same way handle_event does.
    return _action_code(result)


@export
def tk_desktop_take_pending_new_window_project(
    h: Int, out_ptr: Int, cap: Int,
) -> Int:
    """Drain the "open this project in a new window" path queued by the
    Project menu's inline recent-project picks. Returns the number of
    UTF-8 bytes written into the caller's buffer; returns 0 when
    nothing is queued or the buffer can't hold the path (the latter
    leaves the path queued so the host can retry with a larger cap).

    The host calls this right after receiving ``ACT_NEW_WINDOW`` from
    ``tk_desktop_menu_invoke`` to discover whether the new-window
    request was a plain "File ▸ New window" pick (returns 0) or a
    recent-project pick that should land in a project-loaded window
    (returns the path)."""
    if h == 0 or out_ptr == 0 or cap <= 0:
        return 0
    # Peek before consuming so an undersized buffer leaves the path
    # in place for the caller to retry with a larger ``cap`` — a
    # truncated path would point somewhere wrong.
    ref pending = _desk(h)[]._pending_new_window_project
    if not pending:
        return 0
    var path = pending.value()
    var bytes = path.as_bytes()
    var n = len(bytes)
    if n > cap:
        return 0
    _desk(h)[]._pending_new_window_project = Optional[String]()
    var op = UnsafePointer[UInt8, MutExternalOrigin](unsafe_from_address=out_ptr)
    for i in range(n):
        op[i] = bytes[i]
    return n
