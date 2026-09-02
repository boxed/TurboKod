"""Protocol-conformance suite: drives ``LspManager`` against a scripted server.

Everything here spawns ``tests/fixtures/mock_lsp.py`` with a scenario from
``tests/fixtures/lsp/*.json`` and exercises the real path — spawn, framing,
dispatch, the parse functions, the carriers. That is what separates these
from the parse-function unit tests in ``test_lsp.mojo``: those hand a JSON
literal to ``_parse_x`` directly, so they cannot catch anything that goes
wrong *between* the wire and the parser (position encoding, capability
gating, the params we actually send, frame reassembly).

Why a mock at all: LSP publishes no client conformance suite, and a real
server only ever exercises the one result variant it happens to emit. A
scripted server is the only way to cover the union shapes the spec permits
and the malformed payloads real servers emit in practice.

Two families, both here:

* ``*_spec_shape_*`` — union variants the spec allows for a given result.
* ``*_malformed_*`` / ``*_adversarial_*`` — nulls, wrong types, missing
  required fields, bad framing. The client must degrade, never crash and
  never corrupt a buffer.

Scenario authoring notes are in the mock server's docstring.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from turbokod.desktop import Desktop
from turbokod.file_io import delete_path, read_file, stat_file, write_file
from turbokod.json import JsonValue, parse_json
from turbokod.lsp_dispatch import (
    CompletionItem, Diagnostic, LspManager, uri_to_path,
)
from turbokod.string_utils import split_lines_no_trailing
from turbokod.lsp_position import (
    LineTable, POS_UTF16, POS_UTF32, POS_UTF8,
    byte_to_units, encoding_from_name, encoding_name, line_units,
    units_to_byte,
)
from turbokod.posix import getcwd_path, monotonic_ms, sleep_ms, which

from support import _SCREEN, setup_test_env


# ── harness ──────────────────────────────────────────────────────────────

comptime _MOCK = String("tests/fixtures/mock_lsp.py")


def _fixture_dir() -> String:
    return getcwd_path() + String("/tests/fixtures/lsp")


def _scenario_path(name: String) -> String:
    return _fixture_dir() + String("/") + name


def _start_mock(
    mut m: LspManager, scenario: String, root: String, log_path: String,
) raises -> Bool:
    """Spawn the mock with ``scenario`` and pump until READY.

    Returns False when python3 isn't available (the suite then skips rather
    than failing on a machine without it — same convention as the
    real-server tests in ``test_lsp.mojo``).
    """
    var py = which(String("python3"))
    if len(py.as_bytes()) == 0:
        return False
    # Scenario + log go on argv, not the environment: ``LspProcess.spawn``
    # forwards an *allowlist* of parent env vars, so anything test-specific
    # never reaches the child.
    var argv = List[String]()
    argv.append(py)
    argv.append(getcwd_path() + String("/") + _MOCK)
    argv.append(_scenario_path(scenario))
    if len(log_path.as_bytes()) > 0:
        # The mock appends, and the scratch directory is stable across runs
        # (deliberately — see ``_scratch_dir``), so a stale log would leave
        # the previous run's messages in front of this one's. Assertions like
        # "exit was the last thing sent" then read the wrong run.
        _ = delete_path(log_path)
        argv.append(log_path)
    m.start_with(String("python"), argv, root)
    if m.is_failed():
        raise Error(String("mock spawn failed: ") + m.failure_reason)
    # 200 × 10 ms. ``tick`` polls non-blocking, so without the sleep the
    # whole loop burns in microseconds — well before python3 has even
    # finished starting up.
    for _ in range(200):
        _ = m.tick()
        if m.is_ready():
            return True
        if m.is_failed():
            raise Error(
                String("mock failed during handshake: ") + m.failure_reason,
            )
        _ = external_call["usleep", Int32](UInt32(10_000))
    raise Error(
        String("mock never became ready; stderr=") + m.captured_stderr(),
    )


def _pump(mut m: LspManager, rounds: Int = 60):
    """Drain the transport for a while. Every scripted reply is already
    queued by the time we get here, so this is bounded generosity rather
    than a real wait."""
    for _ in range(rounds):
        _ = m.tick()
        _ = external_call["usleep", Int32](UInt32(5_000))


def _log_messages(path: String) raises -> List[JsonValue]:
    """Every message the mock received, parsed. Empty when no log exists.

    This is how the outbound half of the protocol gets asserted — what the
    client *sent*, not just how it parsed the reply."""
    var out = List[JsonValue]()
    var info = stat_file(path)
    if not info.ok:
        return out^
    var lines = split_lines_no_trailing(read_file(path))
    for i in range(len(lines)):
        if len(lines[i].as_bytes()) == 0:
            continue
        try:
            out.append(parse_json(lines[i]))
        except:
            # A truncated final line (the mock was killed mid-write) is not
            # a test failure — skip it rather than masking the real assert.
            continue
    return out^


def _find_sent(
    msgs: List[JsonValue], method: String,
) -> Optional[JsonValue]:
    """The params of the first logged message with ``method``."""
    for i in range(len(msgs)):
        var m_opt = msgs[i].object_get(String("method"))
        if not m_opt or not m_opt.value().is_string():
            continue
        if m_opt.value().as_str() != method:
            continue
        return msgs[i].object_get(String("params"))
    return Optional[JsonValue]()


def _pos_of(params: JsonValue, key: String) -> Tuple[Int, Int]:
    """``(line, character)`` of ``params[key]``, or ``(-1, -1)``."""
    var p = params.object_get(key)
    if not p or not p.value().is_object():
        return (-1, -1)
    var ln = p.value().object_get(String("line"))
    var ch = p.value().object_get(String("character"))
    if not ln or not ch or not ln.value().is_int() or not ch.value().is_int():
        return (-1, -1)
    return (ln.value().as_int(), ch.value().as_int())


def _scratch_dir(name: String) raises -> String:
    """A per-test scratch directory inside the project tree.

    Deliberately not ``/tmp``: disk usage from a test run should be
    traceable to this project. ``.build/`` is already gitignored and
    already where the build caches live.
    """
    # Stable per-test name, not pid-suffixed: the suites run serially (see
    # scripts/run_tests.sh), so there is no collision to avoid, and a pid
    # suffix would leave a fresh directory behind on every run.
    var dir = getcwd_path() + String("/.build/lsp_conformance/") + name
    _ = external_call["mkdir", Int32](
        (getcwd_path() + String("/.build/lsp_conformance\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    return dir^


def _emdash_buffer() raises -> String:
    """The fixture buffer whose rows carry multibyte glyphs before the
    identifiers the scenarios point at. Read from disk (not inlined) so
    the scenario JSON's hand-computed offsets and the text they describe
    can't drift apart."""
    return read_file(_fixture_dir() + String("/emdash.py"))


# ── pure conversion units ────────────────────────────────────────────────


