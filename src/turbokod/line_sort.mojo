"""Case-insensitive line sorting for Edit ▸ Sort Lines.

Two tiers, because case folding and collation are different problems:

1. **Locale collation** (macOS). Folding orders by codepoint, which is wrong
   for most languages with letters past ASCII — Swedish wants ``å ä ö`` after
   ``z`` (codepoint order gives ``ä å ö``), German wants ``ä`` beside ``a``.
   The shim's ``tk_collate_sort`` hands the lines to CoreFoundation with the
   user's current locale.
2. **Unicode case folding** everywhere else, or when the collator refuses
   (a line that isn't valid UTF-8): each line is folded once with libonig's
   tables and the folded keys are compared bytewise, which for UTF-8 is
   codepoint order.

Both are stable: lines that compare equal keep their relative order.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call

from .case_fold import fold_ascii, is_ascii
from .onig import unicode_case_fold


def sorted_lines_ci(rows: List[String]) -> List[String]:
    """``rows`` sorted case-insensitively: collated for the user's locale
    where the platform can, Unicode-folded otherwise."""
    var collated = sorted_lines_collated(rows, String(""))
    if collated:
        return collated.value().copy()
    return sorted_lines_folded(rows)


def sorted_lines_collated(
    rows: List[String], locale: String,
) -> Optional[List[String]]:
    """``rows`` sorted by the platform collator for ``locale`` (an identifier
    like ``sv_SE``; empty means the user's current locale). Empty when there
    is no collator — anywhere but macOS — or it refused the input."""
    var n = len(rows)
    var ptrs = List[Int](capacity=n)
    var lens = List[Int](capacity=n)
    for i in range(n):
        var b = rows[i].as_bytes()
        ptrs.append(Int(b.unsafe_ptr()))
        lens.append(len(b))
    var perm = List[Int](length=n, fill=0)
    var lb = locale.as_bytes()
    var ok = external_call["tk_collate_sort", Int32](
        ptrs.unsafe_ptr(), lens.unsafe_ptr(), n,
        lb.unsafe_ptr(), len(lb), perm.unsafe_ptr(),
    )
    if ok == 0:
        return Optional[List[String]]()
    return Optional[List[String]](_permuted(rows, perm))


def sorted_lines_folded(rows: List[String]) -> List[String]:
    """``rows`` sorted by their full Unicode case fold, in codepoint order."""
    var keys = List[String](capacity=len(rows))
    for i in range(len(rows)):
        keys.append(_fold(rows[i]))
    return _permuted(rows, _stable_order(keys))


def _fold(s: String) -> String:
    if is_ascii(s.as_bytes()):
        return fold_ascii(s)
    try:
        return unicode_case_fold(s)
    except:
        return fold_ascii(s)


def _less(a: String, b: String) -> Bool:
    """Bytewise ``a < b``; a proper prefix sorts first."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    for i in range(min(len(ab), len(bb))):
        if ab[i] != bb[i]:
            return ab[i] < bb[i]
    return len(ab) < len(bb)


def _stable_order(keys: List[String]) -> List[Int]:
    """Indices of ``keys`` in sorted order — a bottom-up merge sort, stable."""
    var n = len(keys)
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
                # Take from the right run only when strictly smaller, so
                # equal keys keep their original order.
                if i < mid and (j >= hi or not _less(keys[src[j]], keys[src[i]])):
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


def _permuted(rows: List[String], perm: List[Int]) -> List[String]:
    var out = List[String](capacity=len(perm))
    for i in range(len(perm)):
        out.append(rows[perm[i]])
    return out^
