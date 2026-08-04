"""LSP client: requests, responses, servers, installs.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.editor import Editor
from turbokod.desktop import Desktop
from turbokod.file_io import read_file, rename_path, stat_file, write_file
from turbokod.install_runner import InstallResult, InstallRunner, _last_lines
from turbokod.json import (
    JsonValue, json_array, json_int, json_null, json_object, json_str,
    parse_json
)
from turbokod.type_ahead import TypeAhead, type_ahead_pick
from turbokod.lsp import (
    LSP_NOTIFICATION, LSP_REQUEST, LSP_RESPONSE, LspClient, LspIncoming,
    LspProcess, _drop_prefix, _find_double_crlf, _parse_content_length,
    classify_message, lsp_initialize_params
)
from turbokod.lsp_dispatch import (
    CodeAction, CodeActionFileEdit, CompletionItem, DIAG_SEVERITY_ERROR,
    DIAG_SEVERITY_HINT, DIAG_SEVERITY_INFO, DIAG_SEVERITY_WARNING, Diagnostic,
    DefinitionResolved, LspManager, _STATE_READY, TextEditEntry,
    _parse_additional_text_edits, _parse_code_action_result,
    _parse_completion_result, _parse_diagnostics_array, _parse_code_lens,
    _collect_unresolved_lenses, _codelens_title_of, _codelens_row_of,
    _parse_document_links, _parse_document_colors, _parse_document_highlights,
    _parse_hierarchy_result, _parse_monikers, _unit_text,
    _parse_inline_completion, _parse_linked_ranges, _parse_inline_values,
    _parse_inline_value_exprs, _parse_folding_ranges, _parse_inlay_hints,
    _parse_selection_ranges, _parse_hover_result,
    _parse_prepare_rename_placeholder, _parse_signature_help,
    _parse_references_result, _parse_text_edits,
    _parse_workspace_edit_changes, _path_to_uri, _uri_to_path
)
from turbokod.highlight import (
    highlight_for_extension, highlight_operator_attr, highlight_string_attr
)
from turbokod.posix import which
from turbokod.grammar_install import (
    built_in_downloadable_grammars, find_downloadable_grammar_by_language,
    find_downloadable_grammar_for_extension
)

from support import _contains, _hl_lines, _temp_path, setup_test_env


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_rename_path_moves_file() raises:
    var src = _temp_path(String("_ren_src.txt"))
    var dst = _temp_path(String("_ren_dst.txt"))
    # Clean any leftovers from a prior crashed run.
    _ = external_call["unlink", Int32]((dst + String("\0")).unsafe_ptr())
    assert_true(write_file(src, String("payload")))
    assert_true(rename_path(src, dst))
    # Source is gone, destination carries the bytes.
    assert_false(stat_file(src).ok)
    assert_true(stat_file(dst).ok)
    assert_equal(read_file(dst), String("payload"))
    _ = external_call["unlink", Int32]((dst + String("\0")).unsafe_ptr())


def test_downloadable_grammar_registry_has_elm() raises:
    """The seed entry — opening a ``.elm`` file is what triggers the
    download prompt in ``Desktop._maybe_prompt_grammar_install``."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_for_extension(specs, String("elm"))
    assert_true(idx >= 0)
    assert_equal(specs[idx].language_id, String("elm"))
    assert_equal(specs[idx].display, String("Elm"))
    var by_lang = find_downloadable_grammar_by_language(specs, String("elm"))
    assert_equal(by_lang, idx)


def test_downloadable_grammar_registry_misses_unknown() raises:
    """``txt`` shouldn't trigger a grammar prompt — keeps the prompt
    machinery from firing on every file the user opens."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_for_extension(specs, String("txt"))
    assert_equal(idx, -1)


def test_type_ahead_pick_returns_index_or_minus_one() raises:
    """The framework helper any list widget can call: append the
    keystroke, return the matching index, or -1 on no match. Empty
    sentinel rows are skipped so a typed letter doesn't snap to the
    leading "(none)" entry."""
    var ta = TypeAhead()
    var opts = List[String]()
    opts.append(String(""))
    opts.append(String("apple"))
    opts.append(String("banana"))
    opts.append(String("cherry"))
    assert_equal(type_ahead_pick(ta, opts, String("b")), 2)
    assert_equal(type_ahead_pick(ta, opts, String("z")), -1)


def test_type_ahead_pick_solo_fallback() raises:
    """When the accumulated prefix doesn't match, retry with just
    the new char so a stale chain doesn't make the next keystroke
    feel like a dead key."""
    var ta = TypeAhead()
    var opts = List[String]()
    opts.append(String("apple"))
    opts.append(String("banana"))
    opts.append(String("zebra"))
    assert_equal(type_ahead_pick(ta, opts, String("b")), 1)
    # 'bz' matches nothing; solo 'z' wins.
    assert_equal(type_ahead_pick(ta, opts, String("z")), 2)


def test_intellij_language_injection_html_in_python_string() raises:
    """A ``# language=html`` marker on the line above a string literal
    re-tokenizes the string body with the HTML grammar. We verify by
    looking for HTML-specific punctuation (``<`` / ``>``) painted as
    operator color inside the body — that highlight wouldn't fire
    against plain Python string content."""
    var lines = _hl_lines(
        String("# language=html"),
        String("html_str = \"<a>link</a>\""),
    )
    var hls = highlight_for_extension(String("py"), lines)
    # The body sits between cols 12 and 22 on row 1 (after the
    # opening ``"`` and before the closing ``"``).
    var saw_op_inside_body = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row != 1:
            continue
        if h.col_start < 12 or h.col_end > 23:
            continue
        if h.attr == highlight_operator_attr():
            saw_op_inside_body = True
    assert_true(saw_op_inside_body)


def test_intellij_language_injection_inline_marker() raises:
    """The marker can sit on the same line as the string when written
    in a block-comment form (``/* language=css */``). The injection
    pass scans forward from the marker's end, so the trailing
    backtick string on the same line gets injected as CSS.

    Uses ``js`` extension so the host grammar and injected grammar
    are different, exercising the registry-share path."""
    var lines = _hl_lines(
        String("const styles = /* language=css */ `.cls { color: red; }`;"),
    )
    var hls = highlight_for_extension(String("js"), lines)
    # The CSS body inside the backticks is at roughly cols 35..54.
    # CSS's ``color`` property and selector punctuation produce
    # multiple non-string highlights — without injection the body
    # would be a single string-attr run.
    var non_string_in_body = 0
    for i in range(len(hls)):
        var h = hls[i]
        if h.row != 0:
            continue
        if h.col_start < 35 or h.col_end > 55:
            continue
        if h.attr != highlight_string_attr():
            non_string_in_body += 1
    assert_true(non_string_in_body > 0)


def test_intellij_language_injection_unknown_language_no_op() raises:
    """A marker pointing at a language we don't have a grammar for
    is a silent no-op — the host grammar's highlights stay
    untouched. ``language=brainfuck`` has no entry in
    ``_ext_for_language``, so the body keeps its plain Python
    string color."""
    var lines = _hl_lines(
        String("# language=brainfuck"),
        String("prog = \"+++[->+<]\""),
    )
    var hls = highlight_for_extension(String("py"), lines)
    # The string body should still paint as a regular Python string —
    # i.e. at least one string-attr highlight covers row 1's body
    # cols, and no operator-attr highlight does.
    var saw_string_on_row1 = False
    var saw_op_inside_body = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row != 1:
            continue
        if h.attr == highlight_string_attr():
            saw_string_on_row1 = True
        if h.col_start >= 8 and h.col_end <= 18 \
                and h.attr == highlight_operator_attr():
            saw_op_inside_body = True
    assert_true(saw_string_on_row1)
    assert_true(not saw_op_inside_body)


def test_intellij_language_injection_triple_quoted_python() raises:
    """Triple-quoted Python strings span multiple lines. The injection
    pass walks across rows to find the closing ``\"\"\"`` and
    tokenizes every body row with the injected grammar. Verified by
    finding HTML highlights on the *interior* row of the docstring,
    where the body sits below the opening row."""
    var lines = _hl_lines(
        String("# language=html"),
        String("doc = \"\"\""),
        String("<div class='x'>hello</div>"),
        String("\"\"\""),
    )
    var hls = highlight_for_extension(String("py"), lines)
    # Row 2 (the interior body row) should have several HTML
    # highlights: tag punctuation, attribute name, etc. — and at
    # least one operator-attr from ``<`` / ``>`` / ``=``.
    var saw_op_on_row2 = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 2 and h.attr == highlight_operator_attr():
            saw_op_on_row2 = True
    assert_true(saw_op_on_row2)


def test_uri_to_path_percent_decodes() raises:
    """Server-originated file URIs percent-encode spaces / non-ASCII; the
    path must be decoded or it won't match open docs or files on disk."""
    assert_equal(
        _uri_to_path(String("file:///tmp/my%20dir/a%2Bb.txt")),
        String("/tmp/my dir/a+b.txt"),
    )
    # UTF-8 bytes (C3 A4 == ä) decode back to the original characters.
    assert_equal(
        _uri_to_path(String("file:///tmp/caf%C3%A9.txt")),
        String("/tmp/café.txt"),
    )
    # A malformed trailing % is left literal, no crash.
    assert_equal(_uri_to_path(String("file:///tmp/a%")), String("/tmp/a%"))
    # Non-file strings pass through untouched.
    assert_equal(_uri_to_path(String("/plain/path")), String("/plain/path"))


def test_lsp_framer_finds_double_crlf() raises:
    var buf = _bytes_of(String("Content-Length: 5\r\n\r\nhello"))
    var idx = _find_double_crlf(buf)
    assert_equal(idx, 17)
    var none_buf = _bytes_of(String("no header here"))
    assert_equal(_find_double_crlf(none_buf), -1)


def test_lsp_framer_parses_content_length() raises:
    var buf = _bytes_of(String("Content-Length: 42\r\n\r\n"))
    var hdr_end = _find_double_crlf(buf)
    assert_equal(_parse_content_length(buf, hdr_end), 42)
    var buf2 = _bytes_of(String("content-length: 7\r\n\r\n"))
    assert_equal(_parse_content_length(buf2, _find_double_crlf(buf2)), 7)
    var buf3 = _bytes_of(String(
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n"
        + "Content-Length: 11\r\n\r\n"
    ))
    assert_equal(_parse_content_length(buf3, _find_double_crlf(buf3)), 11)


def test_lsp_framer_extract_one_message() raises:
    var p = LspProcess()
    var hello = String("Content-Length: 5\r\n\r\nhello")
    var hb = hello.as_bytes()
    for i in range(len(hb)):
        p._read_buffer.append(hb[i])
    var got1 = p._extract_one_message()
    assert_true(Bool(got1))
    assert_equal(got1.value(), String("hello"))
    assert_equal(len(p._read_buffer), 0)
    var two = String("Content-Length: 3\r\n\r\nfooContent-Length: 3\r\n\r\nbar")
    var tb = two.as_bytes()
    for i in range(len(tb)):
        p._read_buffer.append(tb[i])
    var first = p._extract_one_message()
    assert_true(Bool(first))
    assert_equal(first.value(), String("foo"))
    var second = p._extract_one_message()
    assert_true(Bool(second))
    assert_equal(second.value(), String("bar"))
    assert_equal(len(p._read_buffer), 0)
    var part = String("Content-Length: 4\r\n\r\nab")
    var pb = part.as_bytes()
    for i in range(len(pb)):
        p._read_buffer.append(pb[i])
    var none1 = p._extract_one_message()
    assert_false(Bool(none1))
    p._read_buffer.append(0x63)
    p._read_buffer.append(0x64)
    var done = p._extract_one_message()
    assert_true(Bool(done))
    assert_equal(done.value(), String("abcd"))