def test_position_encoding_names_round_trip() raises:
    """Unknown encodings resolve to utf-16 — the spec default, and far more
    likely than bytes for a server answering something we don't know."""
    assert_equal(Int(encoding_from_name(String("utf-8"))), Int(POS_UTF8))
    assert_equal(Int(encoding_from_name(String("utf-16"))), Int(POS_UTF16))
    assert_equal(Int(encoding_from_name(String("utf-32"))), Int(POS_UTF32))
    assert_equal(Int(encoding_from_name(String("utf-7"))), Int(POS_UTF16))
    assert_equal(Int(encoding_from_name(String(""))), Int(POS_UTF16))
    assert_equal(encoding_name(POS_UTF8), String("utf-8"))
    assert_equal(encoding_name(POS_UTF16), String("utf-16"))
    assert_equal(encoding_name(POS_UTF32), String("utf-32"))


def test_utf16_conversion_counts_em_dash_as_one_unit() raises:
    """An em dash is 3 bytes but 1 UTF-16 code unit, so every column after
    it differs by 2 between the editor's byte model and the wire."""
    var line = String("a—b")
    assert_equal(len(line.as_bytes()), 5)
    assert_equal(line_units(line, POS_UTF16), 3)
    assert_equal(byte_to_units(line, 0, POS_UTF16), 0)
    assert_equal(byte_to_units(line, 1, POS_UTF16), 1)
    assert_equal(byte_to_units(line, 4, POS_UTF16), 2)
    assert_equal(byte_to_units(line, 5, POS_UTF16), 3)
    assert_equal(units_to_byte(line, 0, POS_UTF16), 0)
    assert_equal(units_to_byte(line, 1, POS_UTF16), 1)
    assert_equal(units_to_byte(line, 2, POS_UTF16), 4)
    assert_equal(units_to_byte(line, 3, POS_UTF16), 5)


def test_utf16_conversion_counts_emoji_as_a_surrogate_pair() raises:
    """An astral codepoint is 4 bytes, *two* UTF-16 units, one UTF-32 unit.
    The UTF-16 pair is what makes the two encodings differ from utf-32."""
    var line = String("x😀y")
    assert_equal(len(line.as_bytes()), 6)
    assert_equal(line_units(line, POS_UTF16), 4)
    assert_equal(line_units(line, POS_UTF32), 3)
    assert_equal(line_units(line, POS_UTF8), 6)
    assert_equal(byte_to_units(line, 5, POS_UTF16), 3)
    assert_equal(units_to_byte(line, 3, POS_UTF16), 5)
    assert_equal(units_to_byte(line, 2, POS_UTF32), 5)


def test_position_conversion_snaps_inside_a_codepoint() raises:
    """You cannot address half a character in either direction: a byte
    column inside a codepoint snaps to its start, and a UTF-16 offset
    landing between the halves of a surrogate pair does too. A server that
    sends such an offset must not produce a column that splits UTF-8."""
    var line = String("x😀y")
    assert_equal(byte_to_units(line, 2, POS_UTF16), 1)
    assert_equal(byte_to_units(line, 3, POS_UTF16), 1)
    assert_equal(byte_to_units(line, 4, POS_UTF16), 1)
    # unit 2 is the low surrogate — snap back to the emoji's first byte.
    assert_equal(units_to_byte(line, 2, POS_UTF16), 1)


def test_position_conversion_clamps_past_end_of_line() raises:
    """Per spec a ``character`` past the line length "defaults back to the
    line length". Servers do emit these (an end-of-line range expressed as
    a huge number), and an unclamped value would index past the buffer."""
    var line = String("a—b")
    assert_equal(units_to_byte(line, 999, POS_UTF16), 5)
    assert_equal(units_to_byte(line, -4, POS_UTF16), 0)
    assert_equal(byte_to_units(line, 999, POS_UTF16), 3)
    assert_equal(byte_to_units(line, -4, POS_UTF16), 0)
    # utf-8 is the identity but must still clamp.
    assert_equal(units_to_byte(line, 999, POS_UTF8), 5)
    assert_equal(byte_to_units(line, 999, POS_UTF8), 5)


def test_line_table_indexes_rows_and_strips_crlf() raises:
    """The line index feeds every conversion, so its row extraction has to
    handle CRLF (a Windows-authored file) and out-of-range rows (a stale
    response naming a row the buffer no longer has)."""
    var t = LineTable(String("one\r\ntwö—o\nthree"))
    assert_equal(t.row_count(), 3)
    assert_equal(t.line(0), String("one"))
    assert_equal(t.line(1), String("twö—o"))
    assert_equal(t.line(2), String("three"))
    assert_equal(t.line(9), String(""))
    assert_equal(t.line(-1), String(""))
    # "twö—o": t w ö(2B) —(3B) o  → 8 bytes, 5 utf-16 units.
    assert_equal(len(t.line(1).as_bytes()), 8)
    assert_equal(t.col_to_wire(1, 8, POS_UTF16), 5)
    assert_equal(t.wire_to_col(1, 4, POS_UTF16), 7)
    # utf-8 short-circuits to the identity without touching the text.
    assert_equal(t.col_to_wire(1, 8, POS_UTF8), 8)
    assert_equal(t.wire_to_col(1, 4, POS_UTF8), 4)


def test_line_table_empty_and_trailing_newline() raises:
    var t = LineTable(String(""))
    assert_equal(t.row_count(), 1)
    assert_equal(t.line(0), String(""))
    var t2 = LineTable(String("a\n"))
    assert_equal(t2.row_count(), 2)
    assert_equal(t2.line(0), String("a"))
    assert_equal(t2.line(1), String(""))


# ── position encoding, end to end through a real server process ──────────


