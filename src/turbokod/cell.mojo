"""Screen cells: one logical character of output, with attribute and width.

A `Cell` carries one Unicode codepoint plus its display attribute. We store the
codepoint as a `String` rather than a fixed-width int so that grapheme clusters
(combining marks, emoji ZWJ sequences) can be handled at this layer later — for
now we treat each cell as exactly one Mojo `String` value, which the writer is
responsible for keeping to one or two terminal columns.

`width` is the number of terminal columns the glyph occupies (1 for normal,
2 for East-Asian fullwidth / many emoji, 0 for combining marks). For now we
default to 1 and leave width-detection as a TODO — see `cell_width()` below.
"""

from .colors import Attr, default_attr


struct Cell(ImplicitlyCopyable, Movable):
    var glyph: String
    var attr: Attr
    var width: Int

    fn __init__(out self):
        self.glyph = String(" ")
        self.attr = default_attr()
        self.width = 1

    fn __init__(out self, glyph: String, attr: Attr):
        self.glyph = glyph
        self.attr = attr
        self.width = cell_width(glyph)

    fn __init__(out self, glyph: String, attr: Attr, width: Int):
        self.glyph = glyph
        self.attr = attr
        self.width = width

    fn is_blank(self) -> Bool:
        return self.glyph == String(" ")

    fn __eq__(self, other: Cell) -> Bool:
        return self.glyph == other.glyph and self.attr == other.attr and self.width == other.width

    fn __ne__(self, other: Cell) -> Bool:
        return not (self == other)


fn cell_width(glyph: String) -> Int:
    """Best-effort terminal column width for a single grapheme.

    TODO: handle East-Asian wide characters and zero-width combiners properly.
    For now: 1 for any non-empty glyph, 0 for empty.
    """
    if len(glyph) == 0:
        return 0
    return 1


fn blank_cell() -> Cell:
    return Cell(String(" "), default_attr(), 1)
