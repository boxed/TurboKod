"""JSON strings: unsaved drafts and the config are stored as JSON, so text
must come back exactly as it went in."""

from std.testing import TestSuite, assert_equal, assert_raises, assert_true
from turbokod.json import encode_json, json_str, parse_json


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
