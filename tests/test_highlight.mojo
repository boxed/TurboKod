"""Syntax highlighting: TextMate grammars and language specs.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import Attr, STYLE_BOLD, SYN_KEYWORD
from turbokod.editor import Editor
from turbokod.file_io import join_path, write_file
from turbokod.project_targets import python_venv_dir
from turbokod.debug_pane import _extract_path_line_links
from turbokod.doc_store import html_to_text
from turbokod.language_config import (
    LanguageSpec, built_in_servers, find_language_by_id,
    find_language_for_extension
)
from turbokod.language_editor import LanguageEditor
from turbokod.debugger_config import (
    built_in_debuggers, find_debugger_for_language,
    python_debugger_spec_for_venv
)
from turbokod.highlight import (
    GrammarRegistry, Highlight, HighlightCache,
    _apply_django_template_overlay, embedded_language_extensions,
    highlight_for_extension, highlight_incremental, highlight_comment_attr,
    highlight_ident_attr, highlight_keyword_attr, highlight_number_attr,
    highlight_operator_attr, highlight_string_attr, template_include_at
)
from turbokod.posix import which
from turbokod.grammar_install import (
    built_in_downloadable_grammars, find_downloadable_grammar_by_language,
    find_downloadable_grammar_for_extension, grammar_install_command,
    user_grammar_path, user_grammar_path_for_ext
)
from turbokod.project_grammars import GrammarOverride
from turbokod.onig import OnigRegex, onig_global_init, onig_tracked_count
from turbokod.tm_grammar import load_grammar_from_string
from turbokod.tm_tokenizer import tokenize_with_grammar
from turbokod.geometry import Rect

from support import (
    _contains, _hl_lines, _hl_set, _key, _temp_path, setup_test_env
)


def test_grammar_install_command_targets_user_config() raises:
    """The shell command must mkdir the per-language dir and curl the
    grammar JSON to the path the highlighter probes
    (``user_grammar_path_for_ext``). Verified by string-match because
    the runner is a shell pipeline; the alternative is end-to-end with
    a fake server, which adds infrastructure with no payoff."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_by_language(specs, String("elm"))
    assert_true(idx >= 0)
    var cmd = grammar_install_command(String("elm"), specs[idx].url)
    var dest = user_grammar_path(String("elm"))
    # If $HOME is set the destination path will be embedded; if not,
    # the helper produces an empty path and we just check ``mkdir -p``
    # still appears (the runner would fail in that case, which is the
    # correct end state for a sandboxed process with no $HOME).
    assert_true(_contains(cmd, String("mkdir -p")))
    assert_true(_contains(cmd, String("curl ")))
    if len(dest.as_bytes()) > 0:
        assert_true(_contains(cmd, dest))


def test_django_grammar_is_in_downloadable_catalog() raises:
    """The Django HTML grammar is shipped as a downloadable, not as an
    auto-binding for ``.html`` — its ``file_types`` list is empty so a
    Django-less project's ``.html`` files don't get hijacked. Users opt
    in per-project via ``.turbokod/grammars.json``."""
    var specs = built_in_downloadable_grammars()
    var idx = find_downloadable_grammar_by_language(
        specs, String("django-html"),
    )
    assert_true(idx >= 0)
    assert_equal(specs[idx].language_id, String("django-html"))
    assert_equal(len(specs[idx].file_types), 0)
    # No ext should resolve to this grammar via the auto-binding lookup.
    assert_equal(
        find_downloadable_grammar_for_extension(specs, String("html")),
        -1,
    )


def test_grammar_registry_override_routes_to_alternate_grammar() raises:
    """End-to-end: with an override mapping ``.html`` → ``python``, a
    buffer of Python source opened as ``.html`` tokenizes through the
    Python grammar — i.e. the override actually changes which grammar
    runs, not just which path string we hand back.

    Comparing against the same buffer tokenized as ``.py`` makes the
    intent explicit: the two highlight lists must match span-for-span.
    """
    var lines = List[String]()
    lines.append(String("def greet(name):"))
    lines.append(String("    return name"))

    # Baseline: tokenize as Python directly.
    var py_registry = GrammarRegistry()
    var py_cache = HighlightCache()
    var py_hls = highlight_incremental(
        String("py"), lines, 0, py_registry, py_cache,
    )
    assert_true(len(py_hls) > 0)

    # Same buffer, opened as ``.html`` but with the override pointing
    # ``html`` at the python grammar.
    var overrides = List[GrammarOverride]()
    overrides.append(GrammarOverride(String("html"), String("python")))
    var html_registry = GrammarRegistry()
    html_registry.set_overrides(overrides^)
    var html_cache = HighlightCache()
    var html_hls = highlight_incremental(
        String("html"), lines, 0, html_registry, html_cache,
    )
    assert_equal(len(html_hls), len(py_hls))
    for i in range(len(html_hls)):
        assert_equal(html_hls[i].row, py_hls[i].row)
        assert_equal(html_hls[i].col_start, py_hls[i].col_start)
        assert_equal(html_hls[i].col_end, py_hls[i].col_end)

    # Sanity check: without the override, ``.html`` should *not* match
    # the python highlights (the html grammar produces a very different
    # token shape, or none at all, for this input).
    var plain_html_registry = GrammarRegistry()
    var plain_html_cache = HighlightCache()
    var plain_html_hls = highlight_incremental(
        String("html"), lines, 0, plain_html_registry, plain_html_cache,
    )
    var matches_python = False
    if len(plain_html_hls) == len(py_hls):
        matches_python = True
        for i in range(len(plain_html_hls)):
            if (plain_html_hls[i].row != py_hls[i].row
                    or plain_html_hls[i].col_start != py_hls[i].col_start
                    or plain_html_hls[i].col_end != py_hls[i].col_end):
                matches_python = False
                break
    assert_false(matches_python)


def test_highlight_for_extension_does_not_strand_its_grammar() raises:
    """The uncached convenience entry point must not leak a grammar.

    It used to be a separate implementation that loaded a grammar,
    tokenized, and dropped it — which reclaims nothing, because libonig's
    allocations are owned by the shim's registry rather than by Mojo. A
    TypeScript buffer cost ~500 handles per call, and a buffer carrying a
    ``# language=html`` injection marker ~900 (the injection pass built a
    second throwaway registry). It's now a wrapper around
    ``highlight_incremental`` with a private registry it releases.
    """
    onig_global_init()
    var ts = List[String]()
    ts.append(String("interface Foo { bar: string }"))
    ts.append(String("const x: Foo = { bar: 'hi' };"))
    # Warm: the first call also initialises process-wide libonig state.
    assert_true(len(highlight_for_extension(String("ts"), ts)) > 0)
    var live = onig_tracked_count()
    for _ in range(3):
        assert_true(len(highlight_for_extension(String("ts"), ts)) > 0)
    assert_equal(onig_tracked_count(), live)

    # The injection path compiles a *second* grammar; it must go back too.
    var inj = List[String]()
    inj.append(String("# language=html"))
    inj.append(String('page = "<div class=\'x\'>hi</div>"'))
    _ = highlight_for_extension(String("py"), inj)
    var live2 = onig_tracked_count()
    for _ in range(3):
        _ = highlight_for_extension(String("py"), inj)
    assert_equal(onig_tracked_count(), live2)


def test_grammar_registry_release_frees_and_leaves_the_engine_usable() raises:
    """``release`` is the one way compiled grammars give memory back, and
    the reason it can exist at all is that the shim frees a handle only
    if it's still registered — so an aliasing copy releasing again is a
    no-op rather than a double free.

    Two earlier attempts at reclaiming these handles (``ArcPointer``
    refcounting, then a manual heap refcount, both from a destructor)
    hung or corrupted the heap, and the symptom was always in the *next*
    compile. So the assertion that matters here isn't that the registry
    emptied — it's that tokenizing through a freshly loaded grammar after
    the frees still produces the same highlights it did before them."""
    var lines = List[String]()
    lines.append(String("def greet(name):"))
    lines.append(String("    return name"))

    var registry = GrammarRegistry()
    var cache = HighlightCache()
    var live_at_start = onig_tracked_count()
    var before = highlight_incremental(
        String("py"), lines, 0, registry, cache,
    )
    assert_true(len(before) > 0)
    assert_true(len(registry.keys) > 0)
    # Loading the grammar compiled handles the shim is now tracking.
    assert_true(onig_tracked_count() > live_at_start)

    registry.release()
    assert_equal(len(registry.keys), 0)
    assert_equal(len(registry.grammars), 0)
    assert_equal(len(registry.paths), 0)
    # And every one of them came back. This is the assertion that matters:
    # RSS can't see it (a freed block stays resident) and the whole point
    # of ``release`` is that the count returns to its floor.
    assert_equal(onig_tracked_count(), live_at_start)
    # Releasing twice must be harmless (the second pass finds nothing
    # registered), and so must a release of a registry that never loaded.
    registry.release()
    var never_loaded = GrammarRegistry()
    never_loaded.release()

    # Compile + tokenize again after the frees: same grammar, same input,
    # same answer.
    var after_registry = GrammarRegistry()
    var after_cache = HighlightCache()
    var after = highlight_incremental(
        String("py"), lines, 0, after_registry, after_cache,
    )
    assert_equal(len(after), len(before))
    for i in range(len(after)):
        assert_equal(after[i].row, before[i].row)
        assert_equal(after[i].col_start, before[i].col_start)
        assert_equal(after[i].col_end, before[i].col_end)
        assert_equal(after[i].attr.fg, before[i].attr.fg)


def test_released_regex_reports_no_match() raises:
    """A released ``OnigRegex`` answers "no match" instead of
    dereferencing a freed ``regex_t``. Belt-and-braces: the contract is
    that nothing uses a handle after release, and this is what happens
    when something does anyway."""
    onig_global_init()
    var rx = OnigRegex(String("wor"))
    var hay = String("hello world")
    var m = rx.search(hay)
    assert_true(Bool(m))
    assert_equal(m.value().start, 6)
    rx.release()
    assert_false(Bool(rx.search(hay)))
    # Idempotent, including through a copy that aliases the same handles.
    var aliased = rx
    aliased.release()
    rx.release()
    assert_false(Bool(aliased.search(hay)))
    # And the engine still works afterwards.
    var fresh = OnigRegex(String("hell"))
    assert_true(Bool(fresh.search(hay)))
    assert_equal(fresh.search(hay).value().start, 0)


