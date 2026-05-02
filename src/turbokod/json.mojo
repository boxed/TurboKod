"""Minimal JSON encoder/decoder for the LSP client.

Scope is deliberately narrow: enough to encode/parse the JSON-RPC traffic
``mojo-lsp-server`` (and similar servers) emit. We support objects,
arrays, strings (with the standard escape set + ``\\uXXXX``), integer
numbers, ``true``/``false``/``null``. Floats are tolerated on parse
(stored verbatim as a string) but not constructed by our encoder — LSP
itself rarely produces them in the messages we exchange.

We reach for this hand-written module instead of the third-party
``emberjson`` package because emberjson 0.3.0's source uses
``@register_passable``, ``compile.is_compile_time``, and other APIs
that were removed in the Mojo version this project pins to.

The data model uses the same tagged-union shape as ``Event`` in
``events.mojo`` (one struct, ``kind: UInt8`` discriminant, lazy
field access).  Objects keep their insertion order so canonical
encodings stay stable in tests.
"""

from std.collections.list import List
from std.collections.optional import Optional


# --- JsonValue -------------------------------------------------------------

comptime JSON_NULL   = UInt8(0)
comptime JSON_BOOL   = UInt8(1)
comptime JSON_INT    = UInt8(2)
comptime JSON_FLOAT  = UInt8(3)   # stored as raw text on parse, no encode path
comptime JSON_STRING = UInt8(4)
comptime JSON_ARRAY  = UInt8(5)
comptime JSON_OBJECT = UInt8(6)


@fieldwise_init
struct JsonMember(ImplicitlyCopyable, Movable):
    """A single ``(key, value)`` pair inside a JsonValue object."""
    var key: String
    var value: JsonValue


struct JsonValue(ImplicitlyCopyable, Movable):
    """Tagged-union JSON node. Construct via the ``json_*`` factory
    functions and inspect via ``is_*`` predicates + ``as_*`` accessors."""
    var kind: UInt8
    var bool_v: Bool
    var int_v: Int
    var str_v: String
    var arr_v: List[JsonValue]
    var obj_v: List[JsonMember]

    fn __init__(out self):
        self.kind = JSON_NULL
        self.bool_v = False
        self.int_v = 0
        self.str_v = String("")
        self.arr_v = List[JsonValue]()
        self.obj_v = List[JsonMember]()

    fn __copyinit__(out self, copy: Self):
        self.kind = copy.kind
        self.bool_v = copy.bool_v
        self.int_v = copy.int_v
        self.str_v = copy.str_v
        self.arr_v = copy.arr_v.copy()
        self.obj_v = copy.obj_v.copy()

    # --- predicates / accessors --------------------------------------

    fn is_null(self) -> Bool:    return self.kind == JSON_NULL
    fn is_bool(self) -> Bool:    return self.kind == JSON_BOOL
    fn is_int(self) -> Bool:     return self.kind == JSON_INT
    fn is_float(self) -> Bool:   return self.kind == JSON_FLOAT
    fn is_string(self) -> Bool:  return self.kind == JSON_STRING
    fn is_array(self) -> Bool:   return self.kind == JSON_ARRAY
    fn is_object(self) -> Bool:  return self.kind == JSON_OBJECT

    fn as_bool(self) -> Bool:    return self.bool_v
    fn as_int(self) -> Int:      return self.int_v
    fn as_str(self) -> String:   return self.str_v

    fn array_len(self) -> Int:
        return len(self.arr_v) if self.is_array() else 0

    fn array_at(self, i: Int) -> JsonValue:
        if not self.is_array() or i < 0 or i >= len(self.arr_v):
            return json_null()
        return self.arr_v[i]

    fn object_get(self, key: String) -> Optional[JsonValue]:
        if not self.is_object():
            return Optional[JsonValue]()
        for i in range(len(self.obj_v)):
            if self.obj_v[i].key == key:
                return Optional[JsonValue](self.obj_v[i].value)
        return Optional[JsonValue]()

    fn object_has(self, key: String) -> Bool:
        return Bool(self.object_get(key))

    # --- mutators (for object/array construction) --------------------

    fn append(mut self, value: JsonValue):
        if self.kind != JSON_ARRAY:
            return
        self.arr_v.append(value)

    fn put(mut self, var key: String, value: JsonValue):
        if self.kind != JSON_OBJECT:
            return
        for i in range(len(self.obj_v)):
            if self.obj_v[i].key == key:
                self.obj_v[i].value = value
                return
        self.obj_v.append(JsonMember(key^, value))