def test_lsp_drop_prefix_helper() raises:
    var b = _bytes_of(String("hello world"))
    var rest = _drop_prefix(b^, 6)
    assert_equal(len(rest), 5)
    var s = String(StringSlice(ptr=rest.unsafe_ptr(), length=len(rest)))
    assert_equal(s, String("world"))


def test_lsp_classify_message() raises:
    var resp = parse_json(String(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}"
    ))
    var c = classify_message(resp)
    assert_equal(Int(c.kind), Int(LSP_RESPONSE))
    assert_true(Bool(c.id))
    assert_true(c.id.value().is_int())
    assert_equal(c.id.value().as_int(), 7)
    assert_true(Bool(c.result))
    var note = parse_json(String(
        "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\","
        + "\"params\":{\"type\":3,\"message\":\"hi\"}}"
    ))
    var cn = classify_message(note)
    assert_equal(Int(cn.kind), Int(LSP_NOTIFICATION))
    assert_equal(cn.method.value(), String("window/logMessage"))
    # esbonio sends ``workspace/configuration`` requests with a UUID
    # string id. Must classify as REQUEST (not NOTIFICATION) so the
    # server-request handler fires, and ``id`` must preserve the
    # string form so the response echoes the right id and esbonio
    # actually pairs them. Without this fix esbonio hangs forever.
    var str_req = parse_json(String(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc-123\","
        + "\"method\":\"workspace/configuration\","
        + "\"params\":{\"items\":[]}}"
    ))
    var cr = classify_message(str_req)
    assert_equal(Int(cr.kind), Int(LSP_REQUEST))
    assert_true(Bool(cr.id))
    assert_true(cr.id.value().is_string())
    assert_equal(cr.id.value().as_str(), String("abc-123"))
    assert_equal(cr.method.value(), String("workspace/configuration"))


def test_lsp_parse_diagnostics_array_minimum_fields() raises:
    """A publishDiagnostics ``diagnostics`` array with only the spec-
    required fields (range only) must still parse. Severity defaults
    to Info per the spec; message/source come back empty."""
    var v = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":3,\"character\":2},"
        + "\"end\":{\"line\":3,\"character\":7}}}]"
    ))
    var diags = _parse_diagnostics_array(v)
    assert_equal(len(diags), 1)
    assert_equal(diags[0].start_row, 3)
    assert_equal(diags[0].start_col, 2)
    assert_equal(diags[0].end_row, 3)
    assert_equal(diags[0].end_col, 7)
    assert_equal(diags[0].severity, DIAG_SEVERITY_INFO)
    assert_equal(diags[0].message, String(""))
    assert_equal(diags[0].source, String(""))


def test_lsp_parse_diagnostics_array_full_fields() raises:
    """All four severities + message + source round-trip exactly."""
    var v = parse_json(String(
        "["
        + "{\"range\":{\"start\":{\"line\":1,\"character\":0},"
        + "\"end\":{\"line\":1,\"character\":5}},"
        + "\"severity\":1,\"message\":\"undefined name\",\"source\":\"pyright\"},"
        + "{\"range\":{\"start\":{\"line\":2,\"character\":0},"
        + "\"end\":{\"line\":2,\"character\":4}},"
        + "\"severity\":2,\"message\":\"unused import\",\"source\":\"ruff\"},"
        + "{\"range\":{\"start\":{\"line\":3,\"character\":0},"
        + "\"end\":{\"line\":3,\"character\":3}},"
        + "\"severity\":3,\"message\":\"info\"},"
        + "{\"range\":{\"start\":{\"line\":4,\"character\":0},"
        + "\"end\":{\"line\":4,\"character\":2}},"
        + "\"severity\":4,\"message\":\"hint\"}"
        + "]"
    ))
    var diags = _parse_diagnostics_array(v)
    assert_equal(len(diags), 4)
    assert_equal(diags[0].severity, DIAG_SEVERITY_ERROR)
    assert_equal(diags[0].message, String("undefined name"))
    assert_equal(diags[0].source, String("pyright"))
    assert_equal(diags[1].severity, DIAG_SEVERITY_WARNING)
    assert_equal(diags[1].source, String("ruff"))
    assert_equal(diags[2].severity, DIAG_SEVERITY_INFO)
    assert_equal(diags[3].severity, DIAG_SEVERITY_HINT)


def test_lsp_parse_diagnostics_preserves_code_field() raises:
    """The diagnostic ``code`` field (rule identifier — "unresolved-
    reference", "unused-import", …) must round-trip through the parser
    so the host can echo it back in ``textDocument/codeAction`` requests.
    Without it, ty / ruff / pyright return ``result: null`` instead of
    the matching quickfix. Both string and integer codes are accepted
    (the LSP spec allows either)."""
    var v = parse_json(String(
        "["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":4},"
        + "\"end\":{\"line\":0,\"character\":13}},"
        + "\"severity\":1,\"code\":\"unresolved-reference\","
        + "\"message\":\"Name x used when not defined\"},"
        + "{\"range\":{\"start\":{\"line\":1,\"character\":0},"
        + "\"end\":{\"line\":1,\"character\":4}},"
        + "\"severity\":2,\"code\":42,\"message\":\"warn\"}"
        + "]"
    ))
    var diags = _parse_diagnostics_array(v)
    assert_equal(len(diags), 2)
    assert_equal(diags[0].code, String("unresolved-reference"))
    # Integer codes are coerced to their decimal string form.
    assert_equal(diags[1].code, String("42"))


def test_lsp_parse_code_action_result_quickfix_with_workspace_edit() raises:
    """Canonical ``CodeAction[]`` shape: one ``quickfix`` carrying a
    ``WorkspaceEdit.changes`` map. Verifies title / kind / isPreferred
    survive parsing and the file-edit group flattens correctly with the
    insertion range + ``newText`` preserved."""
    var v = parse_json(String(
        "["
        + "{\"title\":\"import typing.Any\",\"kind\":\"quickfix\","
        + "\"isPreferred\":true,"
        + "\"edit\":{\"changes\":{"
        + "\"file:///tmp/x.py\":["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":0,\"character\":0}},"
        + "\"newText\":\"from typing import Any\\n\"}"
        + "]}}}"
        + "]"
    ))
    var actions = _parse_code_action_result(v)
    assert_equal(len(actions), 1)
    assert_equal(actions[0].title, String("import typing.Any"))
    assert_equal(actions[0].kind, String("quickfix"))
    assert_true(actions[0].is_preferred)
    assert_equal(len(actions[0].file_edits), 1)
    assert_equal(actions[0].file_edits[0].uri, String("file:///tmp/x.py"))
    assert_equal(len(actions[0].file_edits[0].edits), 1)
    var te = actions[0].file_edits[0].edits[0]
    assert_equal(te.start_line, 0)
    assert_equal(te.start_char, 0)
    assert_equal(te.end_line, 0)
    assert_equal(te.end_char, 0)
    assert_equal(te.new_text, String("from typing import Any\n"))


def test_lsp_parse_code_action_result_skips_bare_commands() raises:
    """Entries without a ``title`` aren't valid CodeActions, and bare
    ``Command`` entries (no inline ``edit``) are silently skipped so the
    quickfix popup doesn't show actions we have no way to apply yet."""
    var v = parse_json(String(
        "["
        + "{\"command\":\"server.fix\",\"arguments\":[1]},"
        + "{\"title\":\"Run code fix\",\"command\":\"server.fix\"},"
        + "{\"title\":\"Import X\",\"kind\":\"quickfix\","
        + "\"edit\":{\"changes\":{"
        + "\"file:///a.py\":["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":0,\"character\":0}},"
        + "\"newText\":\"import X\\n\"}"
        + "]}}}"
        + "]"
    ))
    var actions = _parse_code_action_result(v)
    # The bare command (no title) is dropped; the command-only action
    # (title but no edit) is kept with an empty file_edits list so the
    # caller can detect + skip; the literal CodeAction is fully parsed.
    assert_equal(len(actions), 2)
    assert_equal(actions[0].title, String("Run code fix"))
    assert_equal(len(actions[0].file_edits), 0)
    # The command-only action now carries its command id (run via
    # workspace/executeCommand).
    assert_equal(actions[0].command, String("server.fix"))
    assert_equal(actions[1].title, String("Import X"))
    assert_equal(len(actions[1].file_edits), 1)


def test_lsp_parse_code_action_result_null_or_non_array_is_empty() raises:
    """``textDocument/codeAction`` may legally respond ``null`` (no
    actions available) — the parser must hand back an empty list rather
    than raise. Same for unexpected shapes (object instead of array)."""
    var nv = parse_json(String("null"))
    assert_equal(len(_parse_code_action_result(nv)), 0)
    var ov = parse_json(String("{\"unexpected\":true}"))
    assert_equal(len(_parse_code_action_result(ov)), 0)


def test_lsp_parse_rename_workspace_edit_multi_file() raises:
    """A ``textDocument/rename`` response *is* a ``WorkspaceEdit`` (no
    CodeAction wrapper). ``_parse_workspace_edit_changes`` must flatten its
    ``changes`` map — across multiple files — into per-file edit groups,
    the same shape the code-action path produces, so the host can apply it
    with ``Editor.apply_code_action_edits``."""
    var v = parse_json(String(
        "{\"changes\":{"
        + "\"file:///tmp/a.py\":["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":4},"
        + "\"end\":{\"line\":0,\"character\":7}},\"newText\":\"baz\"},"
        + "{\"range\":{\"start\":{\"line\":2,\"character\":0},"
        + "\"end\":{\"line\":2,\"character\":3}},\"newText\":\"baz\"}"
        + "],"
        + "\"file:///tmp/b.py\":["
        + "{\"range\":{\"start\":{\"line\":5,\"character\":8},"
        + "\"end\":{\"line\":5,\"character\":11}},\"newText\":\"baz\"}"
        + "]}}"
    ))
    var groups = _parse_workspace_edit_changes(v)
    assert_equal(len(groups), 2)
    # Locate each file's group (map order isn't guaranteed).
    var a_idx = -1
    var b_idx = -1
    for i in range(len(groups)):
        if groups[i].uri == String("file:///tmp/a.py"):
            a_idx = i
        if groups[i].uri == String("file:///tmp/b.py"):
            b_idx = i
    assert_true(a_idx >= 0)
    assert_true(b_idx >= 0)
    assert_equal(len(groups[a_idx].edits), 2)
    assert_equal(len(groups[b_idx].edits), 1)
    assert_equal(groups[a_idx].edits[0].start_char, 4)
    assert_equal(groups[a_idx].edits[0].new_text, String("baz"))


def test_lsp_rename_edits_apply_to_buffer() raises:
    """End-to-end on the application side: edits parsed from a rename
    ``WorkspaceEdit`` flow through ``Editor.apply_code_action_edits`` and
    rename every occurrence in the buffer. Uses the same URI round-trip
    the host relies on (``_path_to_uri(editor.file_path)`` must match the
    edit group's URI) so this also guards that contract."""
    var ed = Editor(String("foo = 1\nprint(foo)\nfoo += foo"))
    ed.file_path = String("/tmp/a.py")
    var uri = _path_to_uri(String("/tmp/a.py"))
    # Replace each "foo" (len 3) with "bar". Order doesn't matter —
    # apply_code_action_edits sorts descending internally.
    var edits = List[TextEditEntry]()
    edits.append(TextEditEntry(0, 0, 0, 3, String("bar")))
    edits.append(TextEditEntry(1, 6, 1, 9, String("bar")))
    edits.append(TextEditEntry(2, 0, 2, 3, String("bar")))
    edits.append(TextEditEntry(2, 7, 2, 10, String("bar")))
    var fe = List[CodeActionFileEdit]()
    fe.append(CodeActionFileEdit(uri, edits^))
    var ok = ed.apply_code_action_edits(fe^)
    assert_true(ok)
    assert_equal(ed.buffer.line(0), String("bar = 1"))
    assert_equal(ed.buffer.line(1), String("print(bar)"))
    assert_equal(ed.buffer.line(2), String("bar += bar"))