def test_server_without_negotiation_gets_utf16_columns_converted() raises:
    """The regression this whole module was written for.

    A server that never implemented 3.17's ``general.positionEncodings``
    answers ``initialize`` with no ``positionEncoding``, so the spec default
    ``utf-16`` applies — we asked for utf-8 and did not get it. Every
    ``character`` it sends is then a UTF-16 offset, and the editor's byte
    columns are not that. Before the conversion landed, the negotiated
    encoding was recorded and *logged* and nothing else, so on any line with
    multibyte text the diagnostic underline, the definition jump and the
    formatting edit all landed 2 bytes early per em dash and 2 per emoji.

    The fixture buffer's row 1 is ``value = 1  # — target here``: ``target``
    is bytes [17, 23) but UTF-16 units [15, 21). The scenario answers in
    units; the assertions are in bytes.
    """
    var dir = _scratch_dir(String("utf16"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var log = dir + String("/requests.jsonl")

    var m = LspManager()
    if not _start_mock(m, String("utf16_no_negotiation.json"), dir, log):
        return
    assert_equal(m.position_encoding(), String("utf-16"))

    # --- inbound: publishDiagnostics ranges arrive in units ---
    m.notify_opened(path, text)
    _pump(m)
    var diags = m.take_diagnostics_for(path)
    assert_equal(len(diags), 2)
    # Row 1, after a 3-byte em dash: units [15,21) → bytes [17,23).
    assert_equal(diags[0].start_row, 1)
    assert_equal(diags[0].start_col, 17)
    assert_equal(diags[0].end_col, 23)
    # Row 2, after a 4-byte emoji (a surrogate pair, so 2 units):
    # units [17,21) → bytes [19,23).
    assert_equal(diags[1].start_row, 2)
    assert_equal(diags[1].start_col, 19)
    assert_equal(diags[1].end_col, 23)

    # --- outbound: the cursor's byte column must leave as units ---
    assert_true(m.request_definition(
        path, 1, 17, String("target"), text,
    ))
    _pump(m)
    var sent = _log_messages(log)
    var dp = _find_sent(sent, String("textDocument/definition"))
    assert_true(Bool(dp))
    var pos = _pos_of(dp.value(), String("position"))
    assert_equal(pos[0], 1)
    assert_equal(pos[1], 15)   # byte 17 → utf-16 unit 15

    m.shutdown()


def test_server_negotiating_utf8_passes_columns_through() raises:
    """The control: a 3.17 server that honors our utf-8 request gets byte
    columns verbatim in both directions. Without this test the conversion
    could be unconditional and still pass the utf-16 case — this is what
    pins it to the negotiated encoding."""
    var dir = _scratch_dir(String("utf8"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var log = dir + String("/requests.jsonl")

    var m = LspManager()
    if not _start_mock(m, String("utf8_negotiated.json"), dir, log):
        return
    assert_equal(m.position_encoding(), String("utf-8"))

    m.notify_opened(path, text)
    _pump(m)
    var diags = m.take_diagnostics_for(path)
    assert_equal(len(diags), 1)
    assert_equal(diags[0].start_col, 17)
    assert_equal(diags[0].end_col, 23)

    assert_true(m.request_definition(
        path, 1, 17, String("target"), text,
    ))
    _pump(m)
    var sent = _log_messages(log)
    var dp = _find_sent(sent, String("textDocument/definition"))
    assert_true(Bool(dp))
    var pos = _pos_of(dp.value(), String("position"))
    assert_equal(pos[1], 17)   # unchanged
    m.shutdown()


def test_utf16_conversion_reaches_references_and_workspace_edits() raises:
    """Positions nest in shapes with their own URI context: ``Location[]``
    carries ``uri`` per entry, and a rename's ``WorkspaceEdit.changes`` is a
    ``{uri: TextEdit[]}`` map where the URI is the *key*. Both have to be
    converted against the right file's text, which is what the remapper's
    URI-context tracking is for."""
    var dir = _scratch_dir(String("utf16_edits"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))

    var m = LspManager()
    if not _start_mock(m, String("utf16_no_negotiation.json"), dir, String("")):
        return
    m.notify_opened(path, text)
    _pump(m)
    _ = m.take_diagnostics_for(path)

    # Location[] — each entry's own ``uri`` supplies the context.
    assert_true(m.request_references(path, 1, 17, String("target"), text))
    _pump(m)
    var refs = m.take_references()
    assert_equal(len(refs), 2)
    assert_equal(refs[0].line, 1)
    assert_equal(refs[0].character, 17)
    assert_equal(refs[1].line, 2)
    assert_equal(refs[1].character, 19)   # unit 17 → byte 19

    # WorkspaceEdit.changes — the URI is the map key, not a field.
    assert_true(m.request_rename(path, 1, 17, String("renamed"), text))
    _pump(m)
    var groups = m.take_rename_edits()
    assert_equal(len(groups), 1)
    assert_equal(uri_to_path(groups[0].uri), path)
    assert_equal(len(groups[0].edits), 1)
    assert_equal(groups[0].edits[0].start_char, 17)
    assert_equal(groups[0].edits[0].end_char, 23)
    assert_equal(groups[0].edits[0].new_text, String("renamed"))

    # TextEdit[] with no URI anywhere — the context is the request's own
    # document, recovered from the id→uri map recorded at send time.
    assert_true(m.request_formatting(path, text))
    _pump(m)
    var edits = m.take_formatting_edits()
    assert_equal(len(edits), 1)
    assert_equal(edits[0].start_line, 2)
    assert_equal(edits[0].start_char, 19)
    assert_equal(edits[0].end_char, 23)

    m.shutdown()



def _contains(haystack: String, needle: String) -> Bool:
    """Substring test — the hover assertions only care that a fragment
    survived, not where it landed."""
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0:
        return True
    if len(n) > len(h):
        return False
    for i in range(len(h) - len(n) + 1):
        var hit = True
        for k in range(len(n)):
            if h[i + k] != n[k]:
                hit = False
                break
        if hit:
            return True
    return False


def _labels(items: List[CompletionItem]) -> List[String]:
    var out = List[String]()
    for i in range(len(items)):
        out.append(items[i].label)
    return out^


def _contains_label(labels: List[String], want: String) -> Bool:
    for i in range(len(labels)):
        if labels[i] == want:
            return True
    return False



# ── spec-shape coverage: union variants a real server never all emits ────


def test_spec_shape_definition_accepts_every_variant() raises:
    """``textDocument/definition`` is ``Definition | DefinitionLink[] | null``
    where ``Definition = Location | Location[]`` — four accepting shapes.

    Real servers each pick one and never change (clangd: Location; gopls:
    LocationLink[]; pyright: Location[]), so no amount of real-server
    testing reaches the others. The scenario answers a different
    definition-shaped method with each variant; all must resolve to the
    same target, and the null must resolve to nothing without being
    mistaken for "still waiting".
    """
    var dir = _scratch_dir(String("shape_def"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("shapes_definition_variants.json"), dir, String(""),
    ):
        return

    # Location (a bare object).
    assert_true(m.request_definition(path, 1, 17, String("target"), text))
    _pump(m)
    var one = m.tick()
    var got_bare = Bool(one)
    if not got_bare:
        # The resolved target surfaces from whichever tick drained it.
        got_bare = not m.last_empty()
    assert_true(got_bare)

    # Location[] — via typeDefinition, which shares the parse path.
    assert_true(m.request_navigation(
        String("textDocument/typeDefinition"), path, 1, 17,
        String("target"), text,
    ))
    _pump(m)
    assert_true(m.has_pending_nav())
    var arr_target = m.take_nav_target()
    assert_true(Bool(arr_target))
    assert_equal(arr_target.value().line, 1)
    assert_equal(arr_target.value().character, 17)

    # LocationLink[] — targetSelectionRange is the position to land on,
    # not targetRange (which spans the whole declaration).
    assert_true(m.request_navigation(
        String("textDocument/implementation"), path, 1, 17,
        String("target"), text,
    ))
    _pump(m)
    assert_true(m.has_pending_nav())
    var link_target = m.take_nav_target()
    assert_true(Bool(link_target))
    assert_equal(link_target.value().line, 1)
    assert_equal(link_target.value().character, 17)

    # null — answered, found nothing. Must not park a bogus target.
    assert_true(m.request_navigation(
        String("textDocument/declaration"), path, 1, 17,
        String("target"), text,
    ))
    _pump(m)
    assert_true(m.has_pending_nav())
    assert_false(Bool(m.take_nav_target()))
    m.shutdown()


def test_spec_shape_hover_markup_content() raises:
    """``Hover.contents`` as ``MarkupContent`` — the modern form."""
    var dir = _scratch_dir(String("shape_hov"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(m, String("shapes_hover_variants.json"), dir, String("")):
        return
    assert_true(m.request_hover(path, 1, 17, text))
    _pump(m)
    assert_equal(m.take_hover_text(), String("markup content"))
    m.shutdown()


def test_spec_shape_hover_bare_string() raises:
    """``Hover.contents`` as a bare string — the oldest MarkedString form,
    still emitted by servers in the wild."""
    var dir = _scratch_dir(String("shape_hov_str"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("shapes_hover_bare_string.json"), dir, String(""),
    ):
        return
    assert_true(m.request_hover(path, 1, 17, text))
    _pump(m)
    assert_equal(m.take_hover_text(), String("a bare string"))
    m.shutdown()


def test_spec_shape_hover_marked_string_array() raises:
    """``Hover.contents`` as ``MarkedString[]`` mixing bare strings and
    ``{language, value}`` objects. All entries must survive — the failure
    mode is showing only the first and silently dropping the code block,
    which is where the useful part usually is."""
    var dir = _scratch_dir(String("shape_hov_arr"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("shapes_hover_marked_string.json"), dir, String(""),
    ):
        return
    assert_true(m.request_hover(path, 1, 17, text))
    _pump(m)
    var hover = m.take_hover_text()
    assert_true(len(hover.as_bytes()) > 0)
    assert_true(_contains(hover, String("first line")))
    assert_true(_contains(hover, String("def f(): ...")))
    assert_true(_contains(hover, String("third line")))
    m.shutdown()


def test_spec_shape_completion_list_and_item_variants() raises:
    """The ``CompletionList`` form plus the per-item variants that each take
    a different branch of the accept path: ``sortText`` overriding label
    order, ``insertText`` differing from ``label``, a ``textEdit`` range,
    an ``insertReplaceEdit`` (two ranges, not one), and
    ``additionalTextEdits`` (the auto-import line)."""
    var dir = _scratch_dir(String("shape_comp"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("shapes_completion_list.json"), dir, String(""),
    ):
        return
    assert_true(m.request_completion(path, 1, 17, text, True))
    _pump(m)
    var items = m.take_completions()
    assert_equal(len(items), 6)
    # sortText, not label, decides order: "zebra" carries sortText "000" and
    # "alpha" carries "999", so the alphabetical order is inverted. The
    # remaining items have no sortText and fall back to their label, which
    # sorts after both digit-prefixed keys.
    assert_equal(items[0].label, String("zebra"))
    assert_equal(items[1].label, String("alpha"))
    var by_label = _labels(items)
    assert_true(_contains_label(by_label, String("with_insert_text")))
    assert_true(_contains_label(by_label, String("with_text_edit")))
    assert_true(_contains_label(by_label, String("with_insert_replace")))
    assert_true(_contains_label(by_label, String("needs_import")))
    # The three edit-bearing variants must all carry a replace range.
    for i in range(len(items)):
        var lab = items[i].label
        if lab == String("with_text_edit") \
                or lab == String("with_insert_replace"):
            assert_true(items[i].has_range)
            assert_equal(items[i].range_start_char, 17)
            assert_equal(items[i].range_end_char, 23)
        if lab == String("needs_import"):
            assert_equal(len(items[i].additional_text_edits), 1)
    m.shutdown()


# ── adversarial: what real servers actually send ─────────────────────────


def test_adversarial_wrong_types_degrade_without_crashing() raises:
    """Every field the spec declares as an object / array / int, sent as the
    wrong type.

    This is the family that matters most in practice: servers violate the
    schema constantly, and a client that trusts it either crashes or —
    worse — produces a column from garbage and splices an edit at it. The
    contract asserted here is "drop the malformed entry, keep the valid
    ones, never crash": each list below has exactly one well-formed member
    among the junk.
    """
    var dir = _scratch_dir(String("adv_types"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("adversarial_wrong_types.json"), dir, String(""),
    ):
        return
    m.notify_opened(path, text)
    _pump(m)

    # A well-formed ``range`` is the only hard requirement: four entries
    # lack one (null range, no range, no ``end``, and two non-objects) and
    # are dropped. The fifth has a valid range but no ``message`` — which
    # the spec requires — and is deliberately *kept* with an empty message,
    # because a squiggle in the right place is more useful than silence
    # even when the server forgot to say why (same reasoning as the
    # severity default in ``_parse_diagnostics_array``).
    var diags = m.take_diagnostics_for(path)
    assert_equal(len(diags), 2)
    assert_equal(diags[0].message, String("the one valid entry"))
    assert_equal(diags[1].message, String(""))
    assert_equal(diags[1].end_col, 1)

    # uri as an int, range as a string → no target, and the manager must
    # report "answered, empty" rather than parking a bogus location.
    assert_true(m.request_definition(path, 1, 17, String("target"), text))
    _pump(m)
    assert_true(m.last_empty())

    # Object where an array belongs.
    assert_true(m.request_references(path, 1, 17, String("target"), text))
    _pump(m)
    assert_equal(len(m.take_references()), 0)

    # An int where MarkupContent | MarkedString belongs.
    assert_true(m.request_hover(path, 1, 17, text))
    _pump(m)
    assert_equal(m.take_hover_text(), String(""))

    # Four malformed symbols, one valid.
    assert_true(m.request_document_symbols(path, text))
    _pump(m)
    var syms = m.take_symbols()
    assert_equal(len(syms), 1)
    assert_equal(syms[0].name, String("ok"))

    # Four malformed TextEdits, one valid.
    assert_true(m.request_formatting(path, text))
    _pump(m)
    var edits = m.take_formatting_edits()
    assert_equal(len(edits), 1)
    assert_equal(edits[0].new_text, String("ok"))

    # ``items`` as a string.
    assert_true(m.request_completion(path, 1, 17, text, True))
    _pump(m)
    assert_equal(len(m.take_completions()), 0)

    # ``changes`` as a string.
    assert_true(m.request_rename(path, 1, 17, String("x"), text))
    _pump(m)
    assert_equal(len(m.take_rename_edits()), 0)

    # Three malformed code actions, one valid.
    var probe = Diagnostic(
        0, 0, 0, 3, 1, String("probe"), String("mock"), String("c"),
    )
    assert_true(m.request_code_actions(path, probe, text))
    _pump(m)
    var actions = m.take_code_actions()
    assert_equal(len(actions), 1)
    assert_equal(actions[0].title, String("valid"))
    m.shutdown()


def test_adversarial_null_results_read_as_answered_not_pending() raises:
    """``result: null`` for every request. The spec permits it, and a server
    that advertised a capability it doesn't implement sends it.

    The distinction being pinned: a null is *answered and empty*, which is
    a different UI state from *still waiting*. Conflating them is what
    leaves a spinner up forever."""
    var dir = _scratch_dir(String("adv_null"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("adversarial_null_results.json"), dir, String(""),
    ):
        return
    m.notify_opened(path, text)
    _pump(m)
    assert_equal(len(m.take_diagnostics_for(path)), 0)

    assert_true(m.request_definition(path, 1, 17, String("target"), text))
    _pump(m)
    assert_true(m.last_empty())

    assert_true(m.request_hover(path, 1, 17, text))
    _pump(m)
    assert_equal(m.take_hover_text(), String(""))

    assert_true(m.request_document_symbols(path, text))
    _pump(m)
    assert_true(m.has_pending_symbols())
    assert_equal(len(m.take_symbols()), 0)

    assert_true(m.request_formatting(path, text))
    _pump(m)
    assert_true(m.has_pending_formatting())
    assert_equal(len(m.take_formatting_edits()), 0)

    assert_true(m.request_rename(path, 1, 17, String("x"), text))
    _pump(m)
    assert_equal(len(m.take_rename_edits()), 0)
    m.shutdown()


def test_adversarial_out_of_range_positions_clamp() raises:
    """Rows past EOF, huge character offsets, inverted and negative ranges —
    all under utf-16, so they go through the converter.

    Servers emit a huge ``character`` as shorthand for end-of-line, and the
    spec says clamp. An unclamped value indexes past the buffer; a negative
    one indexes before it. Neither may produce a column that splits a
    UTF-8 sequence either."""
    var dir = _scratch_dir(String("adv_range"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("adversarial_out_of_range.json"), dir, String(""),
    ):
        return
    assert_equal(m.position_encoding(), String("utf-16"))
    m.notify_opened(path, text)
    _pump(m)

    var diags = m.take_diagnostics_for(path)
    assert_equal(len(diags), 2)
    # Row 2 is 'emoji = "😀" and tail' — 23 bytes. A past-end offset clamps
    # to the line length, never beyond.
    assert_equal(diags[0].start_row, 2)
    assert_equal(diags[0].start_col, 23)
    assert_true(diags[0].end_col <= 23)
    # A row past EOF keeps its row (the editor clamps rows itself) but its
    # column must not be converted against a line that doesn't exist.
    assert_equal(diags[1].start_row, 4242)
    assert_true(diags[1].start_col >= 0)

    assert_true(m.request_formatting(path, text))
    _pump(m)
    var edits = m.take_formatting_edits()
    assert_equal(len(edits), 4)
    for i in range(len(edits)):
        assert_true(edits[i].start_char >= 0)
        assert_true(edits[i].end_char >= 0)
    m.shutdown()


def test_adversarial_framing_split_frames_and_garbage() raises:
    """Transport-level abuse: a frame written in two writes with a pause, a
    body that isn't JSON, and a request that is never answered.

    The split case is the one that bites in production — it happens on
    large completion responses, exactly when a torn parse is most likely —
    and the contract is that an unanswered request must not wedge the
    transport for the requests after it."""
    var dir = _scratch_dir(String("adv_frame"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("adversarial_framing.json"), dir, String(""),
    ):
        return

    # A frame delivered in two writes must reassemble, not tear.
    assert_true(m.request_definition(path, 1, 17, String("target"), text))
    _pump(m, 120)
    assert_false(m.last_empty())

    # A non-JSON body must be dropped without killing the session.
    assert_true(m.request_references(path, 1, 17, String("target"), text))
    _pump(m)
    assert_equal(len(m.take_references()), 0)
    assert_true(m.is_ready())

    # A request that is never answered must leave nothing parked …
    assert_true(m.request_hover(path, 1, 17, text))
    _pump(m)
    assert_false(m.has_pending_hover())
    # … and must not block the request after it.
    assert_true(m.request_formatting(path, text))
    _pump(m)
    var edits = m.take_formatting_edits()
    assert_equal(len(edits), 1)
    assert_equal(edits[0].new_text, String("after-the-mess"))
    assert_true(m.is_ready())
    m.shutdown()


def test_adversarial_server_requests_are_position_converted() raises:
    """Server-to-client requests that mutate buffers: ``workspace/applyEdit``
    (a WorkspaceEdit) and ``window/showDocument`` (a jump target).

    Both are applied to a buffer, so both need the same conversion the
    response path gets. Before the remapper walked inbound *requests* as
    well as responses, a server-driven rename under utf-16 spliced at the
    wrong offset — the worst failure mode in this whole file, because it
    corrupts the file rather than just navigating wrongly."""
    var dir = _scratch_dir(String("adv_srvreq"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("adversarial_server_requests.json"), dir, String(""),
    ):
        return
    assert_equal(m.position_encoding(), String("utf-16"))
    m.notify_opened(path, text)
    _pump(m)

    assert_true(m.has_pending_applyedit())
    var groups = m.take_applyedit()
    assert_equal(len(groups), 1)
    assert_equal(uri_to_path(groups[0].uri), path)
    assert_equal(len(groups[0].edits), 1)
    # units [15,21) → bytes [17,23).
    assert_equal(groups[0].edits[0].start_char, 17)
    assert_equal(groups[0].edits[0].end_char, 23)
    assert_equal(groups[0].edits[0].new_text, String("from_changes_map"))

    assert_true(m.has_show_document())
    assert_equal(m.show_document_path(), path)
    assert_equal(m.show_document_line(), 2)
    assert_equal(m.show_document_char(), 19)   # unit 17 → byte 19
    m.clear_show_document()
    m.shutdown()



def test_workspace_edit_document_changes_is_parsed_and_converted() raises:
    """``WorkspaceEdit`` in the 3.13+ ``documentChanges`` form.

    Two forms exist: the ``{uri: TextEdit[]}`` ``changes`` map, and an array
    of ``{textDocument: {uri, version}, edits}``. rust-analyzer and gopls
    *prefer* the latter, and per spec a server may only use the form the
    client advertised — so this arriving unparsed meant their renames and
    quickfix edits did nothing. We now advertise
    ``workspace.workspaceEdit.documentChanges`` and parse it.

    The URI hangs off a nested ``textDocument`` rather than being a map key,
    which the position remapper already resolved; this pins that the parse
    reaches it too.
    """
    var dir = _scratch_dir(String("docchanges"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("shapes_document_changes.json"), dir, String(""),
    ):
        return
    m.notify_opened(path, text)
    _pump(m)
    var groups = m.take_applyedit()
    assert_equal(len(groups), 1)
    assert_equal(uri_to_path(groups[0].uri), path)
    assert_equal(len(groups[0].edits), 1)
    # units [15,21) → bytes [17,23), same as the ``changes``-map path.
    assert_equal(groups[0].edits[0].start_char, 17)
    assert_equal(groups[0].edits[0].end_char, 23)
    assert_equal(
        groups[0].edits[0].new_text, String("from_document_changes"),
    )
    assert_true(m.is_ready())
    m.shutdown()


def test_workspace_edit_with_file_operations_is_refused_whole() raises:
    """A ``documentChanges`` array that also creates / renames / deletes
    files is refused **entirely**, not half-applied.

    This is the one place where "parse what you can" is the wrong
    instinct. A WorkspaceEdit that renames ``a.py`` to ``b.py`` and rewrites
    every import of it is one atomic refactor; applying only the text edits
    leaves the project referring to a file that still has its old name —
    broken in a way that doing nothing is not. So the parse counts the
    resource operations and returns no edits at all.

    We also don't advertise ``resourceOperations``, so a compliant server
    never sends one; this covers the ones that do anyway.
    """
    var dir = _scratch_dir(String("fileops"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("gaps_resource_operations.json"), dir, String(""),
    ):
        return
    m.notify_opened(path, text)
    _pump(m)
    # The text edit in the same array must NOT come through on its own.
    assert_equal(len(m.take_applyedit()), 0)
    assert_true(m.is_ready())
    m.shutdown()

def test_shutdown_performs_the_spec_handshake() raises:
    """``shutdown`` request → response → ``exit`` notification, before any
    signal.

    We used to go straight to SIGTERM. That works, but it skips whatever the
    server does on the way out — rust-analyzer and jdtls flush caches and
    workspace state on shutdown, and killing them mid-flush makes the *next*
    session re-index or start from a partial cache.

    Asserted from the mock's request log, which is the only way to see what
    the client sent: both messages must be there, in order, and ``exit`` must
    be last.
    """
    var dir = _scratch_dir(String("shutdown"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var log = dir + String("/requests.jsonl")
    var m = LspManager()
    if not _start_mock(m, String("utf8_negotiated.json"), dir, log):
        return
    m.notify_opened(path, text)
    _pump(m, 20)
    m.shutdown()

    var sent = _log_messages(log)
    var shutdown_at = -1
    var exit_at = -1
    for i in range(len(sent)):
        var m_opt = sent[i].object_get(String("method"))
        if not m_opt or not m_opt.value().is_string():
            continue
        var name = m_opt.value().as_str()
        if name == String("shutdown") and shutdown_at < 0:
            shutdown_at = i
        elif name == String("exit") and exit_at < 0:
            exit_at = i
    assert_true(shutdown_at >= 0)
    assert_true(exit_at >= 0)
    assert_true(shutdown_at < exit_at)
    assert_equal(exit_at, len(sent) - 1)


def test_begin_shutdown_returns_immediately_and_polls_to_done() raises:
    """The close handshake must not block its caller.

    Closing a window used to wait out the LSP ``shutdown`` → ``exit``
    round-trip on the UI thread, so the window stayed on screen until the
    slowest language server answered. ``begin_shutdown`` now returns at
    once and the host drains with ``shutdown_poll`` off the runloop
    (``drainClosingDesktop`` in the Swift host), which is what makes the
    close instant while still sending the polite goodbye.

    Asserted two ways: ``begin_shutdown`` returns in well under the
    handshake's own grace budget, and the messages still reach the server
    in spec order.
    """
    var dir = _scratch_dir(String("begin_close"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var log = dir + String("/requests.jsonl")
    var m = LspManager()
    if not _start_mock(m, String("utf8_negotiated.json"), dir, log):
        return
    m.notify_opened(path, text)
    _pump(m, 20)

    var started = monotonic_ms()
    m.begin_shutdown()
    var begin_ms = monotonic_ms() - started
    # The response budget alone is 300 ms; returning inside 100 ms proves
    # we didn't wait for the server at all.
    assert_true(begin_ms < 100)
    assert_true(m.is_closing())

    var done = False
    for _ in range(200):
        if m.shutdown_poll():
            done = True
            break
        sleep_ms(10)
    assert_true(done)
    assert_false(m.is_closing())
    m.finish_shutdown()

    var sent = _log_messages(log)
    var shutdown_at = -1
    var exit_at = -1
    for i in range(len(sent)):
        var m_opt = sent[i].object_get(String("method"))
        if not m_opt or not m_opt.value().is_string():
            continue
        var name = m_opt.value().as_str()
        if name == String("shutdown") and shutdown_at < 0:
            shutdown_at = i
        elif name == String("exit") and exit_at < 0:
            exit_at = i
    assert_true(shutdown_at >= 0)
    assert_true(exit_at >= 0)
    assert_true(shutdown_at < exit_at)


def test_shutdown_poll_bounds_a_server_that_never_answers() raises:
    """A server that accepts ``shutdown`` and never replies, and outlives
    ``exit``, must still let the close complete.

    This is what the grace budgets are for, and the property that matters is
    that they *end*: a handle whose poll never returns done would be
    stranded forever by the native host's drain loop, keeping the window's
    child processes alive for the rest of the session — the exact leak the
    teardown path exists to prevent. ``finish_shutdown`` then SIGTERMs the
    straggler, which is what used to happen unconditionally.
    """
    var dir = _scratch_dir(String("close_ignored"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(m, String("shutdown_ignored.json"), dir, String("")):
        return
    m.begin_shutdown()
    assert_true(m.is_closing())
    # Must NOT report done immediately — that would mean the handshake was
    # skipped rather than waited out.
    assert_false(m.shutdown_poll())

    var started = monotonic_ms()
    var done = False
    for _ in range(300):
        if m.shutdown_poll():
            done = True
            break
        sleep_ms(10)
    var elapsed = monotonic_ms() - started
    assert_true(done)
    # Both budgets elapsed (300 ms response + 200 ms exit) and no more.
    assert_true(elapsed >= 400)
    assert_true(elapsed < 2000)
    m.finish_shutdown()
    # The straggler was signalled and reaped, so nothing is left running.
    assert_false(m.is_ready())


def test_shutdown_is_idempotent_and_survives_a_dead_server() raises:
    """A second ``shutdown`` must be a no-op, and shutting down a server
    that already died must not stall for the handshake budget. The bound
    exists so a wedged server costs a capped stall, but a *dead* one should
    cost nothing at all — the write fails and we bail immediately."""
    var dir = _scratch_dir(String("shutdown_twice"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(m, String("utf8_negotiated.json"), dir, String("")):
        return
    m.shutdown()
    var started = monotonic_ms()
    m.shutdown()
    m.shutdown()
    var elapsed = monotonic_ms() - started
    # Two extra shutdowns of an already-closed session: no handshake, no
    # sleeps. Generous bound so a loaded machine doesn't flake it.
    assert_true(elapsed < 200)


def test_server_refresh_requests_are_answered_and_raise_a_flag() raises:
    """``workspace/{inlayHint,codeLens,diagnostic}/refresh``.

    These are server→client *requests*, so an unanswered one leaves the
    server waiting (the taplo failure mode). We answered MethodNotFound,
    which is worse than useless here: the server stops asking, and the
    stale inlay hints / code lenses already on screen sit there until the
    buffer's line count happens to change — for a build finishing or a
    dependency resolving, possibly never.

    Now they're answered with null and raise a flag the host drains to drop
    its debounce key. The diagnostics variant additionally clears the
    "already pulled this path" record, which re-arms the host's existing
    pull gate without the host needing to know refresh exists.
    """
    var dir = _scratch_dir(String("refresh"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(m, String("refresh_requests.json"), dir, String("")):
        return
    m.notify_opened(path, text)
    _pump(m)
    # Both flags raised, each consumed exactly once.
    assert_true(m.take_document_refresh())
    assert_false(m.take_document_refresh())
    assert_true(m.take_diagnostics_refresh())
    assert_false(m.take_diagnostics_refresh())
    # The session survived: an answered request means the server isn't
    # blocked, so it kept processing.
    assert_true(m.is_ready())
    m.shutdown()


def test_code_action_resolve_fills_in_the_withheld_edit() raises:
    """``codeAction/resolve`` — rust-analyzer's actual shape.

    With ``codeActionProvider.resolveProvider``, a server returns actions
    carrying a title and a ``data`` blob and **no** ``edit``. The host keeps
    only actions it can act on (an edit or a command), so before the resolve
    round-trip existed every one of those was filtered out: an empty
    quick-fix menu on a buffer full of fixable diagnostics.

    Resolution happens inside the manager, before the list is published, so
    the host's contract is unchanged and it needs to know nothing about
    resolve. Three things are pinned here: the withheld edit arrives, an
    action that already had an inline edit is left alone (no wasted
    round-trip, and its edit isn't overwritten), and a resolve does **not**
    rewrite the title — that row is already on screen.
    """
    var dir = _scratch_dir(String("ca_resolve"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("resolve_code_actions.json"), dir, String(""),
    ):
        return
    assert_true(m.server_supports_code_action_resolve())
    var probe = Diagnostic(
        0, 0, 0, 3, 1, String("probe"), String("mock"), String("c"),
    )
    assert_true(m.request_code_actions(path, probe, text))
    _pump(m)
    assert_true(m.has_pending_code_actions())
    var actions = m.take_code_actions()
    assert_equal(len(actions), 3)

    # Titles survive resolve untouched, in the server's original order.
    assert_equal(actions[0].title, String("resolve me"))
    assert_equal(actions[1].title, String("resolve me too"))
    assert_equal(actions[2].title, String("already inline"))

    # The two data-only actions got their edits from the resolve.
    for i in range(2):
        assert_equal(len(actions[i].file_edits), 1)
        assert_equal(uri_to_path(actions[i].file_edits[0].uri), path)
        assert_equal(len(actions[i].file_edits[0].edits), 1)
        assert_equal(
            actions[i].file_edits[0].edits[0].new_text,
            String("from_resolve\n"),
        )
    # The inline one kept its own edit.
    assert_equal(len(actions[2].file_edits), 1)
    assert_equal(
        actions[2].file_edits[0].edits[0].new_text, String("inline\n"),
    )
    m.shutdown()


def test_code_action_resolve_that_never_answers_still_settles() raises:
    """A server that accepts the resolve and never replies must not leave
    the quick-fix menu on "Loading fixes…" forever.

    After the resolve deadline the manager publishes what it has — the
    actions that already carried inline edits — so the menu settles with a
    shorter list rather than hanging. Same reasoning as the diagnostics
    in-flight cap: a bounded wrong-ish answer beats an unbounded spinner.
    """
    var dir = _scratch_dir(String("ca_resolve_hang"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("resolve_code_actions_hangs.json"), dir, String(""),
    ):
        return
    var probe = Diagnostic(
        0, 0, 0, 3, 1, String("probe"), String("mock"), String("c"),
    )
    assert_true(m.request_code_actions(path, probe, text))
    # Nothing may publish while the resolve is outstanding.
    _pump(m, 20)
    assert_false(m.has_pending_code_actions())
    # Pump past the deadline (see ``_CA_RESOLVE_TIMEOUT_MS``).
    for _ in range(60):
        _ = m.tick()
        if m.has_pending_code_actions():
            break
        sleep_ms(50)
    assert_true(m.has_pending_code_actions())
    var actions = m.take_code_actions()
    assert_equal(len(actions), 2)
    # The unresolved one comes through with no edits (the host filters it);
    # the inline one is intact.
    assert_equal(len(actions[0].file_edits), 0)
    assert_equal(len(actions[1].file_edits), 1)
    assert_true(m.is_ready())
    m.shutdown()


def test_document_link_resolve_fills_in_a_deferred_target() raises:
    """``documentLink/resolve``.

    ``DocumentLink.target`` is optional; with
    ``documentLinkProvider.resolveProvider`` the server withholds it and
    fills it in on request (``vscode-json-language-server`` does this for
    every ``$ref``). The parse used to drop targetless links, so they were
    silently un-clickable.

    Publication is deliberately *not* gated on the resolves: links are
    decorative, so the ones with inline targets appear immediately and the
    list is re-published as each target lands. What the host never sees is a
    link with an empty target — an underline that does nothing on click is
    worse than no underline, which is what the original drop was protecting
    against.
    """
    var dir = _scratch_dir(String("dl_resolve"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var m = LspManager()
    if not _start_mock(
        m, String("resolve_document_links.json"), dir, String(""),
    ):
        return
    assert_true(m.server_supports_document_link_resolve())
    assert_true(m.request_document_links(path, text))
    _pump(m)
    assert_true(m.has_pending_doclinks())
    var links = m.take_doclinks()
    assert_equal(len(links), 2)
    # Order follows the server's; the resolved one is first.
    assert_equal(links[0].start_line, 0)
    assert_equal(links[0].new_text, String("file:///resolved/target.py"))
    assert_equal(links[1].start_line, 1)
    assert_equal(links[1].new_text, String("file:///inline/target.py"))
    m.shutdown()


def test_file_rename_and_delete_notify_the_server() raises:
    """``workspace/didRenameFiles`` and ``workspace/didDeleteFiles``.

    We advertise ``workspace.fileOperations`` for these, so a server that
    accepts expects them — and the rename one is the notification that
    actually changes what the user sees: pyright and
    typescript-language-server rewrite every import of a renamed module when
    they get it, and do nothing at all when they don't.

    Asserted from the mock's request log with the URIs checked, because the
    ``oldUri``/``newUri`` pairing is the part that's easy to get backwards.
    """
    var dir = _scratch_dir(String("file_ops"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var log = dir + String("/requests.jsonl")
    var m = LspManager()
    if not _start_mock(m, String("file_operations.json"), dir, log):
        return
    assert_true(m.server_wants_did_rename())
    assert_true(m.server_wants_did_delete())

    var moved = dir + String("/renamed.py")
    m.notify_did_rename_files(path, moved)
    m.notify_did_delete_files(moved)
    _pump(m, 20)

    var sent = _log_messages(log)
    var rn = _find_sent(sent, String("workspace/didRenameFiles"))
    assert_true(Bool(rn))
    var rfiles = rn.value().object_get(String("files"))
    assert_true(Bool(rfiles))
    assert_equal(rfiles.value().array_len(), 1)
    var entry = rfiles.value().array_at(0)
    var old_uri = entry.object_get(String("oldUri"))
    var new_uri = entry.object_get(String("newUri"))
    assert_true(Bool(old_uri))
    assert_true(Bool(new_uri))
    assert_equal(uri_to_path(old_uri.value().as_str()), path)
    assert_equal(uri_to_path(new_uri.value().as_str()), moved)

    var dl = _find_sent(sent, String("workspace/didDeleteFiles"))
    assert_true(Bool(dl))
    var dfiles = dl.value().object_get(String("files"))
    assert_true(Bool(dfiles))
    assert_equal(dfiles.value().array_len(), 1)
    var duri = dfiles.value().array_at(0).object_get(String("uri"))
    assert_true(Bool(duri))
    assert_equal(uri_to_path(duri.value().as_str()), moved)
    m.shutdown()


def test_file_operations_are_silent_when_the_server_opts_out() raises:
    """A server that doesn't advertise ``workspace.fileOperations`` must not
    be sent the notifications. We advertise the capability from our side, but
    that only says we *will* send them — the server's half of the negotiation
    decides whether we do."""
    var dir = _scratch_dir(String("file_ops_off"))
    var path = dir + String("/emdash.py")
    var text = _emdash_buffer()
    assert_true(write_file(path, text))
    var log = dir + String("/requests.jsonl")
    var m = LspManager()
    if not _start_mock(m, String("utf8_negotiated.json"), dir, log):
        return
    assert_false(m.server_wants_did_rename())
    assert_false(m.server_wants_did_delete())
    m.notify_did_rename_files(path, dir + String("/x.py"))
    m.notify_did_delete_files(path)
    _pump(m, 20)
    var sent = _log_messages(log)
    assert_false(Bool(_find_sent(sent, String("workspace/didRenameFiles"))))
    assert_false(Bool(_find_sent(sent, String("workspace/didDeleteFiles"))))
    m.shutdown()


def test_retiring_a_server_leaves_the_list_at_once_and_drains_later() raises:
    """LSP ▸ Restart (and a settings change to a server's argv) must not
    block the editor.

    Both used to call the blocking ``shutdown`` on the UI thread, so
    restarting a server froze the editor for as long as that server took to
    answer — and for a wedged one, for the whole grace budget, mid-keystroke
    in the Settings case.

    ``retire_lsp_manager`` removes it from ``lsp_managers`` immediately
    (which is what the user's next frame sees) and parks it on
    ``_closing_lsp``, drained by ``process_external_changes`` — the one
    per-frame hook both frontends run. The server here ignores both
    ``shutdown`` and ``exit``, so the drain is exercised against the worst
    case rather than a server that exits before the first poll.
    """
    var dir = _scratch_dir(String("retire"))
    var m = LspManager()
    if not _start_mock(m, String("shutdown_ignored.json"), dir, String("")):
        return

    var d = Desktop()
    d.lsp_managers.append(m^)
    d.lsp_languages.append(String("python"))
    assert_equal(len(d.lsp_managers), 1)

    var started = monotonic_ms()
    d.retire_lsp_manager(0)
    var retire_ms = monotonic_ms() - started
    # Gone from the live list instantly, and the call itself didn't wait.
    assert_equal(len(d.lsp_managers), 0)
    assert_equal(len(d.lsp_languages), 0)
    assert_equal(len(d._closing_lsp), 1)
    assert_true(retire_ms < 100)

    # The per-frame hook finishes it off without anyone blocking.
    var drained = False
    for _ in range(300):
        d.process_external_changes(_SCREEN)
        if len(d._closing_lsp) == 0:
            drained = True
            break
        sleep_ms(10)
    assert_true(drained)
    d.shutdown()


def test_retire_lsp_manager_ignores_an_out_of_range_index() raises:
    """Retiring an index that isn't there is a no-op, not a crash. The
    callers compute the index from a focused-editor lookup that can race a
    window close."""
    var d = Desktop()
    d.retire_lsp_manager(0)
    d.retire_lsp_manager(-1)
    d.retire_lsp_manager(7)
    assert_equal(len(d.lsp_managers), 0)
    assert_equal(len(d._closing_lsp), 0)
    d.shutdown()



def main() raises:
    setup_test_env()
    test_position_encoding_names_round_trip()
    test_utf16_conversion_counts_em_dash_as_one_unit()
    test_utf16_conversion_counts_emoji_as_a_surrogate_pair()
    test_position_conversion_snaps_inside_a_codepoint()
    test_position_conversion_clamps_past_end_of_line()
    test_line_table_indexes_rows_and_strips_crlf()
    test_line_table_empty_and_trailing_newline()
    test_server_without_negotiation_gets_utf16_columns_converted()
    test_server_negotiating_utf8_passes_columns_through()
    test_utf16_conversion_reaches_references_and_workspace_edits()
    test_spec_shape_definition_accepts_every_variant()
    test_spec_shape_hover_markup_content()
    test_spec_shape_hover_bare_string()
    test_spec_shape_hover_marked_string_array()
    test_spec_shape_completion_list_and_item_variants()
    test_adversarial_wrong_types_degrade_without_crashing()
    test_adversarial_null_results_read_as_answered_not_pending()
    test_adversarial_out_of_range_positions_clamp()
    test_adversarial_framing_split_frames_and_garbage()
    test_adversarial_server_requests_are_position_converted()
    test_workspace_edit_document_changes_is_parsed_and_converted()
    test_workspace_edit_with_file_operations_is_refused_whole()
    test_code_action_resolve_fills_in_the_withheld_edit()
    test_document_link_resolve_fills_in_a_deferred_target()
    test_file_rename_and_delete_notify_the_server()
    test_file_operations_are_silent_when_the_server_opts_out()
    test_code_action_resolve_that_never_answers_still_settles()
    test_server_refresh_requests_are_answered_and_raise_a_flag()
    test_shutdown_performs_the_spec_handshake()
    test_begin_shutdown_returns_immediately_and_polls_to_done()
    test_shutdown_poll_bounds_a_server_that_never_answers()
    test_retiring_a_server_leaves_the_list_at_once_and_drains_later()
    test_retire_lsp_manager_ignores_an_out_of_range_index()
    test_shutdown_is_idempotent_and_survives_a_dead_server()
    print("lsp_conformance: 35 tests passed")
