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
crosses as a caller-provided ``UInt32`` buffer, 3 words per cell:
``[codepoint, fg | bg<<8 | style<<16, underline_color (0xFFFFFFFF = use fg)]``
— the same packing the (now-retired) Rust path used.
"""

from std.ffi import external_call
from std.sys import size_of

from turbokod.canvas import Canvas
from turbokod.colors import default_attr
from turbokod.events import (
    Event, MOD_CTRL, MOD_META,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT,
    MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN,
)
from turbokod.geometry import Point, Rect
from turbokod.menu import Menu, MenuItem
from turbokod.posix import (
    getenv_value, recover_user_path_for_gui_launch, setenv_value,
)
from turbokod.string_utils import codepoint_at
from turbokod.desktop import (
    Desktop,
    APP_QUIT_ACTION, APP_SETTINGS,
    DEBUG_ADD_WATCH, DEBUG_CONDITIONAL_BP, DEBUG_START_OR_CONTINUE,
    DEBUG_STEP_IN, DEBUG_STEP_OUT, DEBUG_STEP_OVER, DEBUG_STOP,
    DEBUG_TOGGLE_BREAKPOINT, DEBUG_TOGGLE_RAISED,
    EDITOR_COMPARE_CLIPBOARD, EDITOR_COPY, EDITOR_CUT, EDITOR_FILL,
    EDITOR_FIND, EDITOR_FIND_NEXT, EDITOR_FIND_PREV, EDITOR_GOTO,
    EDITOR_GOTO_SYMBOL, EDITOR_LOOKUP_DOCS, EDITOR_NEW, EDITOR_OPEN,
    EDITOR_OPEN_RECENT, EDITOR_PASTE, EDITOR_QUICK_OPEN, EDITOR_REDO,
    EDITOR_REPLACE, EDITOR_SAVE, EDITOR_SAVE_AS, EDITOR_TOGGLE_BLAME,
    EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT, EDITOR_TOGGLE_GIT_CHANGES,
    EDITOR_TOGGLE_LINE_NUMBERS, EDITOR_TOGGLE_MINIMAP, EDITOR_TOGGLE_SOFT_WRAP,
    EDITOR_TOGGLE_TAB_BAR, EDITOR_UNDO,
    GIT_LOCAL_CHANGES, GIT_OPEN_ALL_CHANGED,
    PROJECT_FIND, PROJECT_OPEN, PROJECT_REPLACE,
    TARGET_RUN, TERMINAL_NEW, WINDOW_CLOSE, WINDOW_CLOSE_ALL,
)


# Host action: open a new Desktop window (Desktop returns it unclaimed).
comptime NEW_WINDOW = String("app.new_window")

# Action codes returned to Swift. Everything else is handled inside Desktop.
comptime ACT_NONE         = Int32(0)
comptime ACT_QUIT         = Int32(1)
comptime ACT_OPEN_FILE    = Int32(2)
comptime ACT_QUICK_OPEN   = Int32(3)
comptime ACT_OPEN_PROJECT = Int32(4)
comptime ACT_NEW_WINDOW   = Int32(5)

# Mouse-button ids Swift passes (match events.mojo MOUSE_*).
comptime _MB_LEFT       = UInt8(1)
comptime _MB_MIDDLE     = UInt8(2)
comptime _MB_RIGHT      = UInt8(3)
comptime _MB_WHEEL_UP   = UInt8(4)
comptime _MB_WHEEL_DOWN = UInt8(5)


fn _desk(h: Int) -> UnsafePointer[Desktop, MutExternalOrigin]:
    return UnsafePointer[Desktop, MutExternalOrigin](unsafe_from_address=h)


fn _string_from(ptr: Int, n: Int) -> String:
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
    v.append(MenuItem(String("Soft Wrap"), EDITOR_TOGGLE_SOFT_WRAP, checkable=True))
    v.append(MenuItem(String("Git Changes"), EDITOR_TOGGLE_GIT_CHANGES, checkable=True))
    v.append(MenuItem(String("Tab Bar"), EDITOR_TOGGLE_TAB_BAR, checkable=True))
    v.append(MenuItem(String("Minimap"), EDITOR_TOGGLE_MINIMAP, checkable=True))
    d.menu_bar.add(Menu(String("View"), v^))
    d.menu_bar.add(_mk_menu(String("Git"),
        (String("Toggle Blame"), EDITOR_TOGGLE_BLAME),
        (String("Show diff viewer"), GIT_LOCAL_CHANGES),
        (String("Open all with changes"), GIT_OPEN_ALL_CHANGED),
    ))
    var dbg = List[MenuItem]()
    dbg.append(MenuItem(String("Run"), TARGET_RUN))
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


def _refresh_menu_visibility(mut d: Desktop):
    var is_editor = d.windows.focused_is_editor()
    d.menu_bar.set_visible_by_label(String("Edit"), is_editor)
    d.menu_bar.set_visible_by_label(String("View"), is_editor)
    var git_visible = is_editor
    if not git_visible and d.project:
        git_visible = True
    d.menu_bar.set_visible_by_label(String("Git"), git_visible)
    if not d.menu_bar.is_open():
        var has_extras = d.focused_editor_has_extra_carets()
        for i in range(len(d.menu_bar.menus)):
            if d.menu_bar.menus[i].label == String("Edit"):
                d.menu_bar.menus[i].items = _build_edit_items(has_extras)
                break


fn _action_code(action: Optional[String]) -> Int32:
    if not action:
        return ACT_NONE
    var a = action.value()
    if a == APP_QUIT_ACTION:   return ACT_QUIT
    if a == EDITOR_OPEN:       return ACT_OPEN_FILE
    if a == EDITOR_QUICK_OPEN: return ACT_QUICK_OPEN
    if a == PROJECT_OPEN:      return ACT_OPEN_PROJECT
    if a == NEW_WINDOW:        return ACT_NEW_WINDOW
    return ACT_NONE


# --- C ABI ------------------------------------------------------------------

# Process-local "did we already repair PATH?" flag. Mojo has no module-level
# mutable globals, so we stash the flag in our own environment via setenv —
# cheap, persists across @export calls in the same process, and the
# allowlisted-envp builder in lsp.mojo doesn't forward this name to children
# (it carries no leading-underscore allowlist hit), so LSP servers don't see
# our internal bookkeeping.
comptime _PATH_RECOVERY_MARKER = String("__TURBOKOD_PATH_RECOVERED")


fn _recover_path_once():
    """Run GUI-launch PATH recovery on the first call; no-op afterward.

    Called from ``tk_desktop_new`` so the repair is in place before any
    Desktop method that might ``posix_spawnp`` a child (LSP servers,
    ``rg``, ``git``) — and so the Swift host doesn't have to know it
    exists. Swallows exceptions: a failed recovery just means children
    inherit the launch-time PATH, which is the same fallback we'd have
    without this function at all."""
    var marker = getenv_value(_PATH_RECOVERY_MARKER)
    if len(marker.as_bytes()) > 0:
        return
    try:
        recover_user_path_for_gui_launch()
        _ = setenv_value(_PATH_RECOVERY_MARKER, String("1"))
    except:
        pass


@export
fn tk_desktop_new() -> Int:
    """Create a Desktop on the heap, load config + standard menus, return the
    opaque handle."""
    # macOS Dock/launchd launches give us a stripped ``PATH`` that lacks
    # per-user dirs (``~/.cargo/bin``, ``~/.pyenv/shims``, …) — the LSP
    # spawn path forwards our PATH verbatim to children, so a Dock launch
    # otherwise can't find ``ty-semantic`` / ``pyright`` even though
    # they're on the user's interactive PATH. Idempotent + once-guarded,
    # so multi-window callers don't re-run the login shell each time.
    _recover_path_once()
    var addr = external_call["malloc", Int](size_of[Desktop]())
    if addr == 0:
        return 0
    var p = UnsafePointer[Desktop, MutExternalOrigin](unsafe_from_address=addr)
    p.init_pointee_move(Desktop())
    try:
        p[].load_config_from_disk()
        _build_menus(p[])
    except:
        pass
    return addr


@export
fn tk_desktop_free(h: Int):
    if h == 0:
        return
    var p = _desk(h)
    p.destroy_pointee()
    _ = external_call["free", Int](h)


@export
fn tk_desktop_open_project(h: Int, path_ptr: Int, path_len: Int):
    if h == 0:
        return
    var path = _string_from(path_ptr, path_len)
    if len(path.as_bytes()) == 0:
        return
    try:
        _desk(h)[].open_project(path)
    except:
        pass


@export
fn tk_desktop_open_file(h: Int, path_ptr: Int, path_len: Int, cols: Int, rows: Int):
    if h == 0:
        return
    var path = _string_from(path_ptr, path_len)
    if len(path.as_bytes()) == 0:
        return
    try:
        _desk(h)[].open_file(path, Rect(0, 0, cols, rows))
    except:
        pass


@export
fn tk_desktop_tick(h: Int, cols: Int, rows: Int):
    """Per-frame housekeeping Swift runs before laying out: external-change
    reload, menu visibility, file-tree opens, and the LSP/DAP/autosave
    ticks."""
    if h == 0:
        return
    var screen = Rect(0, 0, cols, rows)
    ref d = _desk(h)[]
    try:
        d.process_external_changes(screen)
    except:
        pass
    _refresh_menu_visibility(d)
    var tree_open = d.file_tree.consume_open()
    if tree_open:
        try:
            d.open_file(tree_open.value(), screen)
        except:
            pass
    d.lsp_tick(screen)
    d.dap_tick(screen)
    d.terminal_tick()
    d.save_actions_tick()


@export
fn tk_desktop_layout(h: Int, cols: Int, rows: Int, out_ptr: Int, cap: Int) -> Int:
    """Paint the Desktop into a ``cols``x``rows`` grid and pack it into the
    caller's buffer (3 u32 per cell). Returns the number of cells written."""
    if h == 0 or out_ptr == 0 or cols <= 0 or rows <= 0:
        return 0
    var canvas = Canvas(cols, rows)
    canvas.clear(default_attr())
    _desk(h)[].paint(canvas, Rect(0, 0, cols, rows))
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
            | (UInt32(Int(attr.style)) << 16)
        var w2: UInt32
        if attr.underline_color < 0:
            w2 = UInt32(0xFFFFFFFF)
        else:
            w2 = UInt32(Int(attr.underline_color))
        op[i * 3] = UInt32(cp)
        op[i * 3 + 1] = w1
        op[i * 3 + 2] = w2
    return n