def test_lsp_parse_text_edits_and_apply_formats_buffer() raises:
    """``_parse_text_edits`` reads a bare ``TextEdit[]`` (the formatting
    response shape) and ``Editor.apply_text_edits`` applies it — sorted
    descending so multiple edits don't shift each other. Models a tiny
    reformat: collapse double spaces and add a trailing newline split."""
    var v = parse_json(String(
        "["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":3},"
        + "\"end\":{\"line\":0,\"character\":5}},\"newText\":\" \"},"
        + "{\"range\":{\"start\":{\"line\":1,\"character\":0},"
        + "\"end\":{\"line\":1,\"character\":2}},\"newText\":\"\"}"
        + "]"
    ))
    var edits = _parse_text_edits(v)
    assert_equal(len(edits), 2)
    assert_equal(edits[0].start_char, 3)
    assert_equal(edits[0].new_text, String(" "))
    # "foo    x" → collapse the 2-space span [3,5) to one; "  bar" → strip
    # leading 2 spaces.
    var ed = Editor(String("foo    x\n  bar"))
    var ok = ed.apply_text_edits(edits^)
    assert_true(ok)
    assert_equal(ed.buffer.line(0), String("foo   x"))
    assert_equal(ed.buffer.line(1), String("bar"))


def test_lsp_parse_document_colors() raises:
    """``documentColor`` → swatch highlights: the color literal's range
    recolored with a truecolor bg matching the literal's color. Components
    arrive as 0..1 floats (raw-text) or ints."""
    var v = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":3,\"character\":10},"
        + "\"end\":{\"line\":3,\"character\":17}},"
        + "\"color\":{\"red\":1,\"green\":0,\"blue\":0,\"alpha\":1}},"
        + "{\"range\":{\"start\":{\"line\":4,\"character\":2},"
        + "\"end\":{\"line\":4,\"character\":9}},"
        + "\"color\":{\"red\":0.0,\"green\":0.5,\"blue\":1.0,\"alpha\":1.0}}]"
    ))
    var sw = _parse_document_colors(v)
    assert_equal(len(sw), 2)
    assert_equal(sw[0].row, 3)
    assert_equal(sw[0].col_start, 10)
    assert_equal(sw[0].col_end, 17)
    # Pure red → bg_rgb 0xFF0000.
    assert_equal(sw[0].attr.bg_rgb, UInt32(0xFF0000))
    # 0.0 / 0.5 / 1.0 → ~0x0080FF.
    var rgb2 = sw[1].attr.bg_rgb
    assert_equal(Int((rgb2 >> 16) & 0xFF), 0)
    assert_true(Int((rgb2 >> 8) & 0xFF) >= 127)
    assert_equal(Int(rgb2 & 0xFF), 255)
    assert_equal(len(_parse_document_colors(parse_json(String("null")))), 0)
    var ed = Editor(String("x\ny\n\n  #ff0000\n  blue42"))
    ed.set_color_swatches(sw^)
    assert_equal(len(ed.color_highlights), 2)


def test_lsp_parse_hierarchy_result() raises:
    """The follow-up parser handles both ``incomingCalls`` (each entry has
    a ``from`` item) and bare item arrays (``supertypes``), mapping each to
    a jump location via uri + selectionRange (fallback range)."""
    # incomingCalls shape.
    var calls = parse_json(String(
        "[{\"from\":{\"name\":\"caller\",\"uri\":\"file:///a.py\","
        + "\"selectionRange\":{\"start\":{\"line\":9,\"character\":4},"
        + "\"end\":{\"line\":9,\"character\":10}}},\"fromRanges\":[]}]"
    ))
    var c = _parse_hierarchy_result(calls)
    assert_equal(len(c), 1)
    assert_equal(c[0].path, String("/a.py"))
    assert_equal(c[0].line, 9)
    assert_equal(c[0].character, 4)
    # supertypes shape (bare items, range fallback).
    var supers = parse_json(String(
        "[{\"name\":\"Base\",\"uri\":\"file:///b.py\","
        + "\"range\":{\"start\":{\"line\":2,\"character\":0},"
        + "\"end\":{\"line\":5,\"character\":0}}}]"
    ))
    var s = _parse_hierarchy_result(supers)
    assert_equal(len(s), 1)
    assert_equal(s[0].path, String("/b.py"))
    assert_equal(s[0].line, 2)
    # outgoingCalls shape (each entry wraps a ``to`` item).
    var outg = parse_json(String(
        "[{\"to\":{\"name\":\"callee\",\"uri\":\"file:///c.py\","
        + "\"selectionRange\":{\"start\":{\"line\":3,\"character\":2},"
        + "\"end\":{\"line\":3,\"character\":8}}},\"fromRanges\":[]}]"
    ))
    var o = _parse_hierarchy_result(outg)
    assert_equal(len(o), 1)
    assert_equal(o[0].path, String("/c.py"))
    assert_equal(o[0].line, 3)
    assert_equal(o[0].character, 2)
    assert_equal(len(_parse_hierarchy_result(parse_json(String("null")))), 0)


def test_lsp_parse_selection_ranges_walks_parent_chain() raises:
    """``selectionRange`` returns one entry per position, each a linked
    list via ``parent``; the parser flattens innermost→outermost. It also
    backs smart-select grow when cached on the editor."""
    var v = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":0,\"character\":4},"
        + "\"end\":{\"line\":0,\"character\":7}},"
        + "\"parent\":{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":0,\"character\":12}},"
        + "\"parent\":{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":3,\"character\":1}}}}}]"
    ))
    var ranges = _parse_selection_ranges(v)
    assert_equal(len(ranges), 3)
    assert_equal(ranges[0].start_char, 4)
    assert_equal(ranges[0].end_char, 7)
    assert_equal(ranges[1].end_char, 12)
    assert_equal(ranges[2].end_line, 3)
    assert_equal(len(_parse_selection_ranges(parse_json(String("null")))), 0)
    # Cached on the editor, a cursor inside the innermost range grows to
    # it via the LSP-first branch in _smart_compute_expansion.
    var ed = Editor(String("foo bar baz\nq\nw\ne"))
    ed.set_selection_ranges(ranges^)
    ed.move_to(0, 5, False)  # cursor inside [4,7)
    var grown = ed._smart_compute_expansion(0, 5, 0, 5)
    assert_equal(grown[1], 4)
    assert_equal(grown[3], 7)


def test_lsp_parse_inlay_hints() raises:
    """``inlayHint`` entries carry a ``position`` + ``label`` (string or
    label-part array); the parser flattens to (row, text) carriers."""
    var v = parse_json(String(
        "["
        + "{\"position\":{\"line\":2,\"character\":7},\"label\":\": int\"},"
        + "{\"position\":{\"line\":5,\"character\":0},\"label\":["
        + "{\"value\":\"name\"},{\"value\":\": \"},{\"value\":\"str\"}]}"
        + "]"
    ))
    var hints = _parse_inlay_hints(v)
    assert_equal(len(hints), 2)
    assert_equal(hints[0].start_line, 2)
    assert_equal(hints[0].new_text, String(": int"))
    assert_equal(hints[1].start_line, 5)
    assert_equal(hints[1].new_text, String("name: str"))
    var ed = Editor(String("a\nb\nc\nd\ne\nf"))
    ed.set_inlay_hints(hints^)
    assert_equal(len(ed.inlay_notes), 2)


def test_lsp_parse_code_lens() raises:
    """``codeLens`` keeps only lenses with a resolved ``command.title``;
    unresolved (command-less) lenses are skipped."""
    var v = parse_json(String(
        "["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":0,\"character\":0}},"
        + "\"command\":{\"title\":\"3 references\",\"command\":\"x\"}},"
        + "{\"range\":{\"start\":{\"line\":4,\"character\":0},"
        + "\"end\":{\"line\":4,\"character\":0}}}"
        + "]"
    ))
    var lenses = _parse_code_lens(v)
    assert_equal(len(lenses), 1)
    assert_equal(lenses[0].start_line, 0)
    assert_true(_contains(lenses[0].new_text, String("3 references")))
    var ed = Editor(String("x\ny\nz"))
    ed.set_code_lens(lenses^)
    assert_equal(len(ed.codelens_notes), 1)


def test_lsp_parse_signature_help() raises:
    """``signatureHelp`` renders the active signature's label, marking the
    active parameter when its label is a string. ``null`` / empty → ""."""
    var v = parse_json(String(
        "{\"signatures\":["
        + "{\"label\":\"foo(a: int, b: str)\",\"parameters\":["
        + "{\"label\":\"a: int\"},{\"label\":\"b: str\"}]},"
        + "{\"label\":\"bar()\"}"
        + "],\"activeSignature\":0,\"activeParameter\":1}"
    ))
    var s = _parse_signature_help(v)
    assert_true(_contains(s, String("foo(a: int, b: str)")))
    assert_true(_contains(s, String("b: str")))
    # Second signature, no params → just the label.
    var v2 = parse_json(String(
        "{\"signatures\":[{\"label\":\"x()\"},{\"label\":\"y(z)\"}],"
        + "\"activeSignature\":1}"
    ))
    assert_equal(_parse_signature_help(v2), String("y(z)"))
    assert_equal(_parse_signature_help(parse_json(String("null"))), String(""))
    assert_equal(
        _parse_signature_help(parse_json(String("{\"signatures\":[]}"))),
        String(""),
    )


def test_lsp_parse_document_highlights() raises:
    """``documentHighlight`` returns ``{range, kind?}[]``; the parser keeps
    the ranges (as carriers) and ignores ``kind``. ``null`` → empty."""
    var v = parse_json(String(
        "["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":4},"
        + "\"end\":{\"line\":0,\"character\":7}},\"kind\":1},"
        + "{\"range\":{\"start\":{\"line\":3,\"character\":0},"
        + "\"end\":{\"line\":3,\"character\":3}},\"kind\":2}"
        + "]"
    ))
    var occ = _parse_document_highlights(v)
    assert_equal(len(occ), 2)
    assert_equal(occ[0].start_line, 0)
    assert_equal(occ[0].start_char, 4)
    assert_equal(occ[0].end_char, 7)
    assert_equal(occ[1].start_line, 3)
    assert_equal(len(_parse_document_highlights(parse_json(String("null")))), 0)
    # Editor accepts the ranges without disturbing buffer content.
    var ed = Editor(String("foo\nbar\nbaz\nfoo"))
    ed.set_document_highlights(occ^)
    assert_equal(len(ed.occurrence_ranges), 2)
    ed.clear_document_highlights()
    assert_equal(len(ed.occurrence_ranges), 0)


def test_lsp_parse_text_edits_null_is_empty() raises:
    """A ``null`` formatting response (server had nothing to change) parses
    to an empty edit list rather than raising."""
    assert_equal(len(_parse_text_edits(parse_json(String("null")))), 0)