def test_grammar_registry_keeps_grammars_across_set_overrides() raises:
    """``set_overrides`` must *not* drop the compiled grammars.

    Nothing frees a compiled grammar's libonig handles (``OnigRegex`` has
    no destructor), so evicting one doesn't reclaim memory — it just
    guarantees the next paint pays for a second copy that lives until the
    process exits. ``set_overrides`` runs on every project open and
    close, which made that ~8 MB per switch with a TypeScript buffer
    open. The mapping change is picked up by the *cache key* instead
    (see the override-routing test above), so eviction was never what
    made overrides work."""
    var registry = GrammarRegistry()
    var cache = HighlightCache()
    var lines = List[String]()
    lines.append(String("def f(): pass"))
    var _ = highlight_incremental(
        String("py"), lines, 0, registry, cache,
    )
    var loaded = len(registry.keys)
    assert_true(loaded > 0)
    registry.set_overrides(List[GrammarOverride]())
    assert_equal(len(registry.keys), loaded)
    assert_equal(len(registry.grammars), loaded)


def test_grammar_registry_override_change_reresolves_without_eviction() raises:
    """Adding an override mid-session changes which grammar a buffer
    tokenizes through, with the previously-loaded grammars still cached.

    This is the invariant the old cache-clearing was standing in for:
    ``cache_key`` is the override's ``language_id`` when an override
    fires and the bare extension otherwise, so a changed mapping resolves
    to a *different* key, misses, and loads — while every other
    language's compiled patterns stay put."""
    var lines = List[String]()
    lines.append(String("def greet(name):"))
    lines.append(String("    return name"))
    var registry = GrammarRegistry()

    # Tokenize as ``.html`` with no override — caches the html grammar.
    var html_cache = HighlightCache()
    var _ = highlight_incremental(
        String("html"), lines, 0, registry, html_cache,
    )
    var before = len(registry.keys)
    assert_true(before > 0)

    # Point ``html`` at the python grammar and re-tokenize the same
    # buffer: the spans must now match a direct python tokenization.
    var overrides = List[GrammarOverride]()
    overrides.append(GrammarOverride(String("html"), String("python")))
    registry.set_overrides(overrides^)
    var after_cache = HighlightCache()
    var after_hls = highlight_incremental(
        String("html"), lines, 0, registry, after_cache,
    )
    var py_registry = GrammarRegistry()
    var py_cache = HighlightCache()
    var py_hls = highlight_incremental(
        String("py"), lines, 0, py_registry, py_cache,
    )
    assert_true(len(py_hls) > 0)
    assert_equal(len(after_hls), len(py_hls))
    for i in range(len(after_hls)):
        assert_equal(after_hls[i].row, py_hls[i].row)
        assert_equal(after_hls[i].col_start, py_hls[i].col_start)
        assert_equal(after_hls[i].col_end, py_hls[i].col_end)
    # The html grammar it had already compiled is still cached.
    assert_true(len(registry.keys) > before)


def test_language_catalog_carries_comment_tokens() raises:
    """Helix's ``languages.toml`` defines ``comment-token`` per language;
    the refresh script lifts it into ``languages.json`` and the loader
    populates ``LanguageSpec.comment_token``. This is what drives the
    Cmd+/ binding so the right marker is used per file type."""
    var specs = built_in_servers()
    var py_idx = find_language_by_id(specs, String("python"))
    if py_idx < 0:
        return  # bundled JSON missing — covered by its own test
    assert_equal(specs[py_idx].comment_token, String("#"))
    var rs_idx = find_language_by_id(specs, String("rust"))
    if rs_idx >= 0:
        assert_equal(specs[rs_idx].comment_token, String("//"))
    var sql_idx = find_language_by_id(specs, String("sql"))
    if sql_idx >= 0:
        assert_equal(specs[sql_idx].comment_token, String("--"))


def test_language_editor_save_emits_override() raises:
    """The editor's ``value()`` after Save must surface the user's
    fields verbatim — language id, file types, and the joined argv
    list split back into argv arrays."""
    var ed = LanguageEditor()
    var argvs = List[String]()
    argvs.append(String("foo --bar baz"))
    ed.open(
        String("xyzlang"), List[String](), argvs^, False,
    )
    # Type a second server.
    ed._add_candidate()
    ed.argv_tf.set_text(String("other --quiet"))
    ed.candidates[ed._list.selected] = ed.argv_tf.text
    var out = ed.value()
    assert_equal(out.language_id, String("xyzlang"))
    assert_equal(len(out.argvs), 2)
    assert_equal(len(out.argvs[0]), 3)
    assert_equal(out.argvs[0][0], String("foo"))
    assert_equal(out.argvs[1][0], String("other"))


def test_language_editor_paint_does_not_damage_dialog_border() raises:
    """End-to-end regression: open the editor with an argv string that
    exceeds the list width, paint it, and assert the dialog's right
    border at every list row is still a vertical bar — proving the
    candidate text was clipped before it could reach the frame."""
    var screen = Rect(0, 0, 100, 40)
    var ed = LanguageEditor()
    var argvs = List[String]()
    # A line longer than the dialog interior — used to overflow into
    # the dialog right border.
    argvs.append(String(
        "some-language-server --very-long-flag /very/long/path/to/binary"
        " --extra-args-that-keep-going-and-going"
    ))
    argvs.append(String("short"))
    ed.open(
        String("xyzlang"), List[String](), argvs^, False,
    )
    var c = Canvas(screen.b.x, screen.b.y)
    ed.paint(c, screen)
    # Dialog right border lives at ``rect.b.x - 1``. Walk the dialog
    # rows that overlap the list rect and confirm the border glyph is
    # still the double-line vertical we drew at frame time. ``║`` is
    # the only legal value; anything else means a candidate string
    # leaked past the list's right edge.
    var dialog = Rect(
        (screen.b.x - 70) // 2, (screen.b.y - 21) // 2,
        (screen.b.x - 70) // 2 + 70, (screen.b.y - 21) // 2 + 21,
    )
    for y in range(dialog.a.y + 1, dialog.b.y - 1):
        var glyph = c.get(dialog.b.x - 1, y).glyph
        assert_equal(glyph, String("║"))


def test_language_editor_list_type_to_jump() raises:
    """The candidate list in the LanguageEditor is also a list
    widget — typing 'p' lands on the first server whose argv starts
    with 'p'. Argv strip mirrors the new selection so the user
    can keep editing."""
    var ed = LanguageEditor()
    var argvs = List[String]()
    argvs.append(String("apple-lsp"))
    argvs.append(String("banana-lsp"))
    argvs.append(String("pyright"))
    ed.open(
        String("xyzlang"), List[String](), argvs^, False,
    )
    ed._focus.focus_force(2)  # _FOCUS_LIST
    _ = ed.handle_key(_key(UInt32(ord("p"))))
    assert_equal(ed._list.selected, 2)
    assert_equal(ed.argv_tf.text, String("pyright"))


def test_language_editor_move_candidate_reorders() raises:
    """Up/Down buttons swap the selected entry with its neighbour,
    keeping the cursor on the just-moved row."""
    var ed = LanguageEditor()
    var argvs = List[String]()
    argvs.append(String("a"))
    argvs.append(String("b"))
    argvs.append(String("c"))
    ed.open(
        String("xyzlang"), List[String](), argvs^, False,
    )
    ed._list.selected = 0
    ed._move_candidate(1)
    assert_equal(ed.candidates[0], String("b"))
    assert_equal(ed.candidates[1], String("a"))
    assert_equal(ed._list.selected, 1)
    # Out-of-bounds is a no-op.
    ed._list.selected = 2
    ed._move_candidate(1)
    assert_equal(ed._list.selected, 2)
    assert_equal(ed.candidates[2], String("c"))


def test_template_include_at_extracts_quoted_path() raises:
    """Cmd+click on the filename inside a Django/Jinja template tag returns
    the quoted path; a click outside any tag-string returns empty."""
    var inc = String('{% include "core/offer/side_block.html" %}')
    # Column 12 is on the 'c' of the quoted path; anywhere inside works.
    assert_equal(
        template_include_at(inc, 12), String("core/offer/side_block.html")
    )
    assert_equal(
        template_include_at(inc, 25), String("core/offer/side_block.html")
    )
    # On the opening brace / bare tag body (not the string) → empty.
    assert_equal(template_include_at(inc, 0), String(""))
    assert_equal(template_include_at(inc, 2), String(""))
    # Single quotes and other tags work too.
    assert_equal(
        template_include_at(String("{% extends 'base.html' %}"), 13),
        String("base.html"),
    )
    # Quoted string inside a ``{{ }}`` expression.
    assert_equal(
        template_include_at(String('{{ foo|default:"x.html" }}'), 17),
        String("x.html"),
    )
    # A quoted string that is *not* inside a template tag is ignored.
    assert_equal(
        template_include_at(String('include "core/x.html"'), 12), String("")
    )
    # {% static ... %} works the same as include.
    assert_equal(
        template_include_at(
            String("{% static 'styles/external/index.css' %}"), 20
        ),
        String("styles/external/index.css"),
    )
    # A missing/unmatched closing quote must NOT drag the tag close (``%}``)
    # or trailing whitespace into the path (regression: opened ``index.css
    # %}`` as a filename).
    assert_equal(
        template_include_at(
            String("{% static 'styles/external/index.css %}"), 20
        ),
        String("styles/external/index.css"),
    )


def test_highlight_for_extension_recognizes_mojo() raises:
    """``fn``/``var`` are keywords, ``"hello"`` is a string, ``# note`` is a
    comment, ``42`` is a number — each gets its own attr."""
    var lines = _hl_lines(
        String("fn main() raises:"),
        String("    var s = \"hello\"  # note"),
        String("    var n = 42"),
    )
    var hls = highlight_for_extension(String("mojo"), lines)
    var saw_keyword_fn = False
    var saw_keyword_var = False
    var saw_keyword_raises = False
    var saw_string = False
    var saw_comment = False
    var saw_number = False
    for i in range(len(hls)):
        var h = hls[i]
        var kind_attr = h.attr
        if h.row == 0 and h.col_start == 0 and h.col_end == 2 \
                and kind_attr == highlight_keyword_attr():
            saw_keyword_fn = True
        if h.row == 0 and kind_attr == highlight_keyword_attr() \
                and h.col_start == 10 and h.col_end == 16:
            saw_keyword_raises = True
        if h.row == 1 and h.col_start == 4 and h.col_end == 7 \
                and kind_attr == highlight_keyword_attr():
            saw_keyword_var = True
        if h.row == 1 and kind_attr == highlight_string_attr():
            saw_string = True
        if h.row == 1 and kind_attr == highlight_comment_attr():
            saw_comment = True
        if h.row == 2 and kind_attr == highlight_number_attr():
            saw_number = True
    assert_true(saw_keyword_fn)
    assert_true(saw_keyword_var)
    assert_true(saw_keyword_raises)
    assert_true(saw_string)
    assert_true(saw_comment)
    assert_true(saw_number)


