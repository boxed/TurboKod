"""``diff_lines``: a correct edit script, short when it can be, and cheap on
big rewrites (it runs on every paint while typing, for the change gutter)."""

from std.testing import TestSuite, assert_equal, assert_true
from turbokod.diff import OP_DELETE, OP_EQUAL, OP_INSERT, diff_lines


def _check(a: List[String], b: List[String]) raises -> Int:
    """Apply the script to ``a``: it must give ``b``, in order. Returns the
    number of deletes and inserts."""
    var ops = diff_lines(a, b)
    var out = List[String]()
    var ai = 0
    var bi = 0
    var edits = 0
    for op in ops:
        if op.kind == OP_EQUAL:
            assert_equal(op.a_index, ai)
            assert_equal(op.b_index, bi)
            assert_equal(a[ai], b[bi])
            out.append(a[ai])
            ai += 1
            bi += 1
        elif op.kind == OP_DELETE:
            assert_equal(op.a_index, ai)
            ai += 1
            edits += 1
        else:
            assert_equal(op.kind, OP_INSERT)
            assert_equal(op.b_index, bi)
            out.append(b[bi])
            bi += 1
            edits += 1
    assert_equal(ai, len(a))
    assert_equal(bi, len(b))
    assert_equal(len(out), len(b))
    for i in range(len(b)):
        assert_equal(out[i], b[i])
    return edits


def _lines(spec: String) -> List[String]:
    var out = List[String]()
    for c in spec.codepoint_slices():
        out.append(String(c))
    return out^


def test_small_cases_give_shortest_scripts() raises:
    assert_equal(_check(_lines(""), _lines("")), 0)
    assert_equal(_check(_lines("abc"), _lines("abc")), 0)
    assert_equal(_check(_lines(""), _lines("ab")), 2)
    assert_equal(_check(_lines("ab"), _lines("")), 2)
    assert_equal(_check(_lines("abcabba"), _lines("cbabac")), 5)
    assert_equal(_check(_lines("xabcx"), _lines("xacbx")), 2)
    assert_equal(_check(_lines("aaaab"), _lines("baaaa")), 2)
    assert_equal(_check(_lines("abcdef"), _lines("abXdeY")), 4)
    assert_equal(_check(_lines("prefix-middle-suffix"), _lines("prefix-MIDDLE-suffix")), 12)


def test_many_mixed_cases_are_correct() raises:
    # deterministic pseudo-random edits of a small alphabet
    var seed = 12345
    for _ in range(300):
        var a = List[String]()
        var b = List[String]()
        seed = (seed * 1103515245 + 12345) % 2147483648
        var na = seed % 12
        seed = (seed * 1103515245 + 12345) % 2147483648
        var nb = seed % 12
        for _ in range(na):
            seed = (seed * 1103515245 + 12345) % 2147483648
            a.append(String(chr(97 + seed % 3)))
        for _ in range(nb):
            seed = (seed * 1103515245 + 12345) % 2147483648
            b.append(String(chr(97 + seed % 3)))
        _ = _check(a, b)


def test_a_big_rewrite_is_still_a_correct_script() raises:
    # every other line of 20000 changed, as after a formatter run: too
    # many differences for a precise diff, so it may be coarser, but it
    # must still be right
    var a = List[String]()
    var b = List[String]()
    for i in range(20000):
        a.append("line " + String(i))
        b.append(("line " + String(i)) if i % 2 == 0 else ("changed " + String(i)))
    _ = _check(a, b)


def test_a_small_edit_in_a_big_file_stays_precise() raises:
    var a = List[String]()
    for i in range(20000):
        a.append("line " + String(i))
    var b = a.copy()
    b[10000] = "edited"
    b.append("appended")
    assert_equal(_check(a, b), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