def test_lsp_server_progress_and_show_message() raises:
    """``$/progress`` begin/report build a one-line note and ``end`` clears
    it; ``window/showMessage`` parks the message. Both drain via the
    ``take_*`` accessors."""
    var mgr = LspManager()
    mgr._on_progress(parse_json(String(
        "{\"token\":\"t\",\"value\":{\"kind\":\"begin\","
        + "\"title\":\"indexing\",\"percentage\":42}}"
    )))
    assert_true(mgr.has_pending_progress())
    var note = mgr.take_progress_note()
    assert_true(_contains(note, String("indexing")))
    assert_true(_contains(note, String("42%")))
    assert_true(not mgr.has_pending_progress())
    # ``end`` clears to empty (still flagged so the host hides the note).
    mgr._on_progress(parse_json(String(
        "{\"token\":\"t\",\"value\":{\"kind\":\"end\"}}"
    )))
    assert_true(mgr.has_pending_progress())
    assert_equal(mgr.take_progress_note(), String(""))
    mgr._on_show_message(parse_json(String(
        "{\"type\":3,\"message\":\"server started\"}"
    )))
    assert_true(mgr.has_pending_server_message())
    assert_true(_contains(mgr.take_server_message(), String("server started")))


def test_lsp_server_supports_reads_capabilities() raises:
    """``server_supports`` gates optional feature requests off the
    initialize ``capabilities`` object: a boolean true, or any
    registration-options object, counts as supported; absent or false does
    not. ``server_supports_prepare_rename`` reads the nested
    ``renameProvider.prepareProvider`` flag."""
    var mgr = LspManager()
    # No capabilities yet → everything reports unsupported.
    assert_true(not mgr.server_supports(String("implementationProvider")))
    assert_true(not mgr.server_supports_prepare_rename())
    var caps = parse_json(String(
        "{"
        + "\"implementationProvider\":true,"
        + "\"typeDefinitionProvider\":{},"
        + "\"declarationProvider\":false,"
        + "\"renameProvider\":{\"prepareProvider\":true}"
        + "}"
    ))
    mgr._capabilities = Optional[JsonValue](caps^)
    assert_true(mgr.server_supports(String("implementationProvider")))
    assert_true(mgr.server_supports(String("typeDefinitionProvider")))
    assert_true(not mgr.server_supports(String("declarationProvider")))
    assert_true(not mgr.server_supports(String("hoverProvider")))
    assert_true(mgr.server_supports_prepare_rename())
    # Plain renameProvider:true means rename works but prepare does not.
    var caps2 = parse_json(String("{\"renameProvider\":true}"))
    mgr._capabilities = Optional[JsonValue](caps2^)
    assert_true(not mgr.server_supports_prepare_rename())


def test_lsp_dynamic_capability_registration() raises:
    """``client/registerCapability`` merges into the cached capabilities so
    ``server_supports`` reports dynamically-registered providers (the way
    rust-analyzer enables most of its features); ``unregisterCapability``
    flips them back off."""
    var mgr = LspManager()
    assert_true(not mgr.server_supports(String("foldingRangeProvider")))
    # Register with an options object → stored verbatim, reports supported.
    mgr._apply_capability_registration(
        String("textDocument/foldingRange"), json_object(),
    )
    assert_true(mgr.server_supports(String("foldingRangeProvider")))
    # Register a notification-only method (no provider field): no
    # capability key, but it flips the watched-files interest flag so the
    # host's on-save hook starts pushing didChangeWatchedFiles.
    assert_true(not mgr._watches_files)
    mgr._apply_capability_registration(
        String("workspace/didChangeWatchedFiles"), json_object(),
    )
    assert_true(mgr._watches_files)
    mgr._remove_capability_registration(
        String("workspace/didChangeWatchedFiles"),
    )
    assert_true(not mgr._watches_files)
    # Unregister flips the capability back to unsupported.
    mgr._remove_capability_registration(String("textDocument/foldingRange"))
    assert_true(not mgr.server_supports(String("foldingRangeProvider")))


def test_lsp_pull_diagnostics_storage() raises:
    """Pull diagnostics gate on ``diagnosticProvider`` and land in the same
    bucket the push path uses, so the host consumes them identically.
    ``has_pulled`` lets the host fire the initial pull exactly once."""
    var mgr = LspManager()
    assert_true(not mgr.supports_pull_diagnostics())
    var caps = parse_json(String(
        "{\"diagnosticProvider\":{\"interFileDependencies\":true}}"
    ))
    mgr._capabilities = Optional[JsonValue](caps^)
    assert_true(mgr.supports_pull_diagnostics())
    assert_true(not mgr.has_pulled(String("/x.py")))
    # A pull report's ``items`` parse + store into the shared bucket.
    var items = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":1,\"character\":0},"
        + "\"end\":{\"line\":1,\"character\":4}},"
        + "\"severity\":1,\"message\":\"oops\"}]"
    ))
    var diags = _parse_diagnostics_array(items)
    mgr._store_diagnostics(String("/x.py"), diags^)
    assert_true(mgr.has_unconsumed_diagnostics_for(String("/x.py")))
    var got = mgr.take_diagnostics_for(String("/x.py"))
    assert_equal(len(got), 1)
    # Consumed flag flips so the host doesn't re-apply every frame.
    assert_true(not mgr.has_unconsumed_diagnostics_for(String("/x.py")))


def test_lsp_pull_diagnostics_multi_inflight() raises:
    """Several pull requests can be in flight at once — on session restore
    the host opens N buffers and fires one pull per file in a single frame.
    Each is tracked by (id, path) so every response matches its own request;
    a single slot would strand all but the last (their "analysing edits…"
    spinners stuck until the 8 s inflight timeout, diagnostics dropped)."""
    var mgr = LspManager()
    var caps = parse_json(String("{\"diagnosticProvider\":{}}"))
    mgr._capabilities = Optional[JsonValue](caps^)
    mgr.state = _STATE_READY
    assert_true(mgr.request_pull_diagnostics(String("/a.py")))
    assert_true(mgr.request_pull_diagnostics(String("/b.py")))
    assert_true(mgr.request_pull_diagnostics(String("/c.py")))
    # All three outstanding, with distinct ids (not collapsed to one slot).
    assert_equal(len(mgr._pull_diag_ids), 3)
    assert_equal(len(mgr._pull_diag_paths), 3)
    assert_equal(mgr._pull_diag_paths[0], String("/a.py"))
    assert_equal(mgr._pull_diag_paths[2], String("/c.py"))
    assert_true(mgr._pull_diag_ids[0] != mgr._pull_diag_ids[2])
    # Re-pulling an already-inflight path supersedes the old entry rather
    # than duplicating it (edit-driven pull replaces the initial one).
    assert_true(mgr.request_pull_diagnostics(String("/a.py")))
    assert_equal(len(mgr._pull_diag_paths), 3)
    # /a.py moved to the tail with a fresh id; /b.py and /c.py stay.
    assert_equal(mgr._pull_diag_paths[2], String("/a.py"))


def test_lsp_server_supports_will_save() raises:
    """The willSave / willSaveWaitUntil capability readers consult the
    object form of textDocumentSync; the int form (or absent) is off."""
    var mgr = LspManager()
    assert_true(not mgr.server_supports_will_save())
    assert_true(not mgr.server_supports_will_save_wait_until())
    var caps = parse_json(String(
        "{\"textDocumentSync\":{\"willSave\":true,"
        + "\"willSaveWaitUntil\":true}}"
    ))
    mgr._capabilities = Optional[JsonValue](caps^)
    assert_true(mgr.server_supports_will_save())
    assert_true(mgr.server_supports_will_save_wait_until())
    # Plain int sync kind → neither flag.
    var caps2 = parse_json(String("{\"textDocumentSync\":2}"))
    mgr._capabilities = Optional[JsonValue](caps2^)
    assert_true(not mgr.server_supports_will_save())
    assert_true(not mgr.server_supports_will_save_wait_until())


def test_lsp_log_message_capture() raises:
    """The window/logMessage handler lands lines in the rolling log
    capture, prefixed by severity (E/W/I/L), one per message."""
    var mgr = LspManager()
    assert_equal(len(mgr.captured_log().as_bytes()), 0)
    mgr._on_log_message(parse_json(String("{\"type\":1,\"message\":\"boom\"}")))
    mgr._on_log_message(parse_json(String("{\"type\":3,\"message\":\"fyi\"}")))
    assert_equal(mgr.captured_log(), String("[E] boom\n[I] fyi\n"))


def test_lsp_message_request_accessors() raises:
    """The parked showMessageRequest surface (message + action titles) is
    readable so the host can drive the modal; actions are returned by copy."""
    var mgr = LspManager()
    assert_true(not mgr.has_message_request())
    mgr._msgreq_pending = True
    mgr._msgreq_message = String("Reload window?")
    var acts = List[String]()
    acts.append(String("Reload"))
    acts.append(String("Later"))
    mgr._msgreq_actions = acts^
    assert_true(mgr.has_message_request())
    assert_equal(mgr.message_request_text(), String("Reload window?"))
    assert_equal(len(mgr.message_request_actions()), 2)
    assert_equal(mgr.message_request_actions()[0], String("Reload"))


def test_lsp_show_document_accessors() raises:
    """The parked showDocument request exposes the target; a file:// uri
    converts to a filesystem path, external uris are flagged."""
    var mgr = LspManager()
    assert_true(not mgr.has_show_document())
    mgr._show_doc_pending = True
    mgr._show_doc_uri = String("file:///tmp/x.py")
    mgr._show_doc_external = False
    mgr._show_doc_line = 4
    assert_true(mgr.has_show_document())
    assert_equal(mgr.show_document_path(), String("/tmp/x.py"))
    assert_equal(mgr.show_document_line(), 4)
    assert_true(not mgr.show_document_external())
    mgr.clear_show_document()
    assert_true(not mgr.has_show_document())


def test_lsp_server_wants_did_create() raises:
    """The didCreateFiles gate reads workspace.fileOperations.didCreate."""
    var mgr = LspManager()
    assert_true(not mgr.server_wants_did_create())
    var caps = parse_json(String(
        "{\"workspace\":{\"fileOperations\":{\"didCreate\":{\"filters\":[]}}}}"
    ))
    mgr._capabilities = Optional[JsonValue](caps^)
    assert_true(mgr.server_wants_did_create())
    var caps2 = parse_json(String("{\"workspace\":{\"fileOperations\":{}}}"))
    mgr._capabilities = Optional[JsonValue](caps2^)
    assert_true(not mgr.server_wants_did_create())


def test_lsp_codelens_resolve_collects_unresolved() raises:
    """Lenses without a title-bearing command are collected for the
    codeLens/resolve round-trip; resolved ones parse directly."""
    var lenses = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":2,\"character\":0},"
        + "\"end\":{\"line\":2,\"character\":1}},\"data\":[1]},"
        + "{\"range\":{\"start\":{\"line\":5,\"character\":0},"
        + "\"end\":{\"line\":5,\"character\":1}},"
        + "\"command\":{\"title\":\"3 refs\",\"command\":\"x\"}}]"
    ))
    var unresolved = _collect_unresolved_lenses(lenses)
    assert_equal(len(unresolved), 1)
    assert_equal(_codelens_row_of(unresolved[0]), 2)
    # _parse_code_lens keeps only the already-titled lens.
    assert_equal(len(_parse_code_lens(lenses)), 1)
    var single = parse_json(String("{\"command\":{\"title\":\"hi\"}}"))
    assert_equal(_codelens_title_of(single), String("hi"))


def test_lsp_on_type_trigger_chars() raises:
    """The trigger-char reader concatenates firstTriggerCharacter +
    moreTriggerCharacter from documentOnTypeFormattingProvider."""
    var mgr = LspManager()
    assert_equal(mgr.on_type_trigger_chars(), String(""))
    var caps = parse_json(String(
        "{\"documentOnTypeFormattingProvider\":{"
        + "\"firstTriggerCharacter\":\"}\","
        + "\"moreTriggerCharacter\":[\";\",\"\\n\"]}}"
    ))
    mgr._capabilities = Optional[JsonValue](caps^)
    assert_equal(mgr.on_type_trigger_chars(), String("};\n"))