def test_highlight_triple_quoted_string_spans_lines() raises:
    """Multi-line triple-quoted strings keep highlight state across rows.
    A docstring (triple-quoted string at statement position) is painted
    with the comment attr; an inline triple-quoted string keeps the
    string attr."""
    var lines = _hl_lines(
        String("\"\"\"docstring start"),
        String("middle line"),
        String("end of docstring\"\"\""),
        String("def f(): pass"),
    )
    var hls = highlight_for_extension(String("py"), lines)
    var have_row_0 = False
    var have_row_1 = False
    var have_row_2 = False
    for i in range(len(hls)):
        if hls[i].attr == highlight_comment_attr():
            if hls[i].row == 0: have_row_0 = True
            if hls[i].row == 1: have_row_1 = True
            if hls[i].row == 2: have_row_2 = True
    assert_true(have_row_0)
    assert_true(have_row_1)
    assert_true(have_row_2)
    # Row 3 (``def f(): pass``) must come back to plain code: ``def`` is
    # a keyword. The previous version of this test used ``var x = 1``,
    # left over from when Python and Mojo shared a bespoke tokenizer
    # that recognized both keyword sets — Python's grammar (rightly)
    # has no notion of ``var``, so that line produced no keyword
    # highlights and silently broke the docstring-close check.
    var saw_kw = False
    for i in range(len(hls)):
        if hls[i].row == 3 and hls[i].attr == highlight_keyword_attr():
            saw_kw = True
    assert_true(saw_kw)

    # Inline triple-quoted string: not at statement position, stays a string.
    var inline = _hl_lines(String("s = \"\"\"hi\"\"\""))
    var ihls = highlight_for_extension(String("py"), inline)
    var saw_inline_string = False
    for i in range(len(ihls)):
        if ihls[i].attr == highlight_string_attr():
            saw_inline_string = True
    assert_true(saw_inline_string)


def test_highlight_unknown_extension_returns_empty() raises:
    var lines = _hl_lines(String("fn main():"), String("  pass"))
    var hls = highlight_for_extension(String("txt"), lines)
    assert_equal(len(hls), 0)


def test_highlight_rust_keywords_strings_comments() raises:
    """The generic registry-driven tokenizer paints C-family files with
    the same attr palette as the Mojo/Python path: a ``var`` keyword,
    ``"hi"`` string, ``// note`` line comment, ``42`` number. Routed
    through ``.zig`` (Zig is still on the generic path — no bundled
    TextMate grammar) so this test stays focused on the generic
    tokenizer, not the TextMate runtime."""
    var lines = _hl_lines(
        String("fn main() {"),
        String("    var s = \"hi\"  // note"),
        String("    var n = 42"),
        String("}"),
    )
    var hls = highlight_for_extension(String("zig"), lines)
    var saw_var_kw = False
    var saw_string = False
    var saw_comment = False
    var saw_number = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 1 and h.col_start == 4 and h.col_end == 7 \
                and h.attr == highlight_keyword_attr():
            saw_var_kw = True
        if h.row == 1 and h.attr == highlight_string_attr():
            saw_string = True
        if h.row == 1 and h.attr == highlight_comment_attr():
            saw_comment = True
        if h.row == 2 and h.attr == highlight_number_attr():
            saw_number = True
    assert_true(saw_var_kw)
    assert_true(saw_string)
    assert_true(saw_comment)
    assert_true(saw_number)


def test_highlight_rust_block_comment_spans_lines() raises:
    """A ``/* ... */`` block comment that opens on one row and closes on
    a later row keeps every row in between painted as comment. State is
    threaded through ``_highlight_generic`` the same way triple-quoted
    strings are threaded through the Mojo/Python tokenizer. Targets
    a generic-path extension to keep this test off the TextMate route.

    Zig doesn't actually have ``/* ... */`` block comments, but the
    spec's ``block_open``/``block_close`` are empty for Zig. Use the
    ``.cpp``... wait, ``.cpp`` now goes through TextMate too. Use
    ``.kt`` (Kotlin) — generic-path C-family with ``/*..*/``."""
    var lines = _hl_lines(
        String("/* opening line"),
        String("middle line"),
        String("end */ var x = 1"),
    )
    var hls = highlight_for_extension(String("kt"), lines)
    var have_0 = False
    var have_1 = False
    var have_2 = False
    for i in range(len(hls)):
        if hls[i].attr == highlight_comment_attr():
            if hls[i].row == 0: have_0 = True
            if hls[i].row == 1: have_1 = True
            if hls[i].row == 2: have_2 = True
    assert_true(have_0)
    assert_true(have_1)
    assert_true(have_2)
    # Past the closing ``*/`` the tokenizer must be back to normal: ``let``
    # comes back as a keyword and ``1`` as a number.
    var saw_let = False
    var saw_number = False
    for i in range(len(hls)):
        if hls[i].row == 2 and hls[i].attr == highlight_keyword_attr():
            saw_let = True
        if hls[i].row == 2 and hls[i].attr == highlight_number_attr():
            saw_number = True
    assert_true(saw_let)
    assert_true(saw_number)


def test_onig_basic_search() raises:
    """Sanity-check the libonig FFI: compile a regex and find a match.
    This is the foundation the TextMate-grammar highlighter will sit
    on top of — if it breaks we want a clear test failure, not a
    cryptic crash inside the grammar runtime."""
    onig_global_init()
    var rx = OnigRegex(String("hel+o"))
    var m = rx.search(String("say hellllo world"))
    var got = False
    if m:
        got = True
        assert_equal(m.value().start, 4)
        assert_equal(m.value().end, 11)
    assert_true(got)


def test_onig_no_match_returns_none() raises:
    """The Optional API surfaces no-match as ``None`` (not as a
    sentinel match with ``start < 0``), matching the rest of the
    codebase's error idioms."""
    onig_global_init()
    var rx = OnigRegex(String("xyz+"))
    var m = rx.search(String("abc def"))
    var got = False
    if m:
        got = True
    assert_true(not got)


def test_onig_search_at_offset() raises:
    """``search_at(start)`` skips the first match if it falls before
    ``start`` — this is what the grammar runtime needs for ``\\G``
    continuation in ``begin``/``while`` rules."""
    onig_global_init()
    var rx = OnigRegex(String("ab"))
    var hay = String("abXYZab")
    var first = rx.search(hay)
    var first_ok = False
    if first:
        first_ok = True
        assert_equal(first.value().start, 0)
    assert_true(first_ok)
    var second = rx.search_at(hay, 1)
    var second_ok = False
    if second:
        second_ok = True
        assert_equal(second.value().start, 5)
    assert_true(second_ok)


def test_textmate_rust_grammar_paints_keywords_and_strings() raises:
    """Loading the bundled Rust TextMate grammar and tokenizing a
    small snippet produces keyword / string / comment / number
    highlights at the expected scopes. This is the integration test
    that proves the JSON loader, the regex FFI, the tokenizer, and
    the scope→Attr mapping all line up.

    We assert presence (at least one of each kind) rather than exact
    span offsets — those will shift as the bundled grammar grows.
    """
    var lines = _hl_lines(
        String("fn main() {"),
        String("    let s = \"hi\";  // note"),
        String("    let n = 42;"),
        String("}"),
    )
    var hls = highlight_for_extension(String("rs"), lines)
    var saw_keyword = False
    var saw_string = False
    var saw_comment = False
    var saw_number = False
    for i in range(len(hls)):
        var a = hls[i].attr
        if a == highlight_keyword_attr():
            saw_keyword = True
        if a == highlight_string_attr():
            saw_string = True
        if a == highlight_comment_attr():
            saw_comment = True
        if a == highlight_number_attr():
            saw_number = True
    assert_true(saw_keyword)
    assert_true(saw_string)
    assert_true(saw_comment)
    assert_true(saw_number)


def test_highlight_rst_grammar_paints_common_constructs() raises:
    """Smoke test for the bundled rST TextMate grammar. Asserts
    presence of the four attr kinds the grammar exposes through scope
    mapping: section adornment (keyword), directive name (ident),
    inline literal (string), and comment line (comment). Span offsets
    aren't asserted — they'd churn with grammar tweaks."""
    var lines = _hl_lines(
        String("Section Title"),
        String("============="),
        String(""),
        String(".. note:: a directive argument"),
        String(""),
        String(".. a plain rST comment"),
        String(""),
        String("This is ``inline literal`` text."),
    )
    var hls = highlight_for_extension(String("rst"), lines)
    var saw_heading = False
    var saw_directive_ident = False
    var saw_literal = False
    var saw_comment = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 1 and h.attr == highlight_keyword_attr():
            saw_heading = True
        if h.row == 3 and h.attr == highlight_ident_attr():
            saw_directive_ident = True
        if h.row == 5 and h.attr == highlight_comment_attr():
            saw_comment = True
        if h.row == 7 and h.attr == highlight_string_attr():
            saw_literal = True
    assert_true(saw_heading)
    assert_true(saw_directive_ident)
    assert_true(saw_comment)
    assert_true(saw_literal)


def test_textmate_brackets_paint_as_operators() raises:
    """``()`` / ``[]`` / ``{}`` must be painted with the operator attr
    in TextMate-tokenized files. The vendored Python grammar doesn't
    tag brackets at all, so without the post-pass they fall through
    uncolored — the bug this test guards against.

    We assert positively (each bracket has an operator highlight) and
    negatively (a bracket inside a string keeps the string color, not
    the operator color)."""
    var lines = _hl_lines(
        String("def f(a, b): return a + [1, 2, 3][0]"),
        String("s = \"(not an operator)\""),
    )
    var hls = highlight_for_extension(String("py"), lines)
    var op_attr = highlight_operator_attr()
    var str_attr = highlight_string_attr()
    var line0 = lines[0]
    var b0 = line0.as_bytes()
    # Every bracket on row 0 outside any string scope: ``(``, ``)``,
    # ``[`` (after ``+``), ``]``, ``[`` (the index), ``]`` (the index).
    # Last-writer wins (mirrors how the editor paints overlapping
    # highlights) so we walk all matches and keep the latest.
    for i in range(len(b0)):
        var c = Int(b0[i])
        if c != 0x28 and c != 0x29 and c != 0x5B and c != 0x5D \
                and c != 0x7B and c != 0x7D:
            continue
        var got = Attr(0, 0)
        var found = False
        for hi in range(len(hls)):
            var h = hls[hi]
            if h.row == 0 and h.col_start <= i and i < h.col_end:
                got = h.attr
                found = True
        assert_true(found)
        assert_true(got == op_attr)

    # Row 1 has ``"(not an operator)"`` — the parens are inside the
    # string scope and should keep the string color (we don't
    # overpaint inside strings).
    var line1 = lines[1]
    var b1 = line1.as_bytes()
    for i in range(len(b1)):
        var c = Int(b1[i])
        if c != 0x28 and c != 0x29:
            continue
        var got = Attr(0, 0)
        var found = False
        for hi in range(len(hls)):
            var h = hls[hi]
            if h.row == 1 and h.col_start <= i and i < h.col_end:
                got = h.attr
                found = True
        assert_true(found)
        assert_true(got == str_attr)


