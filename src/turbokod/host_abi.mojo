"""The wire format between the Mojo core and its C-ABI hosts.

``native_api.mojo`` (the core side) and each host — the Swift app and the
``tk-tui`` terminal binary (``app/tui/main.mojo``) — must agree on these
codes and on the packed-cell layout. Both sides import them from here
rather than mirroring them by hand. Deliberately light (canvas / cell /
colors only) so ``tk-tui`` can import it without pulling in ``Desktop``.
"""

from std.collections.list import List

from .canvas import Canvas
from .cell import Cell
from .colors import Attr
from .string_utils import codepoint_at


# Action codes an input entry point returns to the host. Everything else
# is handled inside Desktop.
comptime ACT_NONE                   = Int32(0)
comptime ACT_QUIT                   = Int32(1)
comptime ACT_OPEN_FILE              = Int32(2)
comptime ACT_QUICK_OPEN             = Int32(3)
comptime ACT_OPEN_PROJECT           = Int32(4)
comptime ACT_NEW_WINDOW             = Int32(5)
comptime ACT_CLOSE_WINDOW           = Int32(6)
comptime ACT_TOGGLE_FLOATING_PANELS = Int32(7)

# Pointer shapes reported by ``tk_desktop_pointer_shape``.
comptime SHAPE_DEFAULT = Int32(0)
comptime SHAPE_TEXT    = Int32(1)
comptime SHAPE_POINTER = Int32(2)
comptime SHAPE_NS_RESIZE = Int32(3)   # over a pane's top edge / dragging it
comptime SHAPE_EW_RESIZE = Int32(4)   # over the file tree's edge

# ``UInt32`` words per cell in the layout buffer:
# ``[codepoint, fg|bg<<8|style<<16|color_mode<<24, underline_color, fg_rgb,
# bg_rgb]``. ``app/swift/TurboKod.swift`` reads the same layout.
comptime CELL_WORDS = 5


def shape_code(shape: String) -> Int32:
    """Pointer-shape name (from ``Desktop.pointer_shape_at``) → wire code."""
    if shape == String("text"):
        return SHAPE_TEXT
    if shape == String("pointer"):
        return SHAPE_POINTER
    if shape == String("ns-resize"):
        return SHAPE_NS_RESIZE
    if shape == String("ew-resize"):
        return SHAPE_EW_RESIZE
    return SHAPE_DEFAULT


def shape_name(code: Int32) -> String:
    """Inverse of ``shape_code``."""
    if code == SHAPE_TEXT:
        return String("text")
    if code == SHAPE_POINTER:
        return String("pointer")
    if code == SHAPE_NS_RESIZE:
        return String("ns-resize")
    if code == SHAPE_EW_RESIZE:
        return String("ew-resize")
    return String("default")


def pack_canvas(
    imm canvas: Canvas, cols: Int, rows: Int, out_ptr: Int, cap: Int,
) -> Int:
    """Pack a laid-out canvas into the caller's ``UInt32`` buffer,
    ``CELL_WORDS`` per cell. Returns the number of cells written (clamped
    to ``cap``). The inverse of ``unpack_into``."""
    var op = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=out_ptr)
    var n = cols * rows
    if n > cap:
        n = cap
    for i in range(n):
        var base = i * CELL_WORDS
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
        op[unsafe_offset=base] = UInt32(cp)
        op[unsafe_offset=base + 1] = w1
        op[unsafe_offset=base + 2] = w2
        op[unsafe_offset=base + 3] = attr.fg_rgb
        op[unsafe_offset=base + 4] = attr.bg_rgb
    return n


def unpack_into(buf: List[UInt32], n: Int, mut canvas: Canvas):
    """Reconstruct a canvas from a ``pack_canvas`` buffer (the host side).

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