# --- builders --------------------------------------------------------------


fn json_null() -> JsonValue:
    var v = JsonValue()
    v.kind = JSON_NULL
    return v^


fn json_bool(b: Bool) -> JsonValue:
    var v = JsonValue()
    v.kind = JSON_BOOL
    v.bool_v = b
    return v^


fn json_int(n: Int) -> JsonValue:
    var v = JsonValue()
    v.kind = JSON_INT
    v.int_v = n
    return v^


fn json_str(var s: String) -> JsonValue:
    var v = JsonValue()
    v.kind = JSON_STRING
    v.str_v = s^
    return v^


fn json_array() -> JsonValue:
    var v = JsonValue()
    v.kind = JSON_ARRAY
    return v^


fn json_object() -> JsonValue:
    var v = JsonValue()
    v.kind = JSON_OBJECT
    return v^


# --- encoder ---------------------------------------------------------------


fn encode_json(value: JsonValue) -> String:
    var out = String("")
    _encode(value, out)
    return out^


fn _encode(value: JsonValue, mut out: String):
    if value.is_null():
        out = out + String("null")
        return
    if value.is_bool():
        out = out + (String("true") if value.as_bool() else String("false"))
        return
    if value.is_int():
        out = out + String(value.as_int())
        return
    if value.is_float():
        # Float was preserved verbatim from parse; round-trip the text.
        out = out + value.as_str()
        return
    if value.is_string():
        _encode_string(value.as_str(), out)
        return
    if value.is_array():
        out = out + String("[")
        for i in range(value.array_len()):
            if i > 0:
                out = out + String(",")
            _encode(value.array_at(i), out)
        out = out + String("]")
        return
    if value.is_object():
        out = out + String("{")
        for i in range(len(value.obj_v)):
            if i > 0:
                out = out + String(",")
            _encode_string(value.obj_v[i].key, out)
            out = out + String(":")
            _encode(value.obj_v[i].value, out)
        out = out + String("}")
        return
    out = out + String("null")


fn _encode_string(s: String, mut out: String):
    out = out + String("\"")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 0x22:
            out = out + String("\\\"")
        elif c == 0x5C:
            out = out + String("\\\\")
        elif c == 0x08:
            out = out + String("\\b")
        elif c == 0x0C:
            out = out + String("\\f")
        elif c == 0x0A:
            out = out + String("\\n")
        elif c == 0x0D:
            out = out + String("\\r")
        elif c == 0x09:
            out = out + String("\\t")
        elif c < 0x20:
            out = out + String("\\u00")
            out = out + _hex_nibble((c >> 4) & 0xF)
            out = out + _hex_nibble(c & 0xF)
        else:
            out = out + chr(c)
    out = out + String("\"")


fn _hex_nibble(n: Int) -> String:
    if n < 10:
        return chr(0x30 + n)
    return chr(0x61 + (n - 10))


# --- parser ----------------------------------------------------------------
# All parsing functions take ``text: String`` and a byte-index ``pos``.
# Each function calls ``text.as_bytes()`` once at the top — that gives us a
# read-only span tied to ``text``'s lifetime so we don't have to thread a
# ``Span[UInt8, mut=False]`` parameter (which trips Mojo's parameter-order
# rules in some versions).


fn parse_json(s: String) raises -> JsonValue:
    """Parse a complete JSON document. Trailing whitespace is allowed; any
    other trailing content raises (matches RFC 8259 strict)."""
    var n = len(s.as_bytes())
    var pos = _skip_ws(s, 0)
    var parsed = _parse_value(s, pos)
    var end = _skip_ws(s, parsed[1])
    if end != n:
        raise Error("trailing data after JSON document")
    return parsed[0]