def test_lsp_color_unit_text() raises:
    """Color components format as 0..1 decimal text for the
    colorPresentation request (0→0.0, 255→1.0, mid→fractional)."""
    assert_equal(_unit_text(0), String("0.0"))
    assert_equal(_unit_text(255), String("1.0"))
    var mid = _unit_text(128)
    # Just assert it's a fractional value between 0 and 1 (starts "0.").
    assert_equal(mid.as_bytes()[0], UInt8(ord("0")))
    assert_equal(mid.as_bytes()[1], UInt8(ord(".")))


def test_lsp_parse_inline_value_exprs() raises:
    """The variable-lookup / evaluable inline-value variants become
    (row, expr) carriers for DAP evaluation; text variants are skipped."""
    var v = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":4,\"character\":2},"
        + "\"end\":{\"line\":4,\"character\":6}},\"text\":\"x = 41\"},"
        + "{\"range\":{\"start\":{\"line\":5,\"character\":0},"
        + "\"end\":{\"line\":5,\"character\":3}},\"variableName\":\"y\"},"
        + "{\"range\":{\"start\":{\"line\":6,\"character\":0},"
        + "\"end\":{\"line\":6,\"character\":4}},\"expression\":\"a+b\"}]"
    ))
    var ex = _parse_inline_value_exprs(v)
    assert_equal(len(ex), 2)        # text variant skipped
    assert_equal(ex[0].start_line, 5)
    assert_equal(ex[0].new_text, String("y"))
    assert_equal(ex[1].start_line, 6)
    assert_equal(ex[1].new_text, String("a+b"))


def test_lsp_parse_folding_ranges() raises:
    """FoldingRange[] parse into start..end range carriers; single-line
    (endLine <= startLine) regions are dropped."""
    var v = parse_json(String(
        "[{\"startLine\":2,\"endLine\":8,\"kind\":\"region\"},"
        + "{\"startLine\":10,\"endLine\":10},"
        + "{\"startLine\":12,\"endLine\":15}]"
    ))
    var fr = _parse_folding_ranges(v)
    assert_equal(len(fr), 2)
    assert_equal(fr[0].start_line, 2)
    assert_equal(fr[0].end_line, 8)
    assert_equal(fr[1].start_line, 12)
    assert_equal(len(_parse_folding_ranges(parse_json(String("null")))), 0)


def test_lsp_parse_inline_values() raises:
    """InlineValueText entries become (row, text) carriers; the lookup /
    evaluable variants (no ``text`` field) are skipped."""
    var v = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":4,\"character\":2},"
        + "\"end\":{\"line\":4,\"character\":6}},\"text\":\"x = 41\"},"
        + "{\"range\":{\"start\":{\"line\":5,\"character\":0},"
        + "\"end\":{\"line\":5,\"character\":3}},\"variableName\":\"y\"}]"
    ))
    var iv = _parse_inline_values(v)
    assert_equal(len(iv), 1)
    assert_equal(iv[0].start_line, 4)
    assert_equal(iv[0].new_text, String("x = 41"))
    assert_equal(len(_parse_inline_values(parse_json(String("null")))), 0)


def test_lsp_parse_linked_ranges() raises:
    """LinkedEditingRanges parse into range carriers (one per range)."""
    var v = parse_json(String(
        "{\"ranges\":[{\"start\":{\"line\":1,\"character\":1},"
        + "\"end\":{\"line\":1,\"character\":4}},"
        + "{\"start\":{\"line\":3,\"character\":2},"
        + "\"end\":{\"line\":3,\"character\":5}}],\"wordPattern\":\"x\"}"
    ))
    var r = _parse_linked_ranges(v)
    assert_equal(len(r), 2)
    assert_equal(r[0].start_line, 1)
    assert_equal(r[0].start_char, 1)
    assert_equal(r[0].end_char, 4)
    assert_equal(r[1].start_line, 3)
    assert_equal(len(_parse_linked_ranges(parse_json(String("null")))), 0)


def test_lsp_parse_inline_completion() raises:
    """The first inline-completion item's insertText is extracted from
    both the list form ({items:[...]}) and a bare item array, string or
    {value} insertText."""
    var lst = parse_json(String(
        "{\"items\":[{\"insertText\":\"foo()\"},{\"insertText\":\"bar\"}]}"
    ))
    assert_equal(_parse_inline_completion(lst), String("foo()"))
    var arr = parse_json(String("[{\"insertText\":{\"value\":\"baz\"}}]"))
    assert_equal(_parse_inline_completion(arr), String("baz"))
    assert_equal(
        _parse_inline_completion(parse_json(String("{\"items\":[]}"))),
        String(""),
    )


def test_lsp_parse_monikers() raises:
    """Moniker[] joins into a scheme:identifier status string."""
    var v = parse_json(String(
        "[{\"scheme\":\"tsc\",\"identifier\":\"lib/foo\",\"unique\":\"scheme\"},"
        + "{\"identifier\":\"bare\"}]"
    ))
    assert_equal(_parse_monikers(v), String("tsc:lib/foo, bare"))
    assert_equal(_parse_monikers(parse_json(String("null"))), String(""))


def test_lsp_parse_document_links() raises:
    """DocumentLink[] with inline targets become range carriers
    (new_text = target); targetless links are skipped."""
    var v = parse_json(String(
        "[{\"range\":{\"start\":{\"line\":1,\"character\":4},"
        + "\"end\":{\"line\":1,\"character\":20}},"
        + "\"target\":\"https://example.com\"},"
        + "{\"range\":{\"start\":{\"line\":2,\"character\":0},"
        + "\"end\":{\"line\":2,\"character\":5}}}]"
    ))
    var links = _parse_document_links(v)
    assert_equal(len(links), 1)
    assert_equal(links[0].start_line, 1)
    assert_equal(links[0].start_char, 4)
    assert_equal(links[0].end_char, 20)
    assert_equal(links[0].new_text, String("https://example.com"))
    assert_equal(len(_parse_document_links(parse_json(String("null")))), 0)


def test_lsp_parse_prepare_rename_placeholder() raises:
    """The prepareRename object result may carry a ``placeholder`` string,
    be a bare ``Range`` (no placeholder), or ``{defaultBehavior:true}``.
    Only the explicit placeholder is extracted; the others return empty so
    the host seeds the prompt from the word under the cursor."""
    var with_ph = parse_json(String(
        "{\"range\":{\"start\":{\"line\":1,\"character\":2},"
        + "\"end\":{\"line\":1,\"character\":5}},\"placeholder\":\"myvar\"}"
    ))
    assert_equal(_parse_prepare_rename_placeholder(with_ph), String("myvar"))
    var bare_range = parse_json(String(
        "{\"start\":{\"line\":1,\"character\":2},"
        + "\"end\":{\"line\":1,\"character\":5}}"
    ))
    assert_equal(_parse_prepare_rename_placeholder(bare_range), String(""))
    var default_behavior = parse_json(String("{\"defaultBehavior\":true}"))
    assert_equal(
        _parse_prepare_rename_placeholder(default_behavior), String(""),
    )


def test_lsp_initialize_params_advertise_code_action_literal_support() raises:
    """The initialize payload must declare ``codeActionLiteralSupport``
    so servers like ty / pyright return ``CodeAction`` literals (with
    inline ``WorkspaceEdit``) rather than opaque ``Command`` entries.
    Without this declaration, ty 0.0.34 returns no actionable fixes."""
    var p = lsp_initialize_params(
        String("file:///tmp/proj"), String("proj"),
    )
    var caps = p.object_get(String("capabilities")).value().copy()
    var text_doc = caps.object_get(String("textDocument")).value().copy()
    var ca = text_doc.object_get(String("codeAction")).value().copy()
    assert_true(ca.object_has(String("codeActionLiteralSupport")))
    var literal = ca.object_get(
        String("codeActionLiteralSupport"),
    ).value().copy()
    var kind = literal.object_get(String("codeActionKind")).value().copy()
    var values = kind.object_get(String("valueSet")).value().copy()
    assert_true(values.is_array())
    var found_quickfix = False
    for i in range(values.array_len()):
        if values.array_at(i).as_str() == String("quickfix"):
            found_quickfix = True
            break
    assert_true(found_quickfix)