def test_textmate_incremental_matches_full_retokenize() raises:
    """The incremental tokenizer must match a full re-run for the same buffer + dirty-row hint.

    We exercise both shapes of edit:

    * a token-level change (adding a comment to one line) — tokenizer
      state at end of the line is unchanged, early-exit fires
      immediately.
    * a scope-changing change (opening a block comment that doesn't
      close on the same line) — tokenizer state changes, and the
      incremental path keeps re-tokenizing until either the state
      rejoins the cached trajectory or the buffer ends.

    In both cases the resulting Highlight list should be byte-for-byte
    identical to a full retokenize of the same buffer.
    """
    var lines = List[String]()
    lines.append(String("fn main() {"))
    lines.append(String("    let s = \"hello\";"))
    lines.append(String("    let n = 42;"))
    lines.append(String("    return;"))
    lines.append(String("}"))
    lines.append(String(""))
    lines.append(String("fn other() { 1 }"))

    # Warm the registry + per-Editor state with a full pass.
    var registry = GrammarRegistry()
    var cache = HighlightCache()
    var _ = highlight_incremental(
        String("rs"), lines, 0, registry, cache,
    )

    # Token-level edit on row 1: append a line comment.
    lines[1] = lines[1] + String(" // note")
    var incr_a = highlight_incremental(
        String("rs"), lines, 1, registry, cache,
    )
    var full_a = highlight_for_extension(String("rs"), lines)
    var s_incr_a = _hl_set(incr_a)
    var s_full_a = _hl_set(full_a)
    assert_equal(len(s_incr_a), len(s_full_a))
    for i in range(len(s_incr_a)):
        assert_equal(s_incr_a[i].row, s_full_a[i].row)
        assert_equal(s_incr_a[i].col_start, s_full_a[i].col_start)
        assert_equal(s_incr_a[i].col_end, s_full_a[i].col_end)

    # Scope-changing edit on row 2: open a block comment that the
    # rest of the buffer is now inside.
    lines[2] = String("    /* let n = 42;")
    var incr_b = highlight_incremental(
        String("rs"), lines, 2, registry, cache,
    )
    var full_b = highlight_for_extension(String("rs"), lines)
    var s_incr_b = _hl_set(incr_b)
    var s_full_b = _hl_set(full_b)
    assert_equal(len(s_incr_b), len(s_full_b))
    for i in range(len(s_incr_b)):
        assert_equal(s_incr_b[i].row, s_full_b[i].row)
        assert_equal(s_incr_b[i].col_start, s_full_b[i].col_start)
        assert_equal(s_incr_b[i].col_end, s_full_b[i].col_end)


def test_textmate_incremental_in_place_multirow_edit() raises:
    """An in-place multi-row edit (toggle-comment over a selection) must
    re-tokenize *every* edited row, not just the first.

    Regression: a single-line comment returns the tokenizer to the base
    stack right after the first commented row, so the post-stack
    early-exit used to fire there and splice the cached (uncommented)
    highlights over the rows below. ``dirty_max_row`` (fed from
    ``Editor._mark_hl_dirty(sr, er)``) is the high-water mark that keeps
    the early-exit suppressed until all edited rows are re-colored.

    Both the dirty-row hint *and* the high-water mark match what
    ``toggle_comment`` passes; the incremental result must equal a full
    retokenize. We also assert that omitting the high-water mark
    reproduces the bug (mismatch), so the test fails if the suppression
    is ever dropped.
    """
    # The commented block starts at row 2 so the incremental path
    # actually engages: ``eff_dirty = dirty_row - 1`` must be > 0, so a
    # comment starting at row 1 would collapse to a full retokenize and
    # never reach the early-exit being tested.
    var lines = List[String]()
    lines.append(String("fn main() {"))
    lines.append(String("    let z = 0;"))
    lines.append(String("    let a = 1;"))
    lines.append(String("    let b = 2;"))
    lines.append(String("    let c = 3;"))
    lines.append(String("}"))

    # Warm two independent per-Editor caches identically. The registry
    # (grammar load) is process-shared and safe to reuse.
    var registry = GrammarRegistry()
    var cache_fixed = HighlightCache()
    var cache_buggy = HighlightCache()
    var _ = highlight_incremental(String("rs"), lines, 0, registry, cache_fixed)
    var _ = highlight_incremental(String("rs"), lines, 0, registry, cache_buggy)

    # Comment rows 2..4 in place — no line-count change, so the
    # incremental path stays engaged (a line-count change would force a
    # full retokenize and mask the bug).
    lines[2] = String("    // let a = 1;")
    lines[3] = String("    // let b = 2;")
    lines[4] = String("    // let c = 3;")

    var full = highlight_for_extension(String("rs"), lines)
    var s_full = _hl_set(full)

    # With the high-water mark (er == 4): every commented row re-colored.
    var incr_fixed = highlight_incremental(
        String("rs"), lines, 2, registry, cache_fixed, 4,
    )
    var s_fixed = _hl_set(incr_fixed)
    assert_equal(len(s_fixed), len(s_full))
    for i in range(len(s_fixed)):
        assert_equal(s_fixed[i].row, s_full[i].row)
        assert_equal(s_fixed[i].col_start, s_full[i].col_start)
        assert_equal(s_fixed[i].col_end, s_full[i].col_end)

    # Without it (the old behaviour): the early-exit fires at row 1 and
    # the lower commented rows keep stale highlights, so the counts must
    # differ. Guards against silently dropping the suppression.
    var incr_buggy = highlight_incremental(
        String("rs"), lines, 2, registry, cache_buggy,
    )
    var s_buggy = _hl_set(incr_buggy)
    assert_true(len(s_buggy) != len(s_full))


def test_textmate_html_embeds_css_inside_style_block() raises:
    """The HTML grammar's ``<style>`` block embeds CSS via
    ``include: "source.css"`` inside a ``(?!\\G)``-gated begin/end.
    Our loader follows the include into the bundled CSS grammar
    (``_path_for_scope`` mapping); our tokenizer's ``\\G``-anchor
    handling makes the ``(?!\\G)`` fire on a fresh line so the CSS
    body actually gets tokenized.

    Verifies end-to-end: a CSS-body line inside ``<style>`` should
    produce more highlights than the surrounding ``<style>`` /
    ``</style>`` tag-only rows, indicating CSS grammar patterns
    fired against the body.
    """
    # Standalone CSS sanity check.
    var css_lines = List[String]()
    css_lines.append(String(".cls { color: red; }"))
    var css_hls = highlight_for_extension(String("css"), css_lines)
    assert_true(len(css_hls) > 0)

    # HTML with an embedded CSS body. The body row should pick up
    # CSS-grammar highlights via the embed.
    var html_lines = List[String]()
    html_lines.append(String("<style>"))
    html_lines.append(String("  .cls { color: red; }"))
    html_lines.append(String("</style>"))
    var html_hls = highlight_for_extension(String("html"), html_lines)
    var row1_count = 0
    for i in range(len(html_hls)):
        if html_hls[i].row == 1:
            row1_count += 1
    # The body line gets multiple highlights from the CSS grammar
    # (selector, property, value, punctuation, etc.). A handful is
    # plenty to prove the embed fires; lots more is expected. We
    # don't pin to a specific count because the bundled grammar's
    # exact tokenization can shift across grammar updates.
    assert_true(row1_count >= 4)


def test_django_template_overlay_fills_embedded_tags() raises:
    """``_apply_django_template_overlay`` paints Django template tags
    (``{{ }}`` / ``{% %}`` / ``{# #}``) the base grammar left uncoloured.
    This is what gives ``<style>`` / ``<script>`` blocks in Django
    templates their template-tag tinting: the CSS/JS grammar embedded
    under ``source.css.django`` / ``source.js`` can't reach a tag once
    its own ``{ }`` context is open (we don't do TextMate injection), so
    the overlay fills the gap. Tags the grammar already coloured (the
    HTML surface) are skipped so its finer per-token tinting survives.
    """
    var lines = List[String]()
    # row 0: a tag nested inside a CSS declaration value — the case the
    # grammar can't reach. The leading ``{`` (CSS block open) must NOT be
    # mistaken for a tag opener.
    lines.append(String(".cls { color: {{ theme }}; }"))
    lines.append(String("{% if dark %}"))            # row 1: block tag
    lines.append(String("/* {# note #} */"))         # row 2: django comment

    # No pre-existing highlights cover the tags (CSS left them plain).
    var hls = List[Highlight]()
    _apply_django_template_overlay(String("django-html"), lines, hls)

    var saw_var = False
    var saw_tag = False
    var saw_comment = False
    var saw_block_open = False
    for i in range(len(hls)):
        var h = hls[i]
        # ``{{ theme }}`` begins at byte 14 in ``.cls { color: {{...``.
        if h.row == 0 and h.attr == highlight_keyword_attr() \
                and h.col_start == 14 and h.col_end == 25:
            saw_var = True
        # The CSS block-open ``{`` at byte 5 must not be coloured.
        if h.row == 0 and h.col_start == 5:
            saw_block_open = True
        if h.row == 1 and h.attr == highlight_keyword_attr() \
                and h.col_start == 0:
            saw_tag = True
        if h.row == 2 and h.attr == highlight_comment_attr():
            saw_comment = True
    assert_true(saw_var)
    assert_true(saw_tag)
    assert_true(saw_comment)
    assert_true(not saw_block_open)

    # A tag the grammar already coloured (keyword on its opener) is left
    # alone — the overlay appends nothing, preserving the grammar's tint.
    var html_lines = List[String]()
    html_lines.append(String("<a>{{ x }}</a>"))      # ``{{`` at byte 3
    var html_hls = List[Highlight]()
    html_hls.append(Highlight(0, 3, 10, highlight_keyword_attr()))
    _apply_django_template_overlay(String("django-html"), html_lines, html_hls)
    assert_equal(len(html_hls), 1)

    # Non-django languages are a no-op (plain CSS keeps its ``{{`` plain).
    var other = List[Highlight]()
    _apply_django_template_overlay(String("css"), lines, other)
    assert_equal(len(other), 0)


