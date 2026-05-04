"""Geometric primitives in character-cell coordinates.

Coordinates: x grows rightward, y grows downward, origin at (0, 0) in the top-left
of whatever surface owns the rect. All rectangles use a half-open convention:
``a`` is inclusive, ``b`` is exclusive — same as Python slices, easier than the
TurboVision C++ original.
"""

from std.collections.optional import Optional


@fieldwise_init
struct Point(ImplicitlyCopyable, Movable):
    var x: Int
    var y: Int

    fn __add__(self, other: Point) -> Point:
        return Point(self.x + other.x, self.y + other.y)

    fn __sub__(self, other: Point) -> Point:
        return Point(self.x - other.x, self.y - other.y)

    fn __eq__(self, other: Point) -> Bool:
        return self.x == other.x and self.y == other.y

    fn __ne__(self, other: Point) -> Bool:
        return not (self == other)

    fn to_string(self) -> String:
        return String("Point(") + String(self.x) + String(", ") + String(self.y) + String(")")


struct Rect(ImplicitlyCopyable, Movable):
    var a: Point  # top-left, inclusive
    var b: Point  # bottom-right, exclusive

    fn __init__(out self, a: Point, b: Point):
        self.a = a
        self.b = b

    fn __init__(out self, ax: Int, ay: Int, bx: Int, by: Int):
        self.a = Point(ax, ay)
        self.b = Point(bx, by)

    @staticmethod
    fn sized(origin: Point, width: Int, height: Int) -> Rect:
        return Rect(origin, Point(origin.x + width, origin.y + height))

    @staticmethod
    fn empty() -> Rect:
        return Rect(0, 0, 0, 0)

    fn width(self) -> Int:
        return self.b.x - self.a.x

    fn height(self) -> Int:
        return self.b.y - self.a.y

    fn is_empty(self) -> Bool:
        return self.a.x >= self.b.x or self.a.y >= self.b.y

    fn contains(self, p: Point) -> Bool:
        return self.a.x <= p.x and p.x < self.b.x and self.a.y <= p.y and p.y < self.b.y

    fn intersect(self, other: Rect) -> Rect:
        var ax = max(self.a.x, other.a.x)
        var ay = max(self.a.y, other.a.y)
        var bx = min(self.b.x, other.b.x)
        var by = min(self.b.y, other.b.y)
        if bx < ax:
            bx = ax
        if by < ay:
            by = ay
        return Rect(ax, ay, bx, by)

    fn union(self, other: Rect) -> Rect:
        if self.is_empty():
            return other
        if other.is_empty():
            return self
        return Rect(
            min(self.a.x, other.a.x), min(self.a.y, other.a.y),
            max(self.b.x, other.b.x), max(self.b.y, other.b.y),
        )

    fn translated(self, delta: Point) -> Rect:
        return Rect(self.a + delta, self.b + delta)

    fn inset(self, dx: Int, dy: Int) -> Rect:
        return Rect(self.a.x + dx, self.a.y + dy, self.b.x - dx, self.b.y - dy)

    fn __eq__(self, other: Rect) -> Bool:
        return self.a == other.a and self.b == other.b

    fn __ne__(self, other: Rect) -> Bool:
        return not (self == other)


fn compute_dialog_rect(
    screen: Rect, pos: Optional[Point], width: Int, height: Int,
) -> Rect:
    """Place a dialog of the requested ``width`` x ``height`` inside
    ``screen``. ``pos`` is the user-chosen top-left after a title-bar
    drag; when unset, the dialog auto-centers. Out-of-bounds positions
    are clamped so the title bar stays reachable after the user resizes
    the terminal smaller than the saved drag offset."""
    var w = width
    var h = height
    if w > screen.b.x - 4: w = screen.b.x - 4
    if h > screen.b.y - 4: h = screen.b.y - 4
    var x: Int
    var y: Int
    if pos:
        x = pos.value().x
        y = pos.value().y
        if x < 0: x = 0
        if y < 0: y = 0
        if x + w > screen.b.x: x = screen.b.x - w
        if y + h > screen.b.y: y = screen.b.y - h
    else:
        x = (screen.b.x - w) // 2
        y = (screen.b.y - h) // 2
    return Rect(x, y, x + w, y + h)
