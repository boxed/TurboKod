"""Screen cells: one logical character of output, with attribute and width.

A `Cell` carries one Unicode codepoint plus its display attribute. We store the
codepoint as a `String` rather than a fixed-width int so that grapheme clusters
(combining marks, emoji ZWJ sequences) can be handled at this layer later — for
now we treat each cell as exactly one Mojo `String` value, which the writer is
responsible for keeping to one or two terminal columns.

`width` is the number of terminal columns the glyph occupies: ``1`` for
normal cells, ``2`` for emoji (the continuation half is a ``width=0`` blank),
``0`` for the empty continuation cell itself. Width is derived from the glyph
by `cell_width()` below, which delegates to `char_width` so it stays in lock
step with `Canvas.put_text`. East-Asian fullwidth and zero-width combining
marks are not yet modeled — only emoji widen.
"""

from .colors import Attr, default_attr
from .string_utils import char_width, codepoint_at


struct Cell(ImplicitlyCopyable, Movable):
    var glyph: String
    var attr: Attr
    var width: Int

    def __init__(out self):
        self.glyph = String(" ")
        self.attr = default_attr()
        self.width = 1

    def __init__(out self, glyph: String, attr: Attr):
        self.glyph = glyph
        self.attr = attr
        self.width = cell_width(glyph)

    def __init__(out self, glyph: String, attr: Attr, width: Int):
        self.glyph = glyph
        self.attr = attr
        self.width = width

    def is_blank(self) -> Bool:
        return self.glyph == String(" ")

    def __eq__(self, other: Cell) -> Bool:
        return self.glyph == other.glyph and self.attr == other.attr and self.width == other.width

    def __ne__(self, other: Cell) -> Bool:
        return not (self == other)


def cell_width(glyph: String) -> Int:
    """Terminal column width for a single grapheme: ``0`` for empty (the
    continuation half of a wide glyph), ``2`` for emoji, ``1`` otherwise.

    Delegates to ``char_width`` on the first codepoint so widths stay
    consistent with ``Canvas.put_text`` and the editor's cell maps.
    East-Asian fullwidth and zero-width combiners are still unmodeled.
    """
    if glyph.byte_length() == 0:
        return 0
    return char_width(codepoint_at(glyph, 0)[0])


def blank_cell() -> Cell:
    return Cell(String(" "), default_attr(), 1)