def test_textmate_capture_patterns_run_inside_group() raises:
    """A ``captures`` entry that carries its own ``patterns`` array
    re-tokenizes the captured byte range. We exercise this with a
    string literal grammar that captures the body of a quoted
    string and runs an escape-sequence pattern over it."""
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        "{\"match\": \"\\\"([^\\\"]*)\\\"\", "
        "\"name\": \"string.quoted.test\", "
        "\"captures\": {"
        "\"1\": {"
        "\"name\": \"string.body.test\", "
        "\"patterns\": ["
        "{\"match\": \"\\\\\\\\.\", \"name\": \"constant.character.escape.test\"}"
        "]"
        "}"
        "}}], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("\"a\\nb\""))
    var hls = tokenize_with_grammar(g, lines)
    # Expect: outer string scope spans the whole match (col 0..6),
    # plus an escape-character highlight at col 2..4 for the ``\n``.
    var saw_outer_string = False
    var saw_escape = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.col_start == 0 and h.col_end == 6 \
                and h.attr == highlight_string_attr():
            saw_outer_string = True
        # ``constant.character.*`` maps to string_attr in our scope
        # mapping. The escape's col range (col 2..4 = ``\n``) lies
        # *inside* the outer string's range; the test only cares
        # that the escape's specific Highlight got emitted.
        if h.col_start == 2 and h.col_end == 4 \
                and h.attr == highlight_string_attr():
            saw_escape = True
    assert_true(saw_outer_string)
    assert_true(saw_escape)


def test_textmate_comment_marker_and_covered_brackets() raises:
    """Guard two regressions seen with embedded-grammar bodies.

    Both show up with JS inside an HTML ``<script>``; reproduced here
    with a self-contained grammar:

    1. A comment *marker* scoped ``punctuation.definition.comment`` must
       read as comment, not as the generic ``punctuation``→operator. The
       ``//`` of a line comment used to get an operator highlight painted
       on top of the comment body.
    2. A bracket sitting under an *unnamed* begin span (which paints the
       identifier fallback over the whole construct, as ``if (`` does)
       must still pick up the operator color. The fallback ident paint
       used to count as "covered" and suppress the bracket post-pass.
    """
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        # Line comment: body scoped comment.line, the ``//`` marker
        # scoped punctuation.definition.comment via capture group 1.
        "{\"match\": \"(//).*$\", "
        "\"name\": \"comment.line.double-slash.test\", "
        "\"captures\": {\"1\": {\"name\": \"punctuation.definition.comment.test\"}}}, "
        # ``if (`` opens an UNNAMED begin/end; only ``if`` is captured as
        # a keyword, so the begin span paints the ident fallback over the
        # ``(``, and the unnamed ``)`` end span does the same.
        "{\"begin\": \"\\\\b(if)\\\\s*\\\\(\", "
        "\"beginCaptures\": {\"1\": {\"name\": \"keyword.control.test\"}}, "
        "\"end\": \"\\\\)\"}"
        "], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("if (x)"))
    lines.append(String("// hi"))
    var hls = tokenize_with_grammar(g, lines)

    var op_attr = highlight_operator_attr()
    var comment_attr = highlight_comment_attr()

    # Row 0: both ``(`` (col 3) and ``)`` (col 5) must end up operator.
    # Last-writer wins, mirroring how the editor paints overlaps.
    def last_attr(hls: List[Highlight], row: Int, col: Int) -> Attr:
        var got = Attr(0, 0)
        for hi in range(len(hls)):
            var h = hls[hi]
            if h.row == row and h.col_start <= col and col < h.col_end:
                got = h.attr
        return got

    assert_true(last_attr(hls, 0, 3) == op_attr)
    assert_true(last_attr(hls, 0, 5) == op_attr)

    # Row 1: the ``//`` marker (cols 0,1) must be comment-colored, not
    # operator. The comment body must be comment-colored too.
    assert_true(last_attr(hls, 1, 0) == comment_attr)
    assert_true(last_attr(hls, 1, 1) == comment_attr)
    assert_true(last_attr(hls, 1, 3) == comment_attr)


def test_textmate_while_rule_keeps_scope_open_per_line() raises:
    """``while``-rules: a ``begin`` opens a scope that stays open for
    every subsequent line whose start matches the ``while`` regex.
    Markdown blockquotes use this — every line beginning with ``>``
    is part of the quote, the first line that doesn't ends it.

    Hand-rolled grammar so we don't depend on an external grammar's
    quirks."""
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        "{\"begin\": \"^>\", \"while\": \"^>\", "
        "\"name\": \"markup.quote.test\", "
        "\"patterns\": ["
        "{\"match\": \"\\\\w+\", \"name\": \"keyword.control.test\"}"
        "]}], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("> first quoted line"))
    lines.append(String("> second quoted line"))
    lines.append(String("not in quote"))
    var hls = tokenize_with_grammar(g, lines)
    # Every quoted line should have the ``markup.quote`` scope painted
    # somewhere in its range. We map ``markup.*`` to the ident attr in
    # the bundled scope mapping (no specific markup mapping yet), but
    # the keyword patterns inside the quote should still highlight.
    var saw_kw_in_quote_0 = False
    var saw_kw_in_quote_1 = False
    var saw_kw_outside = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.attr == highlight_keyword_attr():
            if h.row == 0:
                saw_kw_in_quote_0 = True
            elif h.row == 1:
                saw_kw_in_quote_1 = True
            elif h.row == 2:
                saw_kw_outside = True
    assert_true(saw_kw_in_quote_0)
    assert_true(saw_kw_in_quote_1)
    # Row 2 is outside the quote; the ``keyword`` pattern is nested
    # inside the begin/while scope, so it should *not* have fired
    # there.
    assert_true(not saw_kw_outside)


def test_textmate_end_backreferences_begin_capture() raises:
    """An ``end`` regex may back-reference a *begin* capture group via
    ``\\1``..``\\9`` — TextMate splices the begin match's captured text
    into the end pattern before matching. The django HTML grammar leans
    on this (``begin: "(<)([a-zA-Z0-9:]++)..."``, ``end: "(>)(<)(/)(\\2)(>)"``)
    to close a same-line ``<tag>...</tag>``. libonig can't resolve the
    cross-regex backref on its own, so without our substitution the end
    never matches: the region stays open and poisons every line below it.

    Hand-rolled grammar: ``<tag>`` opens ``meta.tag.test`` and ``</tag>``
    (the ``\\2`` resolves to the tag name) closes it. A ``keyword.test``
    pattern lives at the root, so it only fires once the region has
    actually closed."""
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        "{\"begin\": \"(<)([a-z]+)>\", \"end\": \"(</)(\\\\2)(>)\", "
        "\"name\": \"meta.tag.test\"},"
        "{\"match\": \"\\\\bWORD\\\\b\", \"name\": \"keyword.test\"}"
        "], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("<div>WORD</div>"))
    lines.append(String("WORD"))
    var hls = tokenize_with_grammar(g, lines)
    # Row 1's ``WORD`` is outside any tag, so it must highlight as a
    # keyword — which only happens if ``</div>`` closed the region on
    # row 0. (With the backref unresolved the region would still be
    # open here and ``WORD`` would be swallowed by ``meta.tag.test``,
    # which has no inner patterns.)
    var saw_kw_row1 = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 1 and h.attr == highlight_keyword_attr():
            saw_kw_row1 = True
    assert_true(saw_kw_row1)

    # A *different* tag name must not be accepted as the close: the
    # substituted end is specific to the captured name. Here ``</span>``
    # can't close ``<div>``, so the region runs to EOF and row 1's
    # ``WORD`` stays unhighlighted.
    var lines2 = List[String]()
    lines2.append(String("<div>WORD</span>"))
    lines2.append(String("WORD"))
    var hls2 = tokenize_with_grammar(g, lines2)
    var saw_kw2_row1 = False
    for i in range(len(hls2)):
        var h = hls2[i]
        if h.row == 1 and h.attr == highlight_keyword_attr():
            saw_kw2_row1 = True
    assert_true(not saw_kw2_row1)


def test_textmate_captures_overlay_on_match() raises:
    """A pattern with ``captures`` should emit the outer match scope
    plus a refined per-capture scope inside it. We exercise this
    against a hand-rolled grammar so the assertion is independent
    of whatever the bundled vscode rust grammar happens to do.

    The grammar matches ``fn <name>`` with the ``fn`` keyword as
    capture 1 (``keyword.control``) and the function name as
    capture 2 (``entity.name.function``). Both should produce
    distinct highlights at distinct byte ranges."""
    var grammar_json = String(
        "{\"scopeName\": \"source.test\", \"patterns\": ["
        "{\"match\": \"(fn)\\\\s+(\\\\w+)\", "
        "\"name\": \"meta.function.test\", "
        "\"captures\": {"
        "\"1\": {\"name\": \"keyword.control.test\"}, "
        "\"2\": {\"name\": \"entity.name.function.test\"}"
        "}}], \"repository\": {}}"
    )
    var g = load_grammar_from_string(grammar_json)
    var lines = List[String]()
    lines.append(String("fn hello"))
    var hls = tokenize_with_grammar(g, lines)
    var keyword_at_0_2 = False
    var ident_at_3_8 = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 0 and h.col_start == 0 and h.col_end == 2 \
                and h.attr == highlight_keyword_attr():
            keyword_at_0_2 = True
        # ``entity.name.function`` maps to ident_attr in our scope
        # mapping; the function-name span is bytes 3..8.
        if h.row == 0 and h.col_start == 3 and h.col_end == 8 \
                and h.attr == highlight_ident_attr():
            ident_at_3_8 = True
    assert_true(keyword_at_0_2)
    assert_true(ident_at_3_8)