@export
fn tk_desktop_key(h: Int, key: UInt32, mods: UInt8, cols: Int, rows: Int) -> Int32:
    if h == 0:
        return ACT_NONE
    # Canonicalize Ctrl/Cmd + uppercase letter to lowercase (matches the
    # terminal path so hotkey tables match regardless of frontend).
    var k = key
    if (mods & MOD_CTRL) != 0 or (mods & MOD_META) != 0:
        if k >= UInt32(0x41) and k <= UInt32(0x5A):
            k = k + UInt32(0x20)
    var action: Optional[String]
    try:
        action = _desk(h)[].handle_event(Event.key_event(k, mods), Rect(0, 0, cols, rows))
    except:
        action = Optional[String]()
    return _action_code(action)


@export
fn tk_desktop_mouse(
    h: Int, x: Int, y: Int, button: UInt8, pressed: UInt8, motion: UInt8,
    mods: UInt8, cols: Int, rows: Int,
) -> Int32:
    if h == 0:
        return ACT_NONE
    var ev = Event.mouse_event(
        Point(x, y), button, pressed != 0, motion != 0, mods,
    )
    var action: Optional[String]
    try:
        action = _desk(h)[].handle_event(ev, Rect(0, 0, cols, rows))
    except:
        action = Optional[String]()
    return _action_code(action)


@export
fn tk_desktop_pointer_shape(h: Int, x: Int, y: Int, cols: Int, rows: Int) -> Int32:
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
fn tk_desktop_has_project(h: Int) -> Int32:
    if h == 0:
        return Int32(0)
    return Int32(1) if _desk(h)[].project else Int32(0)
