"""One stable sort for the places that need one."""

from std.collections.list import List


def stable_order[
    T: Copyable, //, before: def(T, T) thin -> Bool
](items: List[T]) -> List[Int]:
    """The indices of ``items`` in ``before`` order — a bottom-up merge
    sort, so items neither is ``before`` the other keep their order."""
    var n = len(items)
    var src = List[Int](capacity=n)
    for i in range(n):
        src.append(i)
    var dst = src.copy()
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            for k in range(lo, hi):
                # Take from the right run only when strictly before, so
                # equal items keep their original order.
                if i < mid and (
                    j >= hi or not before(items[src[j]], items[src[i]])
                ):
                    dst[k] = src[i]
                    i += 1
                else:
                    dst[k] = src[j]
                    j += 1
            lo += 2 * width
        var t = src^
        src = dst^
        dst = t^
        width *= 2
    return src^