def test_textmate_eol_closes_frame_with_newline_end_pattern() raises:
    """Grammars use ``end: "\\n(?!\\s)"`` to close a scope at end-of-
    line unless the next line is an indented continuation (Elm/Haskell
    ``import``/``module``). Per-line tokenization never sees ``\\n``,
    so the tokenizer has an EOL post-pass that re-fires the top
    frame's end regex against ``line + "\\n" + next_line`` at byte
    ``n``. This test pins down both branches of that pass.

    Pre-fix the import frame stayed open forever and its inner
    patterns swallowed every later line — strings/keywords on row 2
    were left uncolored or painted with the wrong scope."""
    var grammar_json = String(
        "{\"scopeName\":\"source.test\",\"patterns\":["
        "{\"begin\":\"^\\\\b(import)\\\\s+\","
        "\"end\":\"\\\\n(?!\\\\s)\","
        "\"name\":\"meta.import.test\","
        "\"beginCaptures\":{\"1\":{\"name\":\"keyword.control.test\"}},"
        "\"patterns\":[{\"match\":\"[A-Z][A-Za-z0-9]*\","
        "\"name\":\"support.module.test\"}]},"
        "{\"match\":\"\\\\b(let)\\\\b\","
        "\"name\":\"keyword.control.test\"}"
        "],\"repository\":{}}"
    )
    var g = load_grammar_from_string(grammar_json)

    # Branch 1 — non-indented next line: import frame must close at
    # end of row 0. ``let`` on row 1 is a root-level keyword pattern
    # that's NOT inside the import frame's nested list, so it can
    # only fire from a clean root.
    var lines = List[String]()
    lines.append(String("import Foo"))
    lines.append(String("let x"))
    var hls = tokenize_with_grammar(g, lines)
    var saw_let_keyword = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 1 and h.col_start == 0 and h.col_end == 3 \
                and h.attr == highlight_keyword_attr():
            saw_let_keyword = True
    assert_true(saw_let_keyword)

    # Branch 2 — indented next line: ``\\n(?!\\s)`` lookahead fails
    # because the next line begins with whitespace, so the frame
    # stays open through row 1. ``let`` on row 2 (after the frame
    # finally closes at row 1's EOL) must still fire as a keyword.
    var lines2 = List[String]()
    lines2.append(String("import Foo"))
    lines2.append(String("    Bar"))
    lines2.append(String("let x"))
    var hls2 = tokenize_with_grammar(g, lines2)
    var saw_let_kw_row2 = False
    for i in range(len(hls2)):
        var h = hls2[i]
        if h.row == 2 and h.col_start == 0 and h.col_end == 3 \
                and h.attr == highlight_keyword_attr():
            saw_let_kw_row2 = True
    assert_true(saw_let_kw_row2)


def test_textmate_all_bundled_grammars_load() raises:
    """Every grammar bundled under ``src/turbokod/grammars/`` should
    parse, compile its regexes through libonig, and produce *some*
    highlights for a tiny representative snippet. This catches
    breakages from grammar updates that introduce regex syntax
    libonig rejects, or pattern shapes our runtime doesn't handle.

    The assertion is intentionally loose — we just want non-empty
    output, not specific scopes — so adding a new grammar doesn't
    require a hand-tuned test alongside it."""
    # extension, sample-line that should produce at least one highlight.
    var probes = List[Tuple[String, String]]()
    probes.append((String("rs"),   String("fn main() {}")))
    probes.append((String("go"),   String("package main")))
    probes.append((String("ts"),   String("const x: number = 1;")))
    probes.append((String("js"),   String("const x = 1;")))
    probes.append((String("cpp"),  String("int main() { return 0; }")))
    probes.append((String("sh"),   String("if [ -f x ]; then echo y; fi")))
    probes.append((String("html"), String("<html><body>hi</body></html>")))
    probes.append((String("css"),  String(".cls { color: red; }")))
    probes.append((String("json"), String("{\"a\": 1}")))
    probes.append((String("diff"), String("-removed line")))
    # ``while``-rule grammars: now wired through our runtime once
    # ``PATTERN_BEGIN_WHILE`` was added. Light smoke probes — the
    # while-rule semantics get a dedicated test below.
    probes.append((String("rb"),   String("def hi; \"hi\"; end")))
    probes.append((String("yaml"), String("key: value")))
    for i in range(len(probes)):
        var ext = probes[i][0]
        var sample = probes[i][1]
        var lines = List[String]()
        lines.append(sample)
        var hls = highlight_for_extension(ext, lines)
        # ``len(hls) > 0`` is the loose contract: each grammar's
        # snippet was hand-picked to contain at least one obviously
        # colorable token (keyword, string, comment, etc.).
        if len(hls) == 0:
            print("no highlights produced for extension: " + ext)
        assert_true(len(hls) > 0)


def test_textmate_json_grammar_paints_strings_and_numbers() raises:
    """Adding a new language is just a grammar JSON drop-in plus an
    entry in ``_grammar_path_for_ext``. Verify the JSON grammar
    kicks in for ``.json`` files: keys + values render as strings,
    numeric literals as numbers, ``true`` / ``false`` as keywords."""
    var lines = _hl_lines(
        String("{"),
        String("  \"name\": \"value\","),
        String("  \"count\": 42,"),
        String("  \"flag\": true"),
        String("}"),
    )
    var hls = highlight_for_extension(String("json"), lines)
    var saw_string = False
    var saw_number = False
    var saw_keyword = False
    for i in range(len(hls)):
        var a = hls[i].attr
        if a == highlight_string_attr():
            saw_string = True
        if a == highlight_number_attr():
            saw_number = True
        if a == highlight_keyword_attr():
            saw_keyword = True
    assert_true(saw_string)
    assert_true(saw_number)
    assert_true(saw_keyword)


def test_textmate_css_declaration_values_are_tokenized() raises:
    """CSS property *values* — numbers, strings, comments — must color.

    Regression for two tokenizer bugs that left declaration values
    untouched:

    1. ``meta.property-name`` closes with a zero-width ``end``
       (``(?![-a-zA-Z])``) right on the ``:``. The empty-match guard
       used to bump ``pos`` one byte past a zero-width *end* pop the
       same way it does a zero-width plain match, swallowing the colon
       so the sibling property-value ``(:)\\s*`` begin never fired —
       the whole value (``24px``, ``"hello"``, …) went untokenized.
    2. A pushed ``string`` / ``comment`` frame nests under wrapper
       scopes (``meta.property-value.css`` …), so ``_emit_unmatched``
       prefix-matching the *whole* chain missed the inner scope and
       left string/comment bodies uncolored. It now walks the chain
       innermost-first.
    """
    var lines = _hl_lines(
        String("/* note */"),
        String(".foo {"),
        String("  width: 24px;"),
        String("  content: \"hello\";"),
        String("}"),
    )
    var hls = highlight_for_extension(String("css"), lines)

    # ``24px`` sits at cols 9-12 on row 2; its leading digits must
    # paint as a number.
    var saw_number = False
    # The string body ``hello`` sits at cols 12-16 on row 3.
    var saw_string_body = False
    # The block comment body on row 0.
    var saw_comment = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 2 and h.col_start <= 9 and h.col_end > 9:
            if h.attr == highlight_number_attr():
                saw_number = True
        if h.row == 3 and h.col_start <= 13 and h.col_end > 13:
            if h.attr == highlight_string_attr():
                saw_string_body = True
        if h.row == 0 and h.col_start <= 4 and h.col_end > 4:
            if h.attr == highlight_comment_attr():
                saw_comment = True
    assert_true(saw_number)
    assert_true(saw_string_body)
    assert_true(saw_comment)


def test_embedded_language_extensions_collects_unique_languages() raises:
    """``embedded_language_extensions`` should de-dup and return the
    extension for each ``language=NAME`` marker. Languages mapped to
    bundled extensions (e.g. ``html`` → ``html``) and languages
    mapped via the downloadable grammar registry (e.g. ``elm`` →
    ``elm``) both flow through the same lookup."""
    var lines = _hl_lines(
        String("# language=html"),
        String("a = \"<x/>\""),
        String("// language=css"),
        String("b = \".x{color:red}\""),
        # Duplicate marker — must not produce two ``html`` entries.
        String("# language=html"),
        String("c = \"<y/>\""),
        # Language-id from the downloadable registry: maps to the
        # spec's first file_type (``elm``).
        String("# language=elm"),
        String("d = \"main = 1\""),
    )
    var exts = embedded_language_extensions(lines)
    var saw_html = False
    var saw_css = False
    var saw_elm = False
    var html_count = 0
    for i in range(len(exts)):
        if exts[i] == String("html"):
            saw_html = True
            html_count += 1
        if exts[i] == String("css"):
            saw_css = True
        if exts[i] == String("elm"):
            saw_elm = True
    assert_true(saw_html)
    assert_true(saw_css)
    assert_true(saw_elm)
    assert_equal(html_count, 1)


def test_embedded_language_extensions_skips_unknown_languages() raises:
    """An ``unknown`` language with no entry in ``_ext_for_language``
    and no downloadable spec should be silently dropped — the
    install prompt only knows how to act on extensions in the
    grammar catalog."""
    var lines = _hl_lines(
        String("# language=brainfuck"),
        String("prog = \"+++[->+<]\""),
    )
    var exts = embedded_language_extensions(lines)
    assert_equal(len(exts), 0)


def test_textmate_rust_block_comment_spans_lines() raises:
    """The TextMate runtime threads its scope stack across lines, so
    a ``/* ... */`` that opens on one line and closes on a later one
    paints every row in between as comment. This is the same
    behavior as the generic tokenizer's ``_HL_IN_BLOCK_COMMENT``
    state, but driven by the grammar's begin/end pattern."""
    var lines = _hl_lines(
        String("/* outer"),
        String("middle"),
        String("end */ let x = 1;"),
    )
    var hls = highlight_for_extension(String("rs"), lines)
    var have_0 = False
    var have_1 = False
    var have_2_comment = False
    var have_2_keyword = False
    for i in range(len(hls)):
        if hls[i].attr == highlight_comment_attr():
            if hls[i].row == 0: have_0 = True
            if hls[i].row == 1: have_1 = True
            if hls[i].row == 2: have_2_comment = True
        if hls[i].row == 2 and hls[i].attr == highlight_keyword_attr():
            have_2_keyword = True
    assert_true(have_0)
    assert_true(have_1)
    assert_true(have_2_comment)
    assert_true(have_2_keyword)


def test_onig_invalid_pattern_raises() raises:
    """A malformed pattern surfaces as a ``raise`` from the
    constructor, with libonig's nonzero rc embedded in the message —
    enough to grep the source."""
    onig_global_init()
    var raised = False
    try:
        var _rx = OnigRegex(String("(unclosed"))
    except:
        raised = True
    assert_true(raised)


