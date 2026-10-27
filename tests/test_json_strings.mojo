"""JSON strings: unsaved drafts and the config are stored as JSON, so text
must come back exactly as it went in, and a damaged file must be an error,
not a read past its end."""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true
from turbokod.json import encode_json, json_str, parse_json, read_int_pair, read_int_quad


def _parse_str(text: String) raises -> String:
    return parse_json(text).as_str()


def test_control_characters_are_escaped() raises:
    assert_equal(
        encode_json(json_str("a\x08\x0c\n\r\t\x01\x1f \"\\/b")),
        "\"a\\b\\f\\n\\r\\t\\u0001\\u001f \\\"\\\\/b\"",
    )


def test_every_ascii_character_round_trips() raises:
    var s = String("")
    for c in range(1, 128):
        s += chr(c)
    s += "é — 😀 漢字"
    assert_equal(_parse_str(encode_json(json_str(s))), s)


def test_escapes_are_decoded() raises:
    assert_equal(_parse_str("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\""), "\"\\/\x08\x0c\n\r\t")
    assert_equal(_parse_str("\"\\u00e9\\u2014\""), "é—")


def test_a_surrogate_pair_is_one_character() raises:
    assert_equal(_parse_str("\"\\ud83d\\ude00\""), "😀")
    assert_equal(_parse_str("\"\\ud800\\udc00\""), chr(0x10000))
    assert_equal(_parse_str("\"\\udbff\\udfff\""), chr(0x10FFFF))


def test_a_lone_surrogate_becomes_a_replacement_character() raises:
    assert_equal(_parse_str("\"\\ud83dx\""), "\ufffdx")
    assert_equal(_parse_str("\"\\ud83d\\u0041\""), "\ufffdA")
    assert_equal(_parse_str("\"\\ude00\""), "\ufffd")
    assert_equal(_parse_str("\"\\udfff\""), "\ufffd")
    assert_equal(_parse_str("\"\\udbffx\""), "\ufffdx")
    # just outside the surrogate range
    assert_equal(_parse_str("\"\\ud7ff\\ue000\""), chr(0xD7FF) + chr(0xE000))
    # the edges of the low half
    assert_equal(_parse_str("\"\\udc00\""), "\ufffd")
    assert_equal(_parse_str("\"\\udc00\\udc00\""), "\ufffd\ufffd")
    assert_equal(_parse_str("\"\\ud800\\ue000\""), "\ufffd" + chr(0xE000))
    # what follows a high surrogate is only a low one when it's an escape
    assert_equal(_parse_str("\"\\ud83dxudc00\""), "\ufffdxudc00")
    assert_equal(_parse_str("\"\\ud83dabxyzw\""), "\ufffdabxyzw")


def test_broken_strings_are_errors() raises:
    with assert_raises():
        _ = parse_json("\"abc")
    with assert_raises():
        _ = parse_json("\"\\")
    with assert_raises():
        _ = parse_json("\"\\u00\"")
    with assert_raises():
        _ = parse_json("\"a\nb\"")
    with assert_raises():
        _ = parse_json("{a\": 1}")


def test_truncated_escapes_are_errors() raises:
    with assert_raises():
        _ = parse_json("\"\\u00e")
    with assert_raises():
        _ = parse_json("\"\\ud83d\\ude0")
    with assert_raises():
        _ = parse_json("\"\\ud83d\\u")


def test_windows_line_endings_are_whitespace() raises:
    var v = parse_json("{\r\n  \"a\": [1,\r\n 2]\r\n}\r\n")
    assert_equal(v.object_get("a").value().array_len(), 2)


def test_out_of_range_items_are_null() raises:
    var arr = parse_json("[1, 2]")
    assert_true(arr.array_at(-1).is_null())
    assert_true(arr.array_at(2).is_null())
    assert_equal(arr.array_at(1).as_int(), 2)
    var obj = parse_json("{\"a\": 1, \"b\": 2}")
    assert_equal(obj.object_key_at(-1), "")
    assert_equal(obj.object_key_at(2), "")
    assert_equal(obj.object_key_at(1), "b")
    assert_true(obj.object_value_at(-1).is_null())
    assert_true(obj.object_value_at(2).is_null())
    assert_equal(obj.object_value_at(1).as_int(), 2)


def test_int_pairs_and_quads_fall_back_on_anything_else() raises:
    var obj = parse_json(
        "{\"ok\": [3, 4], \"short\": [3], \"str\": [3, \"4\"], \"str0\": [\"3\", 4], \"num\": 5,"
        " \"q\": [1, 2, 3, 4], \"qa\": [\"1\", 2, 3, 4], \"qb\": [1, \"2\", 3, 4],"
        " \"qc\": [1, 2, \"3\", 4], \"qd\": [1, 2, 3, \"4\"], \"q3\": [1, 2, 3]}"
    )
    assert_equal(read_int_pair(obj, "ok", 0, 0)[1], 4)
    for key in ["short", "str", "str0", "num", "missing"]:
        var got = read_int_pair(obj, key, 7, 8)
        assert_equal(got[0], 7, key)
        assert_equal(got[1], 8, key)
    assert_equal(read_int_quad(obj, "q", 0, 0, 0, 0)[3], 4)
    for key in ["qa", "qb", "qc", "qd", "q3", "ok"]:
        assert_equal(read_int_quad(obj, key, 9, 9, 9, 7)[3], 7, key)


def test_numbers_come_back_as_written() raises:
    var text = String("[0,9,19,-7,1.5,-0.25e+3,2E-3,1e5,3.0e-12,0.9e09,8.09E+90]")
    var v = parse_json(text)
    assert_equal(encode_json(v), text)
    assert_true(v.array_at(1).is_int())
    assert_equal(v.array_at(2).as_int(), 19)
    assert_equal(v.array_at(3).as_int(), -7)
    for i in range(4, 11):
        assert_true(v.array_at(i).is_float(), String(i))
    assert_equal(encode_json(parse_json("{\"a\":-12}")), "{\"a\":-12}")
    with assert_raises():
        _ = parse_json("[1:]")
    with assert_raises():
        _ = parse_json("-")


def test_literals() raises:
    assert_true(parse_json("true").as_bool())
    assert_true(not parse_json("false").as_bool())
    assert_true(parse_json("null").is_null())
    assert_equal(encode_json(parse_json("[true,false,null]")), "[true,false,null]")
    for bad in ["[trux]", "[tsue]", "[xrue]", "[fals]", "[falsy]", "[fblse]", "[nul]", "[nulL]", "[tru]"]:
        with assert_raises():
            _ = parse_json(bad)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
