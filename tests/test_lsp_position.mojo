"""Byte columns to and from a language server's UTF-8/16/32 columns: wrong
by one, and every edit a server sends lands in the wrong place."""

from std.testing import TestSuite, assert_equal
from turbokod.lsp_position import (
    LineTable, POS_UTF16, POS_UTF32, POS_UTF8, byte_to_units, line_units, units_to_byte,
)


def test_the_first_character_past_the_bmp_is_two_utf16_units() raises:
    var line = "a" + chr(0x10000) + "b"  # 1 + 4 + 1 bytes
    assert_equal(byte_to_units(line, 5, POS_UTF16), 3)
    assert_equal(units_to_byte(line, 3, POS_UTF16), 5)
    assert_equal(line_units(line, POS_UTF16), 4)
    assert_equal(line_units(line, POS_UTF32), 3)
    var last_bmp = "a" + chr(0xFFFF) + "b"  # 1 + 3 + 1 bytes
    assert_equal(byte_to_units(last_bmp, 4, POS_UTF16), 2)


def test_columns_out_of_range_are_clamped() raises:
    var line = String("aé")  # 3 bytes
    for enc in [POS_UTF8, POS_UTF16, POS_UTF32]:
        assert_equal(byte_to_units(line, -1, enc), 0)
        assert_equal(units_to_byte(line, -1, enc), 0)
        assert_equal(units_to_byte(line, 99, enc), 3)
    assert_equal(byte_to_units(line, 99, POS_UTF8), 3)
    assert_equal(byte_to_units(line, 99, POS_UTF16), 2)
    # exactly the end, after a multi-byte character
    assert_equal(byte_to_units(line, 3, POS_UTF16), 2)
    assert_equal(units_to_byte(line, 2, POS_UTF16), 3)


def test_a_line_past_the_table() raises:
    var t = LineTable(String("ab\ncd"))
    assert_equal(t.row_count(), 2)
    assert_equal(t.line(1), String("cd"))
    assert_equal(t.line(2), String(""))
    assert_equal(t.line(-1), String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