fn _parse_value(text: String, pos: Int) raises -> Tuple[JsonValue, Int]:
    var bytes = text.as_bytes()
    if pos >= len(bytes):
        raise Error("unexpected end of input")
    var c = Int(bytes[pos])
    if c == 0x7B:
        return _parse_object(text, pos)
    if c == 0x5B:
        return _parse_array(text, pos)
    if c == 0x22:
        var sp = _parse_string(text, pos)
        var sp_str = sp[0]
        return (json_str(sp_str), sp[1])
    if c == 0x74 or c == 0x66:
        return _parse_bool(text, pos)
    if c == 0x6E:
        return _parse_null(text, pos)
    if c == 0x2D or (0x30 <= c and c <= 0x39):
        return _parse_number(text, pos)
    raise Error("unexpected byte starting JSON value")


fn _parse_object(text: String, pos: Int) raises -> Tuple[JsonValue, Int]:
    var bytes = text.as_bytes()
    var p = pos + 1
    var obj = json_object()
    p = _skip_ws(text, p)
    if p < len(bytes) and bytes[p] == 0x7D:
        return (obj^, p + 1)
    while True:
        p = _skip_ws(text, p)
        if p >= len(bytes) or bytes[p] != 0x22:
            raise Error("expected string key in object")
        var key_pair = _parse_string(text, p)
        var key = key_pair[0]
        p = _skip_ws(text, key_pair[1])
        if p >= len(bytes) or bytes[p] != 0x3A:
            raise Error("expected ':' after object key")
        p += 1
        p = _skip_ws(text, p)
        var v_pair = _parse_value(text, p)
        obj.put(key^, v_pair[0])
        p = _skip_ws(text, v_pair[1])
        if p >= len(bytes):
            raise Error("unterminated object")
        if bytes[p] == 0x2C:
            p += 1
            continue
        if bytes[p] == 0x7D:
            return (obj^, p + 1)
        raise Error("expected ',' or '}' in object")


fn _parse_array(text: String, pos: Int) raises -> Tuple[JsonValue, Int]:
    var bytes = text.as_bytes()
    var p = pos + 1
    var arr = json_array()
    p = _skip_ws(text, p)
    if p < len(bytes) and bytes[p] == 0x5D:
        return (arr^, p + 1)
    while True:
        p = _skip_ws(text, p)
        var v_pair = _parse_value(text, p)
        arr.append(v_pair[0])
        p = _skip_ws(text, v_pair[1])
        if p >= len(bytes):
            raise Error("unterminated array")
        if bytes[p] == 0x2C:
            p += 1
            continue
        if bytes[p] == 0x5D:
            return (arr^, p + 1)
        raise Error("expected ',' or ']' in array")


fn _parse_string(text: String, pos: Int) raises -> Tuple[String, Int]:
    """Read one JSON-escaped string starting at ``pos``.

    Accumulates into a ``List[UInt8]`` rather than ``out + chr(c)`` —
    String concat is O(N) per step in Mojo, so a multi-MB JSON value
    (DevDocs ``db.json`` body) would otherwise take O(N²) and turn the
    first ``Cmd+K`` of a session into a multi-minute hang.
    """
    var bytes = text.as_bytes()
    if pos >= len(bytes) or bytes[pos] != 0x22:
        raise Error("expected string")
    var p = pos + 1
    var out = List[UInt8]()
    while p < len(bytes):
        var c = Int(bytes[p])
        if c == 0x22:
            return (
                String(StringSlice(unsafe_from_utf8=Span(out))),
                p + 1,
            )
        if c == 0x5C:
            if p + 1 >= len(bytes):
                raise Error("unterminated escape")
            var e = Int(bytes[p + 1])
            if e == 0x22:    out.append(0x22); p += 2
            elif e == 0x5C:  out.append(0x5C); p += 2
            elif e == 0x2F:  out.append(0x2F); p += 2
            elif e == 0x62:  out.append(0x08); p += 2
            elif e == 0x66:  out.append(0x0C); p += 2
            elif e == 0x6E:  out.append(0x0A); p += 2
            elif e == 0x72:  out.append(0x0D); p += 2
            elif e == 0x74:  out.append(0x09); p += 2
            elif e == 0x75:
                if p + 5 >= len(bytes):
                    raise Error("truncated \\uXXXX escape")
                var cp = 0
                for k in range(4):
                    cp = (cp << 4) | _hex_value(Int(bytes[p + 2 + k]))
                p += 6
                _emit_utf8(cp, out)
            else:
                raise Error("bad string escape")
            continue
        if c < 0x20:
            raise Error("control byte in string")
        out.append(bytes[p])
        p += 1
    raise Error("unterminated string")