def test_lsp_parse_completion_result_array_shape() raises:
    """A bare ``CompletionItem[]`` array (one of the two shapes the
    LSP spec allows) parses to one item per entry. Each item carries
    its label, kind, and detail; ``insert_text`` defaults to the
    label when no explicit ``insertText`` / ``textEdit`` is given.
    With no ``sortText`` on either entry the items sort by label,
    so ``bar`` lands first even though it was second on the wire."""
    var v = parse_json(String(
        "["
        + "{\"label\":\"foo\",\"kind\":3,\"detail\":\"() -> int\"},"
        + "{\"label\":\"bar\",\"kind\":6,\"insertText\":\"bar_\"}"
        + "]"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 2)
    assert_equal(items[0].label, String("bar"))
    assert_equal(items[0].insert_text, String("bar_"))
    assert_equal(items[0].kind, 6)
    assert_equal(items[1].label, String("foo"))
    assert_equal(items[1].insert_text, String("foo"))
    assert_equal(items[1].kind, 3)
    assert_equal(items[1].detail, String("() -> int"))


def test_lsp_parse_completion_result_list_shape() raises:
    """The CompletionList shape ``{isIncomplete,items:[...]}`` parses
    the same as a bare array. Servers like pyright return this form."""
    var v = parse_json(String(
        "{\"isIncomplete\":false,\"items\":["
        + "{\"label\":\"x\",\"kind\":6}"
        + "]}"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 1)
    assert_equal(items[0].label, String("x"))


def test_lsp_parse_completion_result_honors_sort_text() raises:
    """``sortText`` overrides the wire order in the parsed list. The
    server here flags ``zzz`` as the preferred match by giving it a
    leading ``0`` while ``aaa`` gets ``2`` — sorting puts ``zzz`` first
    even though it would otherwise sort last. An entry with no
    ``sortText`` falls back to its label, so ``mmm`` lands last in the
    natural lexicographic slot (``m`` > digits in ASCII)."""
    var v = parse_json(String(
        "["
        + "{\"label\":\"aaa\",\"sortText\":\"2-aaa\"},"
        + "{\"label\":\"mmm\"},"
        + "{\"label\":\"zzz\",\"sortText\":\"0-zzz\"}"
        + "]"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 3)
    assert_equal(items[0].label, String("zzz"))
    assert_equal(items[0].sort_text, String("0-zzz"))
    assert_equal(items[1].label, String("aaa"))
    assert_equal(items[1].sort_text, String("2-aaa"))
    assert_equal(items[2].label, String("mmm"))
    assert_equal(items[2].sort_text, String("mmm"))


def test_lsp_parse_completion_result_snippet_falls_back_to_label() raises:
    """``insertTextFormat == 2`` (snippet) means the body has
    placeholders we don't render. Drop the snippet body and use the
    label as the inserted text — otherwise ``${1:arg}`` markers would
    land in the buffer verbatim."""
    var v = parse_json(String(
        "[{\"label\":\"print\",\"kind\":3,"
        + "\"insertText\":\"print(${1:value})\","
        + "\"insertTextFormat\":2}]"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 1)
    assert_equal(items[0].label, String("print"))
    assert_equal(items[0].insert_text, String("print"))


def test_lsp_parse_hover_result_string_contents() raises:
    """The legacy plain-string form (``{contents: "..."}``) parses to
    the string verbatim."""
    var v = parse_json(String(
        "{\"contents\":\"int — a built-in scalar\"}"
    ))
    var text = _parse_hover_result(v)
    assert_equal(text, String("int — a built-in scalar"))


def test_lsp_parse_hover_result_markup_content() raises:
    """``MarkupContent`` (``{kind, value}``) — the modern shape pyright /
    ty / rust-analyzer use — returns the ``value`` field."""
    var v = parse_json(String(
        "{\"contents\":{\"kind\":\"markdown\",\"value\":\"```py\\nfoo: int\\n```\"}}"
    ))
    var text = _parse_hover_result(v)
    assert_equal(text, String("```py\nfoo: int\n```"))


def test_lsp_parse_hover_result_array_joins_with_newlines() raises:
    """``MarkedString[]`` joins each entry with a newline so a hover
    answer split across several blocks reads as one popup body. Mix of
    plain string and ``{language, value}`` is allowed by the spec."""
    var v = parse_json(String(
        "{\"contents\":["
        + "{\"language\":\"python\",\"value\":\"def foo() -> int\"},"
        + "\"Return the answer.\""
        + "]}"
    ))
    var text = _parse_hover_result(v)
    assert_equal(text, String("def foo() -> int\nReturn the answer."))


def test_lsp_parse_hover_result_empty_when_no_contents() raises:
    """Servers reply with ``null`` (or ``{contents: null}``) for symbols
    they don't recognize — surface as the empty string so the host
    treats it as 'nothing to show' rather than popping a blank box."""
    var v_null = parse_json(String("null"))
    assert_equal(_parse_hover_result(v_null), String(""))
    var v_empty = parse_json(String("{\"contents\":null}"))
    assert_equal(_parse_hover_result(v_empty), String(""))


def test_lsp_parse_references_result_list_of_locations() raises:
    """``textDocument/references`` always returns ``Location[]`` (or
    null). Each entry has uri+range; parse one ``DefinitionResolved``
    per entry, anchored at the range start. Malformed entries (missing
    uri or range) are skipped, not crashed on."""
    var v = parse_json(String(
        "["
        + "{\"uri\":\"file:///a.py\",\"range\":{\"start\":{\"line\":3,\"character\":4},\"end\":{\"line\":3,\"character\":7}}},"
        + "{\"uri\":\"file:///b.py\",\"range\":{\"start\":{\"line\":10,\"character\":0},\"end\":{\"line\":10,\"character\":3}}},"
        + "{\"uri\":\"file:///c.py\"}"  # missing range — dropped
        + "]"
    ))
    var refs = _parse_references_result(v)
    assert_equal(len(refs), 2)
    assert_equal(refs[0].path, String("/a.py"))
    assert_equal(refs[0].line, 3)
    assert_equal(refs[0].character, 4)
    assert_equal(refs[1].path, String("/b.py"))
    assert_equal(refs[1].line, 10)
    assert_equal(refs[1].character, 0)


def test_lsp_parse_references_result_null_is_empty() raises:
    """``null`` (the spec-allowed "no references" form) parses to an
    empty list — same as an empty array."""
    var v_null = parse_json(String("null"))
    assert_equal(len(_parse_references_result(v_null)), 0)
    var v_empty = parse_json(String("[]"))
    assert_equal(len(_parse_references_result(v_empty)), 0)


def test_lsp_parse_completion_result_extracts_additional_text_edits() raises:
    """``additionalTextEdits`` survives parsing as a list of
    ``TextEditEntry``. Auto-import responses (the canonical user)
    look like this — primary insert is the bare name, plus one
    aux edit at line 0 col 0 inserting ``import foo\\n``."""
    var v = parse_json(String(
        "[{\"label\":\"foo\",\"kind\":3,"
        + "\"insertText\":\"foo\","
        + "\"additionalTextEdits\":["
        + "{\"newText\":\"import foo\\n\","
        + "\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":0,\"character\":0}}}"
        + "]}]"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 1)
    assert_equal(items[0].insert_text, String("foo"))
    assert_equal(len(items[0].additional_text_edits), 1)
    var aux = items[0].additional_text_edits[0]
    assert_equal(aux.start_line, 0)
    assert_equal(aux.start_char, 0)
    assert_equal(aux.end_line, 0)
    assert_equal(aux.end_char, 0)
    assert_equal(aux.new_text, String("import foo\n"))


def test_lsp_parse_completion_result_captures_data_for_resolve() raises:
    """An item whose ``additionalTextEdits`` are deferred to resolve
    arrives with empty aux edits, ``resolved == False``, and its opaque
    ``data`` payload preserved as raw JSON so it can be echoed back in
    ``completionItem/resolve``."""
    var v = parse_json(String(
        "[{\"label\":\"foo\",\"kind\":3,"
        + "\"data\":{\"import\":\"bar\",\"id\":7}}]"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 1)
    assert_equal(len(items[0].additional_text_edits), 0)
    assert_false(items[0].resolved)
    # ``data`` round-trips as re-parseable JSON carrying both members.
    assert_true(len(items[0].data.as_bytes()) > 0)
    var back = parse_json(items[0].data)
    assert_true(back.is_object())
    var imp = back.object_get(String("import"))
    assert_true(Bool(imp))
    assert_equal(imp.value().as_str(), String("bar"))


def test_lsp_parse_additional_text_edits_from_resolved_item() raises:
    """A ``completionItem/resolve`` response is a single CompletionItem
    object; ``_parse_additional_text_edits`` pulls its (now-populated)
    auto-import edit straight off that object — the same helper the
    initial-list parse uses."""
    var resolved = parse_json(String(
        "{\"label\":\"foo\",\"detail\":\"def foo() -> int\","
        + "\"additionalTextEdits\":["
        + "{\"newText\":\"from bar import foo\\n\","
        + "\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":0,\"character\":0}}}"
        + "]}"
    ))
    var aux = _parse_additional_text_edits(resolved)
    assert_equal(len(aux), 1)
    assert_equal(aux[0].new_text, String("from bar import foo\n"))
    assert_equal(aux[0].start_line, 0)
    assert_equal(aux[0].end_char, 0)


def test_lsp_parse_completion_result_extracts_text_edit_range() raises:
    """A ``textEdit`` with a ``range`` populates ``has_range`` plus
    the start/end coords so the editor can replace exactly what the
    server intended, even across non-word punctuation."""
    var v = parse_json(String(
        "[{\"label\":\"reviews/reviews__tags.html\","
        + "\"kind\":17,"
        + "\"textEdit\":{"
        + "\"range\":{\"start\":{\"line\":3,\"character\":12},"
        + "\"end\":{\"line\":3,\"character\":22}},"
        + "\"newText\":\"reviews/reviews__tags.html\"}}]"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 1)
    assert_equal(
        items[0].insert_text, String("reviews/reviews__tags.html"),
    )
    assert_true(items[0].has_range)
    assert_equal(items[0].range_start_line, 3)
    assert_equal(items[0].range_start_char, 12)
    assert_equal(items[0].range_end_line, 3)
    assert_equal(items[0].range_end_char, 22)


def test_lsp_parse_completion_result_extracts_insert_replace_edit() raises:
    """``InsertReplaceEdit`` uses ``replace`` (not ``insert``) so
    accepting the completion overwrites the existing text rather than
    leaving a trailing suffix past the cursor."""
    var v = parse_json(String(
        "[{\"label\":\"foo\",\"kind\":3,"
        + "\"textEdit\":{"
        + "\"newText\":\"foobar\","
        + "\"insert\":{\"start\":{\"line\":1,\"character\":2},"
        + "\"end\":{\"line\":1,\"character\":5}},"
        + "\"replace\":{\"start\":{\"line\":1,\"character\":2},"
        + "\"end\":{\"line\":1,\"character\":8}}}}]"
    ))
    var items = _parse_completion_result(v)
    assert_equal(len(items), 1)
    assert_equal(items[0].insert_text, String("foobar"))
    assert_true(items[0].has_range)
    assert_equal(items[0].range_start_char, 2)
    assert_equal(items[0].range_end_char, 8)  # ``replace`` wins over ``insert``


def test_lsp_parse_diagnostics_skips_malformed_entries() raises:
    """Entries missing ``range`` are dropped; malformed ones don't
    poison neighbors. The good entries either side must parse."""
    var v = parse_json(String(
        "["
        + "{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        + "\"end\":{\"line\":0,\"character\":1}},\"severity\":1,"
        + "\"message\":\"first\"},"
        # No ``range`` — must be skipped, not abort the loop.
        + "{\"severity\":1,\"message\":\"orphan\"},"
        + "{\"range\":{\"start\":{\"line\":5,\"character\":0},"
        + "\"end\":{\"line\":5,\"character\":2}},\"severity\":2,"
        + "\"message\":\"third\"}"
        + "]"
    ))
    var diags = _parse_diagnostics_array(v)
    assert_equal(len(diags), 2)
    assert_equal(diags[0].message, String("first"))
    assert_equal(diags[1].message, String("third"))


def test_lsp_diagnostics_inflight_tracking() raises:
    """``LspManager`` exposes the per-path ``analyzing edits…`` signal
    via ``diagnostics_inflight_ms_for``: positive ms after we mark a
    didChange in flight, ``-1`` once a matching ``publishDiagnostics``
    arrives. Drives the status-bar spinner so the user can see when
    squiggles are stale because the server hasn't caught up yet."""
    var m = LspManager()
    var path = String("/tmp/example.py")
    # No prior didOpen / didChange: nothing in flight.
    assert_equal(m.diagnostics_inflight_ms_for(path), -1)
    # Simulate sending a didChange at version 3 — the
    # ``_send_did_change`` wrapper is the in-flight gate but it also
    # touches the network; ``_mark_diag_inflight`` is the inner step
    # we actually want to assert on.
    m._mark_diag_inflight(path, 3)
    assert_true(m.diagnostics_inflight_ms_for(path) >= 0)
    # Stale publishDiagnostics (older version) must NOT clear the
    # spinner — we're still waiting on a fresh response for v3.
    m._clear_diag_inflight(path, 2)
    assert_true(m.diagnostics_inflight_ms_for(path) >= 0)
    # Matching version clears.
    m._clear_diag_inflight(path, 3)
    assert_equal(m.diagnostics_inflight_ms_for(path), -1)
    # Servers that don't echo a version (``pub_version <= 0``) clear
    # unconditionally — better to occasionally hide the spinner
    # early than leave it stuck on those servers.
    m._mark_diag_inflight(path, 7)
    m._clear_diag_inflight(path, 0)
    assert_equal(m.diagnostics_inflight_ms_for(path), -1)


def test_lsp_subprocess_round_trip_via_cat() raises:
    """End-to-end pipe + framer test using ``/bin/cat``."""
    var cat_info = stat_file(String("/bin/cat"))
    if not cat_info.ok:
        assert_true(True)
        return
    var argv = List[String]()
    argv.append(String("/bin/cat"))
    var p = LspProcess.spawn(argv)
    p.write_message(String("ping"))
    p.write_message(String("pong"))
    var got1: Optional[String] = Optional[String]()
    for _ in range(200):
        var maybe = p.poll_message(Int32(50))
        if maybe:
            got1 = maybe
            break
    assert_true(Bool(got1))
    assert_equal(got1.value(), String("ping"))
    var got2: Optional[String] = Optional[String]()
    for _ in range(200):
        var maybe = p.poll_message(Int32(50))
        if maybe:
            got2 = maybe
            break
    assert_true(Bool(got2))
    assert_equal(got2.value(), String("pong"))
    p.terminate()


def test_lsp_write_message_queues_bytes_when_fd_is_unavailable() raises:
    """The queued path means ``write_message`` never blocks: with no
    real stdin (default-constructed ``LspProcess``, ``stdin_fd == -1``)
    the framed bytes accumulate in ``_pending_write`` instead of
    racing into a syscall. This is the same invariant that protects
    the UI thread when an LSP server stops draining its stdin —
    bytes pile up in the queue, never inside ``write(2)``.
    """
    var p = LspProcess()
    p.write_message(String("hello"))
    # 21-byte ``Content-Length: 5\r\n\r\n`` header + 5-byte payload.
    assert_equal(len(p._pending_write), 26)
    assert_false(p.write_overflowed())
    # A second message accumulates on top of the first.
    p.write_message(String("world"))
    assert_equal(len(p._pending_write), 52)
    assert_false(p.write_overflowed())


def test_lsp_write_overflow_resets_queue_and_latches_flag() raises:
    """Past the 16 MB safety cap, the queue is dropped and
    ``write_overflowed`` latches True so the manager can fail the
    session rather than silently lose bytes mid-frame.
    """
    var p = LspProcess()
    # Seed the queue at exactly the 16 MB cap by hand — much faster
    # than building a >32 MB payload byte by byte through
    # ``append_string_bytes``. Then any further ``write_message``
    # tips us past the strict ``>`` cap and trips the overflow latch.
    comptime CAP_AT: Int = 16 * 1024 * 1024
    for _ in range(CAP_AT):
        p._pending_write.append(UInt8(0))
    assert_false(p.write_overflowed())
    p.write_message(String("tipover"))
    assert_true(p.write_overflowed())
    assert_equal(len(p._pending_write), 0)


def test_install_runner_last_lines_picks_tail_skipping_blanks() raises:
    """``_last_lines`` is the helper the install popup uses to render the
    rolling 5-line tail. Trailing blanks should be dropped (so the popup
    doesn't fill its window with empty rows when the installer ends with
    a newline) and trailing CR/whitespace per line stripped."""
    # Fewer lines than asked-for: returns them all, oldest first.
    var two = _last_lines(String("alpha\nbeta\n"), 5)
    assert_equal(len(two), 2)
    assert_equal(two[0], String("alpha"))
    assert_equal(two[1], String("beta"))
    # More lines than asked-for: returns the last N.
    var input = String("a\nb\nc\nd\ne\nf\ng\n")
    var tail = _last_lines(input, 3)
    assert_equal(len(tail), 3)
    assert_equal(tail[0], String("e"))
    assert_equal(tail[1], String("f"))
    assert_equal(tail[2], String("g"))
    # CRLF / trailing space are stripped per line.
    var crlf = _last_lines(String("hello\r\nworld  \n"), 5)
    assert_equal(len(crlf), 2)
    assert_equal(crlf[0], String("hello"))
    assert_equal(crlf[1], String("world"))
    # Empty / whitespace-only lines collapse out (so a trailing blank
    # after the final progress line doesn't push real output off-screen).
    var blanks = _last_lines(String("first\n\n\nsecond\n   \n"), 5)
    assert_equal(len(blanks), 2)
    assert_equal(blanks[0], String("first"))
    assert_equal(blanks[1], String("second"))


def test_install_runner_runs_sh_command_to_completion() raises:
    """End-to-end: spawn ``sh -c "echo hello"`` via the runner and tick
    until the child reaps. The returned ``InstallResult`` should carry
    exit 0, the captured ``hello`` output, and the original label /
    command we started with."""
    var r = InstallRunner()
    assert_false(r.is_active())
    r.start(String("smoke"), String("echo hello"))
    assert_true(r.is_active())
    var result_opt: Optional[InstallResult] = Optional[InstallResult]()
    # ``echo`` takes microseconds; the loop ceiling exists only to bound
    # the test if something goes wrong in the spawn / reap path.
    for _ in range(2000):
        result_opt = r.tick()
        if result_opt:
            break
    assert_true(Bool(result_opt))
    var result = result_opt.value()
    assert_true(result.ok())
    assert_equal(result.label, String("smoke"))
    assert_equal(result.command, String("echo hello"))
    # ``echo hello`` writes ``hello\n`` to stdout — the trailing newline
    # is preserved in ``output`` (we only strip per-line in the popup).
    var ob = result.output.as_bytes()
    assert_true(len(ob) >= 5)
    var first5 = String(StringSlice(unsafe_from_utf8=ob[:5]))
    assert_equal(first5, String("hello"))
    # Runner is back to idle, ready to accept a new install.
    assert_false(r.is_active())


def test_install_runner_failure_carries_nonzero_exit() raises:
    """A non-zero exit must be visible to the host so it knows to open
    the failure-output editor window. ``sh -c 'exit 7'`` is the minimal
    deterministic failure."""
    var r = InstallRunner()
    r.start(String("fail-smoke"), String("exit 7"))
    var result_opt: Optional[InstallResult] = Optional[InstallResult]()
    for _ in range(200):
        result_opt = r.tick()
        if result_opt:
            break
    assert_true(Bool(result_opt))
    var result = result_opt.value()
    assert_false(result.ok())
    assert_equal(result.exit_code(), 7)


def test_lsp_initialize_against_mojo_lsp_server() raises:
    """Spawn ``mojo-lsp-server`` and round-trip an ``initialize`` request.
    Skipped silently if the binary isn't installed."""
    var server = String(".pixi/envs/default/bin/mojo-lsp-server")
    var info = stat_file(server)
    if not info.ok:
        assert_true(True)
        return
    var argv = List[String]()
    argv.append(server)
    var client = LspClient.spawn(argv)
    var params = json_object()
    params.put(String("processId"), json_int(0))
    params.put(String("rootUri"), json_null())
    params.put(String("capabilities"), json_object())
    var req_id = client.send_request(String("initialize"), params^)
    var got: Optional[LspIncoming] = Optional[LspIncoming]()
    for _ in range(100):
        var maybe = client.poll(Int32(50))
        if maybe:
            got = maybe.copy()
            break
    if not got:
        var err = client.process.drain_stderr()
        client.terminate()
        raise Error(String("no LSP response; stderr=") + err)
    var msg = got.value().copy()
    assert_equal(Int(msg.kind), Int(LSP_RESPONSE))
    assert_true(Bool(msg.id))
    assert_true(msg.id.value().is_string())
    assert_equal(msg.id.value().as_str(), req_id)
    assert_true(Bool(msg.result))
    assert_true(msg.result.value().is_object())
    assert_true(msg.result.value().object_has(String("capabilities")))
    client.send_notification(String("initialized"), json_object())
    var shutdown_id = client.send_request(String("shutdown"), json_null())
    for _ in range(100):
        var maybe2 = client.poll(Int32(50))
        if maybe2 and Bool(maybe2.value().id) \
                and maybe2.value().id.value().is_string() \
                and maybe2.value().id.value().as_str() == shutdown_id:
            break
    client.send_notification(String("exit"), json_null())
    var exited = False
    for _ in range(20):
        if client.process.try_reap():
            exited = True
            break
    if not exited:
        client.terminate()


def test_ty_offers_quickfix_for_missing_any_import() raises:
    """Spawn ``ty server``, open a Python file that uses ``Any`` without
    importing it, and ask for ``textDocument/codeAction`` on the resulting
    ``unresolved-reference`` diagnostic. Assert ty returns at least one
    ``quickfix`` whose ``WorkspaceEdit`` inserts ``from typing import Any``.

    This pins ty's auto-fix-for-missing-imports behavior — the question
    that motivated the test was whether ty actually offers an import
    quickfix here (it does, as of ty 0.0.34). When our diagnostic menu
    grows a "Quick fix" option, this test guards against ty silently
    dropping the feature out from under us. Skipped silently if ``ty``
    isn't on ``$PATH`` so the suite still passes on dev machines that
    haven't installed it.
    """
    if len(which(String("ty")).as_bytes()) == 0:
        assert_true(True)
        return
    # Workspace dir that ty will treat as its project root. Files outside
    # any workspace get partial analysis from ty, so we set one up
    # explicitly and point ``rootUri`` at it.
    var dir = String("/tmp/turbokod_ty_quickfix_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var py_path = dir + String("/probe.py")
    assert_true(write_file(py_path, String("def f(x: Any) -> Any:\n    return x\n")))
    var root_uri = String("file://") + dir
    var doc_uri = String("file://") + py_path

    var argv = List[String]()
    argv.append(String("ty"))
    argv.append(String("server"))
    var client = LspClient.spawn(argv, dir)

    # initialize — advertise codeAction client capability with a
    # ``codeActionLiteralSupport`` valueSet that includes ``quickfix``,
    # otherwise some servers return only command objects (or nothing).
    var params = json_object()
    params.put(String("processId"), json_int(0))
    params.put(String("rootUri"), json_str(root_uri))
    var folders = json_array()
    var folder = json_object()
    folder.put(String("uri"), json_str(root_uri))
    folder.put(String("name"), json_str(String("ty_quickfix")))
    folders.append(folder^)
    params.put(String("workspaceFolders"), folders^)
    var caps = json_object()
    var text_doc_caps = json_object()
    var ca_caps = json_object()
    var ca_literal = json_object()
    var ca_kind = json_object()
    var kind_values = json_array()
    kind_values.append(json_str(String("")))
    kind_values.append(json_str(String("quickfix")))
    ca_kind.put(String("valueSet"), kind_values^)
    ca_literal.put(String("codeActionKind"), ca_kind^)
    ca_caps.put(String("codeActionLiteralSupport"), ca_literal^)
    text_doc_caps.put(String("codeAction"), ca_caps^)
    caps.put(String("textDocument"), text_doc_caps^)
    params.put(String("capabilities"), caps^)
    var init_id = client.send_request(String("initialize"), params^)

    var saw_init = False
    for _ in range(200):
        var maybe = client.poll(Int32(50))
        if maybe and Bool(maybe.value().id) \
                and maybe.value().id.value().is_string() \
                and maybe.value().id.value().as_str() == init_id:
            saw_init = True
            break
    if not saw_init:
        var err = client.process.drain_stderr()
        client.terminate()
        raise Error(String("ty: no initialize response; stderr=") + err)
    client.send_notification(String("initialized"), json_object())

    # didOpen with the offending source — triggers ty's diagnostics.
    var did_open = json_object()
    var doc = json_object()
    doc.put(String("uri"), json_str(doc_uri))
    doc.put(String("languageId"), json_str(String("python")))
    doc.put(String("version"), json_int(1))
    doc.put(String("text"), json_str(
        String("def f(x: Any) -> Any:\n    return x\n")
    ))
    did_open.put(String("textDocument"), doc^)
    client.send_notification(String("textDocument/didOpen"), did_open^)

    # Drain notifications until publishDiagnostics for our URI arrives
    # with a non-empty diagnostic list. ty emits one publishDiagnostics
    # immediately on didOpen, so a few hundred ms is plenty.
    var diag_params: Optional[JsonValue] = Optional[JsonValue]()
    for _ in range(200):
        var maybe = client.poll(Int32(50))
        if not maybe:
            continue
        var msg = maybe.value().copy()
        if Int(msg.kind) != Int(LSP_NOTIFICATION):
            continue
        if not Bool(msg.method) \
                or msg.method.value() != String("textDocument/publishDiagnostics"):
            continue
        if not Bool(msg.params):
            continue
        var pv = msg.params.value().copy()
        var uri_v = pv.object_get(String("uri"))
        if not uri_v or uri_v.value().as_str() != doc_uri:
            continue
        var diags_v = pv.object_get(String("diagnostics"))
        if not diags_v or not diags_v.value().is_array():
            continue
        if diags_v.value().array_len() == 0:
            continue
        diag_params = Optional[JsonValue](pv^)
        break
    if not diag_params:
        var err = client.process.drain_stderr()
        client.terminate()
        raise Error(String("ty: no diagnostics published; stderr=") + err)

    var pv = diag_params.value().copy()
    var diags = pv.object_get(String("diagnostics")).value().copy()
    var first_diag = diags.array_at(0)
    var range_v = first_diag.object_get(String("range")).value().copy()

    # textDocument/codeAction with a *minimal* echoed diagnostic — only
    # range + severity + message + source + code, matching exactly what
    # ``LspManager.request_code_actions`` reconstructs from the parsed
    # ``Diagnostic`` struct. We deliberately rebuild the echoed diag
    # rather than re-forwarding ty's original to guard against the
    # regression that motivated this test: when ``code`` is missing,
    # ty 0.0.34 returns ``result: null`` instead of the import quickfix.
    var min_diag = json_object()
    min_diag.put(String("range"), range_v.copy())
    var sev_v = first_diag.object_get(String("severity"))
    if sev_v and sev_v.value().is_int():
        min_diag.put(String("severity"), json_int(sev_v.value().as_int()))
    var msg_v = first_diag.object_get(String("message"))
    if msg_v and msg_v.value().is_string():
        min_diag.put(String("message"), json_str(msg_v.value().as_str()))
    var src_v = first_diag.object_get(String("source"))
    if src_v and src_v.value().is_string():
        min_diag.put(String("source"), json_str(src_v.value().as_str()))
    var code_v = first_diag.object_get(String("code"))
    if code_v and code_v.value().is_string():
        min_diag.put(String("code"), json_str(code_v.value().as_str()))
    var ca_params = json_object()
    var ca_doc = json_object()
    ca_doc.put(String("uri"), json_str(doc_uri))
    ca_params.put(String("textDocument"), ca_doc^)
    ca_params.put(String("range"), range_v.copy())
    var ctx = json_object()
    var ctx_diags = json_array()
    ctx_diags.append(min_diag^)
    ctx.put(String("diagnostics"), ctx_diags^)
    ca_params.put(String("context"), ctx^)
    var ca_id = client.send_request(String("textDocument/codeAction"), ca_params^)

    var ca_result: Optional[JsonValue] = Optional[JsonValue]()
    for _ in range(200):
        var maybe = client.poll(Int32(50))
        if not maybe:
            continue
        var msg = maybe.value().copy()
        if Int(msg.kind) != Int(LSP_RESPONSE):
            continue
        if not Bool(msg.id) or not msg.id.value().is_string() \
                or msg.id.value().as_str() != ca_id:
            continue
        if Bool(msg.result):
            ca_result = Optional[JsonValue](msg.result.value().copy())
        break
    if not ca_result:
        var err = client.process.drain_stderr()
        client.terminate()
        raise Error(String("ty: no codeAction response; stderr=") + err)

    # The result must be a non-empty array; at least one entry must be a
    # ``quickfix`` whose WorkspaceEdit inserts ``from typing import Any``.
    var actions = ca_result.value().copy()
    assert_true(actions.is_array())
    assert_true(actions.array_len() > 0)
    var found_typing_any = False
    for i in range(actions.array_len()):
        var action = actions.array_at(i)
        if not action.is_object():
            continue
        var kind_v = action.object_get(String("kind"))
        if not kind_v or kind_v.value().as_str() != String("quickfix"):
            continue
        var edit_v = action.object_get(String("edit"))
        if not edit_v or not edit_v.value().is_object():
            continue
        var changes_v = edit_v.value().object_get(String("changes"))
        if not changes_v or not changes_v.value().is_object():
            continue
        var file_edits_v = changes_v.value().object_get(doc_uri)
        if not file_edits_v or not file_edits_v.value().is_array():
            continue
        var file_edits = file_edits_v.value().copy()
        for j in range(file_edits.array_len()):
            var te = file_edits.array_at(j)
            var new_text_v = te.object_get(String("newText"))
            if not new_text_v:
                continue
            var nt = new_text_v.value().as_str()
            if nt.find(String("from typing import Any")) >= 0:
                found_typing_any = True
                break
        if found_typing_any:
            break
    assert_true(found_typing_any)

    # Best-effort shutdown so we don't leak a ty subprocess.
    var shutdown_id = client.send_request(String("shutdown"), json_null())
    for _ in range(40):
        var maybe = client.poll(Int32(50))
        if maybe and Bool(maybe.value().id) \
                and maybe.value().id.value().is_string() \
                and maybe.value().id.value().as_str() == shutdown_id:
            break
    client.send_notification(String("exit"), json_null())
    var exited = False
    for _ in range(20):
        if client.process.try_reap():
            exited = True
            break
    if not exited:
        client.terminate()
    _ = external_call["unlink", Int32]((py_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_taplo_publishes_diagnostics_after_workspace_configuration_probe() raises:
    """Regression: taplo issues a ``workspace/configuration`` request to
    the client right after ``didOpen`` and blocks *all* publishDiagnostics
    until that probe is answered. Before the LSP_REQUEST handler landed
    we silently dropped the request, leaving the "analyzing edits…"
    spinner stuck on every TOML buffer indefinitely.

    The check: spawn taplo via ``LspManager``, notify_opened a small
    pyproject.toml, pump ``tick`` until ``diagnostics_inflight_ms_for``
    clears (= a matching publishDiagnostics has arrived). Skipped
    silently when taplo isn't on PATH so the suite still passes on dev
    machines that don't have it.
    """
    if len(which(String("taplo")).as_bytes()) == 0:
        assert_true(True)
        return
    # ``/private/tmp`` to dodge the macOS symlink: ``/tmp`` → ``/private/tmp``
    # makes URIs that taplo canonicalizes back to the resolved path
    # not match the ``/tmp/...`` we stored in ``_diag_inflight_paths``.
    # Real-world buffer paths under a user's project root don't hit
    # this since there's no symlink in the way.
    var dir = String("/private/tmp/turbokod_taplo_probe_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var toml_path = dir + String("/pyproject.toml")
    assert_true(write_file(
        toml_path,
        String("[tool.black]\nline-length = 100\n"),
    ))

    var m = LspManager()
    var argv = List[String]()
    argv.append(String("taplo"))
    argv.append(String("lsp"))
    argv.append(String("stdio"))
    m.start_with(String("toml"), argv, dir)
    if m.is_failed():
        _ = external_call["unlink", Int32](
            (toml_path + String("\0")).unsafe_ptr(),
        )
        _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())
        raise Error(String("taplo: spawn failed: ") + m.failure_reason)

    # Drive tick() until the handshake completes and the configuration
    # probe arrives + is answered. 200 × 25 ms = 5 s should be plenty.
    for _ in range(200):
        _ = m.tick()
        if m.is_ready():
            break
        _ = external_call["usleep", Int32](UInt32(25_000))
    if not m.is_ready():
        m.shutdown()
        _ = external_call["unlink", Int32](
            (toml_path + String("\0")).unsafe_ptr(),
        )
        _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())
        raise Error(String("taplo: never reached READY state"))

    m.notify_opened(toml_path, String("[tool.black]\nline-length = 100\n"))
    # Now pump until the spinner clears. If we drop server-to-client
    # requests, taplo never publishes — so the loop times out and the
    # final assertion fails. With the handler wired, the configuration
    # round-trip + publishDiagnostics arrives in ~10 ms in practice;
    # 5 s of polling is the generous belt-and-braces budget.
    var cleared = False
    for _ in range(200):
        _ = m.tick()
        if m.diagnostics_inflight_ms_for(toml_path) < 0:
            cleared = True
            break
        _ = external_call["usleep", Int32](UInt32(25_000))

    var stderr_tail = m.captured_stderr()
    m.shutdown()
    _ = external_call["unlink", Int32](
        (toml_path + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())
    if not cleared:
        raise Error(
            String("taplo: publishDiagnostics never arrived within 5s; ")
            + String("inflight handler likely broken. stderr=") + stderr_tail
        )


def main() raises:
    setup_test_env()
    test_rename_path_moves_file()
    test_downloadable_grammar_registry_has_elm()
    test_downloadable_grammar_registry_misses_unknown()
    test_type_ahead_pick_returns_index_or_minus_one()
    test_type_ahead_pick_solo_fallback()
    test_intellij_language_injection_html_in_python_string()
    test_intellij_language_injection_inline_marker()
    test_intellij_language_injection_unknown_language_no_op()
    test_intellij_language_injection_triple_quoted_python()
    test_uri_to_path_percent_decodes()
    test_lsp_framer_finds_double_crlf()
    test_lsp_framer_parses_content_length()
    test_lsp_framer_extract_one_message()
    test_lsp_drop_prefix_helper()
    test_lsp_classify_message()
    test_lsp_parse_diagnostics_array_minimum_fields()
    test_lsp_parse_diagnostics_array_full_fields()
    test_lsp_parse_diagnostics_preserves_code_field()
    test_lsp_parse_code_action_result_quickfix_with_workspace_edit()
    test_lsp_parse_code_action_result_skips_bare_commands()
    test_lsp_parse_code_action_result_null_or_non_array_is_empty()
    test_lsp_parse_rename_workspace_edit_multi_file()
    test_lsp_rename_edits_apply_to_buffer()
    test_lsp_parse_text_edits_and_apply_formats_buffer()
    test_lsp_parse_document_colors()
    test_lsp_parse_hierarchy_result()
    test_lsp_parse_selection_ranges_walks_parent_chain()
    test_lsp_parse_inlay_hints()
    test_lsp_parse_code_lens()
    test_lsp_parse_signature_help()
    test_lsp_parse_document_highlights()
    test_lsp_parse_text_edits_null_is_empty()
    test_lsp_server_progress_and_show_message()
    test_lsp_server_supports_reads_capabilities()
    test_lsp_dynamic_capability_registration()
    test_lsp_pull_diagnostics_storage()
    test_lsp_pull_diagnostics_multi_inflight()
    test_lsp_server_supports_will_save()
    test_lsp_log_message_capture()
    test_lsp_message_request_accessors()
    test_lsp_show_document_accessors()
    test_lsp_server_wants_did_create()
    test_lsp_codelens_resolve_collects_unresolved()
    test_lsp_on_type_trigger_chars()
    test_lsp_color_unit_text()
    test_lsp_parse_inline_value_exprs()
    test_lsp_parse_folding_ranges()
    test_lsp_parse_inline_values()
    test_lsp_parse_linked_ranges()
    test_lsp_parse_inline_completion()
    test_lsp_parse_monikers()
    test_lsp_parse_document_links()
    test_lsp_parse_prepare_rename_placeholder()
    test_lsp_initialize_params_advertise_code_action_literal_support()
    test_lsp_parse_completion_result_array_shape()
    test_lsp_parse_completion_result_list_shape()
    test_lsp_parse_completion_result_honors_sort_text()
    test_lsp_parse_completion_result_snippet_falls_back_to_label()
    test_lsp_parse_hover_result_string_contents()
    test_lsp_parse_hover_result_markup_content()
    test_lsp_parse_hover_result_array_joins_with_newlines()
    test_lsp_parse_hover_result_empty_when_no_contents()
    test_lsp_parse_references_result_list_of_locations()
    test_lsp_parse_references_result_null_is_empty()
    test_lsp_parse_completion_result_extracts_additional_text_edits()
    test_lsp_parse_completion_result_captures_data_for_resolve()
    test_lsp_parse_additional_text_edits_from_resolved_item()
    test_lsp_parse_completion_result_extracts_text_edit_range()
    test_lsp_parse_completion_result_extracts_insert_replace_edit()
    test_lsp_parse_diagnostics_skips_malformed_entries()
    test_lsp_diagnostics_inflight_tracking()
    test_lsp_subprocess_round_trip_via_cat()
    test_lsp_write_message_queues_bytes_when_fd_is_unavailable()
    test_lsp_write_overflow_resets_queue_and_latches_flag()
    test_install_runner_last_lines_picks_tail_skipping_blanks()
    test_install_runner_runs_sh_command_to_completion()
    test_install_runner_failure_carries_nonzero_exit()
    test_lsp_initialize_against_mojo_lsp_server()
    test_ty_offers_quickfix_for_missing_any_import()
    test_taplo_publishes_diagnostics_after_workspace_configuration_probe()
    print("lsp: 80 tests passed")