def test_language_registry_loads_from_bundled_json() raises:
    """The catalog imported from Helix's languages.toml should load cleanly
    and contain at least the long-tail languages we now expect."""
    var specs = built_in_servers()
    # Catalog isn't tiny — sanity-check the lower bound rather than a
    # specific count so refreshes don't break this test.
    assert_true(len(specs) > 50)

    # Elm regression: pre-import the registry didn't contain Elm at all.
    var elm_idx = find_language_by_id(specs, String("elm"))
    assert_true(elm_idx >= 0)
    assert_true(len(specs[elm_idx].candidates) > 0)
    assert_equal(
        specs[elm_idx].candidates[0].argv[0],
        String("elm-language-server"),
    )

    # Extension routing for one of the curated entries with an install hint.
    var py_idx = find_language_for_extension(specs, String("py"))
    assert_true(py_idx >= 0)
    assert_equal(specs[py_idx].language_id, String("python"))
    assert_true(len(specs[py_idx].install_hint.as_bytes()) > 0)


def test_python_venv_dir_finds_dotvenv() raises:
    """``python_venv_dir`` returns the venv root when ``<root>/.venv``
    exists with a ``bin/python`` inside; an empty bare directory
    called ``venv`` (no ``bin/python``) doesn't count, so we don't
    mis-detect random folders just because of their name."""
    var root = _temp_path(String("_pyvenv_dir"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # No venv yet → empty (modulo an ambient $VIRTUAL_ENV in the test
    # runner; we only assert "not pointing at our root's venv").
    var no_venv = python_venv_dir(root)
    assert_true(no_venv != join_path(root, String(".venv")))
    assert_true(no_venv != join_path(root, String("venv")))
    # An empty ``venv`` dir without a ``bin/python`` shouldn't count.
    var bare_venv = join_path(root, String("venv"))
    _ = external_call["mkdir", Int32](
        (bare_venv + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var still_no_venv = python_venv_dir(root)
    assert_true(still_no_venv != bare_venv)
    # Drop a real ``.venv/bin/python`` and confirm the lookup finds it.
    var dot_venv = join_path(root, String(".venv"))
    _ = external_call["mkdir", Int32](
        (dot_venv + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var dot_bin = join_path(dot_venv, String("bin"))
    _ = external_call["mkdir", Int32](
        (dot_bin + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var dot_py = join_path(dot_bin, String("python"))
    assert_true(write_file(dot_py, String("#!/bin/sh\nexec /usr/bin/false\n")))
    assert_equal(python_venv_dir(root), dot_venv)
    # Cleanup.
    _ = external_call["unlink", Int32]((dot_py + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dot_bin + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dot_venv + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((bare_venv + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_python_debugger_spec_for_venv_prepends_venv_python() raises:
    """``python_debugger_spec_for_venv`` adds a ``<venv>/bin/python -m
    debugpy.adapter`` candidate at the front of the python spec's
    candidate list when ``<venv>/bin/python`` exists, leaving the
    PATH-resolved candidates as a fallback. Non-Python specs and
    empty venv dirs pass through untouched."""
    var specs = built_in_debuggers()
    var py_idx = find_debugger_for_language(specs, String("python"))
    assert_true(py_idx >= 0)
    var py_spec = specs[py_idx].copy()
    var orig_count = len(py_spec.candidates)
    # Empty venv → identity.
    var same = python_debugger_spec_for_venv(py_spec, String(""))
    assert_equal(len(same.candidates), orig_count)
    # Non-Python → identity even with a real-looking venv path.
    var go_idx = find_debugger_for_language(specs, String("go"))
    assert_true(go_idx >= 0)
    var go_same = python_debugger_spec_for_venv(
        specs[go_idx], String("/tmp/whatever"),
    )
    assert_equal(len(go_same.candidates), len(specs[go_idx].candidates))
    # Build a real venv layout and confirm a venv-resolved candidate
    # gets prepended.
    var root = _temp_path(String("_pyvenv_spec"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var bin_dir = join_path(root, String("bin"))
    _ = external_call["mkdir", Int32](
        (bin_dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var py = join_path(bin_dir, String("python"))
    assert_true(write_file(py, String("#!/bin/sh\nexec /usr/bin/false\n")))
    var adapted = python_debugger_spec_for_venv(py_spec, root)
    assert_true(len(adapted.candidates) > orig_count)
    # First candidate's argv[0] is the venv's python.
    assert_equal(adapted.candidates[0].argv[0], py)
    # Original candidates still tail the list as a fallback.
    assert_equal(
        adapted.candidates[len(adapted.candidates) - 1].argv[0],
        py_spec.candidates[len(py_spec.candidates) - 1].argv[0],
    )
    _ = external_call["unlink", Int32]((py + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((bin_dir + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_extract_path_line_links_pytest_style() raises:
    """Bare ``<path>:<N>`` (pytest / compiler convention) is detected,
    with the span covering exactly ``path:line`` and the right path +
    1-based line parsed out."""
    var hits = _extract_path_line_links(
        String("iommi/declarative/dispatch.py:123")
    )
    assert_equal(len(hits), 1)
    assert_equal(hits[0].path, String("iommi/declarative/dispatch.py"))
    assert_equal(hits[0].line, 123)
    assert_equal(hits[0].cell_start, 0)
    assert_equal(
        hits[0].cell_end,
        String("iommi/declarative/dispatch.py:123").byte_length(),
    )

    # Embedded in a sentence with a trailing ``:col`` — the link stops
    # after the line number; the column is not part of the span.
    var hits2 = _extract_path_line_links(
        String("  tests/test_foo.py:45:12: AssertionError")
    )
    assert_equal(len(hits2), 1)
    assert_equal(hits2[0].path, String("tests/test_foo.py"))
    assert_equal(hits2[0].line, 45)
    assert_equal(hits2[0].cell_start, 2)
    assert_equal(
        hits2[0].cell_end, 2 + String("tests/test_foo.py:45").byte_length()
    )

    # A bare filename (no slash) still works.
    var hits3 = _extract_path_line_links(String("conftest.py:7"))
    assert_equal(len(hits3), 1)
    assert_equal(hits3[0].path, String("conftest.py"))
    assert_equal(hits3[0].line, 7)


def test_extract_path_line_links_rejects_non_paths() raises:
    """Heuristics keep host:port, HH:MM and URLs from being underlined:
    the path token needs a dotted extension and no ``//``."""
    # No extension -> not a path.
    assert_equal(len(_extract_path_line_links(String("localhost:8080"))), 0)
    # Clock time -> the ``12`` token has no dot.
    assert_equal(len(_extract_path_line_links(String("12:30:45"))), 0)
    # URL -> double slash disqualifies it.
    assert_equal(
        len(_extract_path_line_links(String("http://example.com/x.py:9"))), 0
    )
    # Colon with no following digits is not a link.
    assert_equal(len(_extract_path_line_links(String("a/b.py: note"))), 0)


def test_html_to_text_basics() raises:
    """Tags strip cleanly, entities decode, ``<b>`` becomes ``**``, and
    paragraphs are separated by a blank line."""
    var rendered = html_to_text(String(
        "<p>Hello, <b>world</b>!</p>"
        + String("<p>Second &amp; line.</p>"),
    ))
    # ``<b>`` rendered as markdown bold around its content.
    var b = rendered.as_bytes()
    var marker = String("Hello, **world**!")
    var mb = marker.as_bytes()
    var found = False
    for i in range(len(b) - len(mb) + 1):
        var ok = True
        for k in range(len(mb)):
            if b[i + k] != mb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)
    # Entity decoded.
    var amp_marker = String("Second & line.")
    var ab = amp_marker.as_bytes()
    var amp_found = False
    for i in range(len(b) - len(ab) + 1):
        var ok = True
        for k in range(len(ab)):
            if b[i + k] != ab[k]:
                ok = False
                break
        if ok:
            amp_found = True
            break
    assert_true(amp_found)
    # Paragraphs separated by a blank line (``\n\n``) — that's the bit
    # the old non-markdown renderer was missing.
    var blank_marker = String("**!\n\nSecond")
    var blb = blank_marker.as_bytes()
    var blank_found = False
    for i in range(len(b) - len(blb) + 1):
        var ok = True
        for k in range(len(blb)):
            if b[i + k] != blb[k]:
                ok = False
                break
        if ok:
            blank_found = True
            break
    assert_true(blank_found)
    # No leftover '<' or '>' from tags.
    for i in range(len(b)):
        assert_true(b[i] != 0x3C and b[i] != 0x3E)


def test_html_to_text_headings_become_hashes() raises:
    """``<h1>`` -> ``#``, ``<h2>`` -> ``##``, … with a blank line below."""
    var rendered = html_to_text(String(
        "<h1>Title</h1><h2>Sub</h2><p>Body.</p>"
    ))
    var b = rendered.as_bytes()
    var want = String("# Title\n\n## Sub\n\nBody.")
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


def test_html_to_text_lists_and_inline() raises:
    """``<ul>`` items get ``- ``, ``<ol>`` items get ``1. ``,
    ``<code>`` becomes backticks, ``<a href>`` becomes
    ``[text](href)``."""
    var rendered = html_to_text(String(
        "<p>Try <a href=\"x.html\">this</a> or <code>foo</code>.</p>"
        + String("<ul><li>one</li><li>two</li></ul>")
        + String("<ol><li>first</li><li>second</li></ol>"),
    ))
    var b = rendered.as_bytes()
    # Inline link.
    var link_m = String("[this](x.html)")
    var lmb = link_m.as_bytes()
    var link_found = False
    for i in range(len(b) - len(lmb) + 1):
        var ok = True
        for k in range(len(lmb)):
            if b[i + k] != lmb[k]:
                ok = False
                break
        if ok:
            link_found = True
            break
    assert_true(link_found)
    # Inline code.
    var code_m = String("`foo`")
    var cmb = code_m.as_bytes()
    var code_found = False
    for i in range(len(b) - len(cmb) + 1):
        var ok = True
        for k in range(len(cmb)):
            if b[i + k] != cmb[k]:
                ok = False
                break
        if ok:
            code_found = True
            break
    assert_true(code_found)
    # ``<ul>`` items.
    var ul_m = String("- one\n- two")
    var umb = ul_m.as_bytes()
    var ul_found = False
    for i in range(len(b) - len(umb) + 1):
        var ok = True
        for k in range(len(umb)):
            if b[i + k] != umb[k]:
                ok = False
                break
        if ok:
            ul_found = True
            break
    assert_true(ul_found)
    # ``<ol>`` items numbered.
    var ol_m = String("1. first\n2. second")
    var omb = ol_m.as_bytes()
    var ol_found = False
    for i in range(len(b) - len(omb) + 1):
        var ok = True
        for k in range(len(omb)):
            if b[i + k] != omb[k]:
                ok = False
                break
        if ok:
            ol_found = True
            break
    assert_true(ol_found)


def test_html_to_text_pre_uses_fence() raises:
    """``<pre>`` blocks are wrapped in ```` ``` ```` fences while
    keeping their internal whitespace verbatim."""
    var rendered = html_to_text(String(
        "<p>before</p><pre>fn foo():\n    return 42</pre><p>after</p>"
    ))
    var b = rendered.as_bytes()
    var want = String("```\nfn foo():\n    return 42\n```")
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


def test_html_to_text_preserves_pre() raises:
    """``<pre>`` blocks must keep their internal whitespace verbatim —
    that's the whole point of code samples in the docs.

    We use a deliberately weird indent that a generic whitespace-collapse
    pass would mangle (two leading spaces, internal tab) so a regression
    that breaks the ``pre_depth`` branch shows up as a failed match.
    """
    var html = String(
        "<p>before</p><pre>  fn foo():\n\treturn 42</pre><p>after</p>"
    )
    var rendered = html_to_text(html)
    # The tab and leading two spaces survived.
    var marker = String("  fn foo():\n\treturn 42")
    var b = rendered.as_bytes()
    var mb = marker.as_bytes()
    var found = False
    for i in range(len(b) - len(mb) + 1):
        var ok = True
        for k in range(len(mb)):
            if b[i + k] != mb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


def test_html_to_text_strips_script_and_style() raises:
    """``<script>`` / ``<style>`` content must not leak into the
    rendered text. DevDocs HTML doesn't ship script tags, but vendored
    HTML from arbitrary doc sources sometimes does, and surfacing
    JavaScript verbatim in a doc viewer is jarring."""
    var rendered = html_to_text(String(
        "<p>Hi</p><script>alert('boom');</script><p>bye</p>",
    ))
    var b = rendered.as_bytes()
    var bad = String("alert")
    var bb = bad.as_bytes()
    var leaked = False
    for i in range(len(b) - len(bb) + 1):
        var ok = True
        for k in range(len(bb)):
            if b[i + k] != bb[k]:
                ok = False
                break
        if ok:
            leaked = True
            break
    assert_false(leaked)


def test_html_to_text_table_renders_as_gfm_table() raises:
    """``<table>`` becomes a GFM table: pipe-bordered rows, a separator
    after the first row, columns padded to the widest cell, and inline
    markup inside cells survives the recursive cell render. The earlier
    renderer just emitted tab-separated cells, which collapsed to a
    single illegible line in the doc pane.
    """
    # Inline markup, header row, multiple body rows, ragged cell widths.
    var rendered = html_to_text(String(
        "<p>Before.</p>"
        + String("<table>")
        + String("<tr><th>Function</th><th>Description</th></tr>")
        + String("<tr><td><code>abs(x)</code></td>")
        + String("<td>The <em>absolute</em> value of <strong>x</strong>.</td></tr>")
        + String("<tr><td><code>min(a)</code></td><td>min docs.</td></tr>")
        + String("</table>")
        + String("<p>After.</p>"),
    ))
    var want = String(
        "Before.\n\n"
        + String("| Function | Description                    |\n")
        + String("| -------- | ------------------------------ |\n")
        + String("| `abs(x)` | The *absolute* value of **x**. |\n")
        + String("| `min(a)` | min docs.                      |\n")
        + String("\nAfter."),
    )
    var b = rendered.as_bytes()
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


def test_html_to_text_table_escapes_pipes_in_cells() raises:
    """A literal ``|`` inside a cell would otherwise terminate the cell
    early and shift every column to its right; we escape as ``\\|``."""
    var rendered = html_to_text(String(
        "<table><tr><th>Op</th></tr><tr><td>a|b</td></tr></table>",
    ))
    var b = rendered.as_bytes()
    var want = String("| a\\|b |")
    var wb = want.as_bytes()
    var found = False
    for i in range(len(b) - len(wb) + 1):
        var ok = True
        for k in range(len(wb)):
            if b[i + k] != wb[k]:
                ok = False
                break
        if ok:
            found = True
            break
    assert_true(found)


def test_markdown_highlights_headings_code_and_emphasis() raises:
    """The bespoke Markdown highlighter colors ATX headings (keyword),
    fenced + inline code (string), and ``**bold**`` (bold style), where
    the generic fallback used to produce nothing at all."""
    var lines = _hl_lines(
        String("# Title"),
        String("Some **bold** and `code` text."),
        String("```"),
        String("x = 1"),
        String("```"),
        String("- item"),
        String("[link](http://example.com)"),
    )
    var hls = highlight_for_extension(String("md"), lines)
    # Heading: whole row 0 painted as keyword.
    var saw_heading = False
    var saw_bold = False
    var saw_inline_code = False
    var saw_fence_body = False
    var saw_list_marker = False
    var saw_link_url = False
    for i in range(len(hls)):
        var h = hls[i]
        if h.row == 0 and h.attr.fg == SYN_KEYWORD \
                and (h.attr.style & STYLE_BOLD) != 0:
            saw_heading = True
        if h.row == 1 and h.col_start == 5 and (h.attr.style & STYLE_BOLD) != 0:
            saw_bold = True
        if h.row == 1 and h.attr == highlight_string_attr() and h.col_start > 12:
            saw_inline_code = True
        # Row 3 ("x = 1") is inside the fence → whole-line code color.
        if h.row == 3 and h.col_start == 0 and h.col_end == 5 \
                and h.attr == highlight_string_attr():
            saw_fence_body = True
        if h.row == 5 and h.col_start == 0 and h.col_end == 1 \
                and h.attr == highlight_operator_attr():
            saw_list_marker = True
        if h.row == 6 and h.attr == highlight_string_attr():
            saw_link_url = True
    assert_true(saw_heading)
    assert_true(saw_bold)
    assert_true(saw_inline_code)
    assert_true(saw_fence_body)
    assert_true(saw_list_marker)
    assert_true(saw_link_url)


def test_markdown_fenced_code_uses_embedded_grammar() raises:
    """A ```` ```python ```` fence tokenizes its body with the Python
    TextMate grammar (same injection path as ``# language=`` markers),
    so ``def``/``return`` in the body come out as keywords and the
    literal ``1`` as a number — not the uniform fence-code color."""
    var lines = _hl_lines(
        String("Intro paragraph."),
        String("```python"),
        String("def f():"),
        String("    return 1"),
        String("```"),
    )
    var hls = highlight_for_extension(String("md"), lines)
    var saw_def_keyword = False
    var saw_number = False
    for i in range(len(hls)):
        var h = hls[i]
        # ``def`` on row 2: keyword color from the Python grammar.
        if h.row == 2 and h.col_start == 0 and h.col_end == 3 \
                and h.attr == highlight_keyword_attr():
            saw_def_keyword = True
        # The ``1`` on row 3: number color, proving the body was
        # tokenized as Python rather than painted as flat code.
        if h.row == 3 and h.attr == highlight_number_attr():
            saw_number = True
    assert_true(saw_def_keyword)
    assert_true(saw_number)


def main() raises:
    setup_test_env()
    test_grammar_install_command_targets_user_config()
    test_django_grammar_is_in_downloadable_catalog()
    test_grammar_registry_override_routes_to_alternate_grammar()
    test_highlight_for_extension_does_not_strand_its_grammar()
    test_grammar_registry_release_frees_and_leaves_the_engine_usable()
    test_released_regex_reports_no_match()
    test_grammar_registry_keeps_grammars_across_set_overrides()
    test_grammar_registry_override_change_reresolves_without_eviction()
    test_language_catalog_carries_comment_tokens()
    test_language_editor_save_emits_override()
    test_language_editor_paint_does_not_damage_dialog_border()
    test_language_editor_list_type_to_jump()
    test_language_editor_move_candidate_reorders()
    test_template_include_at_extracts_quoted_path()
    test_highlight_for_extension_recognizes_mojo()
    test_highlight_triple_quoted_string_spans_lines()
    test_highlight_unknown_extension_returns_empty()
    test_highlight_rust_keywords_strings_comments()
    test_highlight_rust_block_comment_spans_lines()
    test_onig_basic_search()
    test_onig_no_match_returns_none()
    test_onig_search_at_offset()
    test_textmate_rust_grammar_paints_keywords_and_strings()
    test_highlight_rst_grammar_paints_common_constructs()
    test_textmate_brackets_paint_as_operators()
    test_textmate_incremental_matches_full_retokenize()
    test_textmate_incremental_in_place_multirow_edit()
    test_textmate_html_embeds_css_inside_style_block()
    test_django_template_overlay_fills_embedded_tags()
    test_textmate_capture_patterns_run_inside_group()
    test_textmate_comment_marker_and_covered_brackets()
    test_textmate_while_rule_keeps_scope_open_per_line()
    test_textmate_end_backreferences_begin_capture()
    test_textmate_captures_overlay_on_match()
    test_textmate_eol_closes_frame_with_newline_end_pattern()
    test_textmate_all_bundled_grammars_load()
    test_textmate_json_grammar_paints_strings_and_numbers()
    test_textmate_css_declaration_values_are_tokenized()
    test_embedded_language_extensions_collects_unique_languages()
    test_embedded_language_extensions_skips_unknown_languages()
    test_textmate_rust_block_comment_spans_lines()
    test_onig_invalid_pattern_raises()
    test_language_registry_loads_from_bundled_json()
    test_python_venv_dir_finds_dotvenv()
    test_python_debugger_spec_for_venv_prepends_venv_python()
    test_extract_path_line_links_pytest_style()
    test_extract_path_line_links_rejects_non_paths()
    test_html_to_text_basics()
    test_html_to_text_headings_become_hashes()
    test_html_to_text_lists_and_inline()
    test_html_to_text_pre_uses_fence()
    test_html_to_text_preserves_pre()
    test_html_to_text_strips_script_and_style()
    test_html_to_text_table_renders_as_gfm_table()
    test_html_to_text_table_escapes_pipes_in_cells()
    test_markdown_highlights_headings_code_and_emphasis()
    test_markdown_fenced_code_uses_embedded_grammar()
    print("highlight: 56 tests passed")