fn _emit_utf8(cp: Int, mut out: List[UInt8]):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


fn _hex_value(c: Int) raises -> Int:
    if 0x30 <= c and c <= 0x39:
        return c - 0x30
    if 0x41 <= c and c <= 0x46:
        return c - 0x41 + 10
    if 0x61 <= c and c <= 0x66:
        return c - 0x61 + 10
    raise Error("bad hex digit")


fn _parse_number(text: String, pos: Int) raises -> Tuple[JsonValue, Int]:
    var bytes = text.as_bytes()
    var start = pos
    var p = pos
    var is_float = False
    if p < len(bytes) and bytes[p] == 0x2D:
        p += 1
    while p < len(bytes) and Int(bytes[p]) >= 0x30 and Int(bytes[p]) <= 0x39:
        p += 1
    if p < len(bytes) and bytes[p] == 0x2E:
        is_float = True
        p += 1
        while p < len(bytes) and Int(bytes[p]) >= 0x30 and Int(bytes[p]) <= 0x39:
            p += 1
    if p < len(bytes) and (bytes[p] == 0x65 or bytes[p] == 0x45):
        is_float = True
        p += 1
        if p < len(bytes) and (bytes[p] == 0x2B or bytes[p] == 0x2D):
            p += 1
        while p < len(bytes) and Int(bytes[p]) >= 0x30 and Int(bytes[p]) <= 0x39:
            p += 1
    if p == start:
        raise Error("expected number")
    var token = String(StringSlice(unsafe_from_utf8=bytes[start:p]))
    if is_float:
        var v = JsonValue()
        v.kind = JSON_FLOAT
        v.str_v = token^
        return (v^, p)
    var n = Int(atol(token))
    return (json_int(n), p)


fn _parse_bool(text: String, pos: Int) raises -> Tuple[JsonValue, Int]:
    var bytes = text.as_bytes()
    if pos + 3 < len(bytes) \
            and bytes[pos] == 0x74 and bytes[pos+1] == 0x72 \
            and bytes[pos+2] == 0x75 and bytes[pos+3] == 0x65:
        return (json_bool(True), pos + 4)
    if pos + 4 < len(bytes) \
            and bytes[pos] == 0x66 and bytes[pos+1] == 0x61 \
            and bytes[pos+2] == 0x6C and bytes[pos+3] == 0x73 \
            and bytes[pos+4] == 0x65:
        return (json_bool(False), pos + 5)
    raise Error("expected true/false")


fn _parse_null(text: String, pos: Int) raises -> Tuple[JsonValue, Int]:
    var bytes = text.as_bytes()
    if pos + 3 < len(bytes) \
            and bytes[pos] == 0x6E and bytes[pos+1] == 0x75 \
            and bytes[pos+2] == 0x6C and bytes[pos+3] == 0x6C:
        return (json_null(), pos + 4)
    raise Error("expected null")


fn _skip_ws(text: String, pos: Int) -> Int:
    var bytes = text.as_bytes()
    var p = pos
    while p < len(bytes):
        var c = bytes[p]
        if c != 0x20 and c != 0x09 and c != 0x0A and c != 0x0D:
            break
        p += 1
    return p
