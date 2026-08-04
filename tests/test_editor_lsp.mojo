"""Editor-side language-service UI: completion, diagnostics, hover.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.colors import BLUE, LIGHT_GRAY, default_attr
from turbokod.editor import Editor
from turbokod.file_io import write_file
from turbokod.lsp_dispatch import (
    CodeActionFileEdit, CompletionItem, DIAG_SEVERITY_ERROR,
    DIAG_SEVERITY_HINT, DIAG_SEVERITY_WARNING, Diagnostic, TextEditEntry
)
from turbokod.highlight import GrammarRegistry
from turbokod.posix import which
from turbokod.events import (
    Event, KEY_BACKSPACE, KEY_ENTER, KEY_LEFT, KEY_SPACE, MOD_CTRL, MOD_META,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE
)
from turbokod.geometry import Point, Rect
from turbokod.window import Window

from support import _VIEW, _key, _spell_with_dict, _temp_path, setup_test_env


def test_editor_meta_click_emits_definition_request() raises:
    # The native turbokod wrapper sends a custom meta bit (MOD_META) on
    # Cmd+click; the editor treats Cmd+left-click as the goto-definition
    # trigger. (Plain Alt+click adds an extra caret instead.)
    var ed = Editor(String("foo bar baz"))
    var ev = Event.mouse_event(
        Point(4, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_META,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_true(Bool(req))
    var dr = req.value()
    assert_equal(dr.row, 0)
    assert_equal(dr.col, 4)
    assert_equal(dr.word, String("bar"))
    # The cursor must NOT have moved (Cmd+click is non-mutating).
    assert_equal(ed.selections[0].col, 0)
    # And the slot is consumed: a second poll returns empty.
    var req2 = ed.consume_definition_request()
    assert_false(Bool(req2))


def test_editor_meta_click_outside_identifier_is_silent() raises:
    var ed = Editor(String("foo  bar"))
    # Click on the space between words.
    var ev = Event.mouse_event(
        Point(3, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_META,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_false(Bool(req))


def test_editor_hover_dwell_emits_request_for_word_under_mouse() raises:
    """Bare hover over an identifier stamps a hover candidate;
    ``consume_hover_request`` then returns the (row, col) at the word's
    first byte once the dwell elapses. Hovering inside the same word
    doesn't re-stamp the timer, and hovering over whitespace clears the
    candidate so no request fires."""
    var ed = Editor(String("foo bar_baz\n"))
    var view = Rect(0, 0, 40, 5)
    # Hover at column 6 (inside "bar_baz"). Bare hover: button=NONE.
    var hover_mid = Event.mouse_event(
        Point(6, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover_mid, view)
    # ``now_ms == 0`` is the test escape hatch (bypass dwell gate).
    var req_opt = ed.consume_hover_request(0)
    assert_true(req_opt.__bool__())
    var req = req_opt.value()
    assert_equal(req.row, 0)
    # Word "bar_baz" starts at byte 4.
    assert_equal(req.col, 4)
    # Calling consume again after emit: no re-fire while dwelling on
    # the same word.
    assert_true(not ed.consume_hover_request(0).__bool__())
    # Hover on whitespace — candidate clears, no request.
    var hover_space = Event.mouse_event(
        Point(3, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover_space, view)
    assert_true(not ed.consume_hover_request(0).__bool__())


def test_editor_completion_prefix_start_walks_back_through_word() raises:
    """``completion_prefix_start`` returns the col where the in-progress
    identifier begins. Used to anchor the popup so accepting an entry
    replaces what the user already typed."""
    var ed = Editor(String("foo + abcde"))
    ed.move_to(0, 9, False)  # park inside "abcde", 3 bytes in
    var s = ed.completion_prefix_start()
    assert_equal(s, 6)


def test_editor_cursor_move_inside_word_keeps_popup_alive() raises:
    """Pressing Left/Right while the cursor stays inside the anchored
    identifier must NOT close the popup — it re-stamps a request so
    the filter follows. Pressing Left past the anchor (or jumping to
    another row) closes."""
    var ed = Editor(String("foo"))
    ed.move_to(0, 3, False)  # park at end of "foo"
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foobar"), String("foobar"), 6, String(""),
        String("foobar"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 0)
    # Left arrow from col 3 → col 2 keeps cursor inside "foo".
    var ev = Event.key_event(KEY_LEFT)
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    assert_true(ed.completion_popup_visible)
    # A fresh request was stamped (filter refresh).
    var req = ed.consume_completion_request()
    assert_true(Bool(req))


def test_editor_ctrl_space_marks_request_manual() raises:
    """Ctrl+Space stamps a ``CompletionRequest`` with ``manual=True``
    so the host can distinguish a user-invoked request (an empty
    response should surface ``<no completion found>``) from the
    as-you-type auto-trigger (an empty response stays silent)."""
    var ed = Editor(String(""))
    var ev = Event.key_event(KEY_SPACE, MOD_CTRL)
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_completion_request()
    assert_true(Bool(req))
    assert_true(req.value().manual)


def test_editor_autotrigger_request_is_not_manual() raises:
    """The as-you-type auto-trigger marks the request ``manual=False``
    — an empty response on this path should dismiss the popup
    silently rather than show ``<no completion found>``."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x66))  # 'f'
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_completion_request()
    assert_true(Bool(req))
    assert_false(req.value().manual)


def test_editor_autotrigger_request_debounced_until_settled() raises:
    """As-you-type completion requests are held in the slot while
    typing is still fresh. Gating ``consume_completion_request`` on a
    ``now_ms`` equal to the stamp leaves the request parked."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x66))  # 'f'
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    assert_true(Bool(ed.pending_completion_request))
    var stamp_field = ed._completion_request_stamp_ms
    var req_now = ed.consume_completion_request(stamp_field)
    assert_false(Bool(req_now))
    assert_true(Bool(ed.pending_completion_request))


def test_editor_autotrigger_request_released_after_debounce() raises:
    """Once ``_COMPLETION_DEBOUNCE_MS`` has elapsed since the last
    keystroke, the gated consume releases the parked request."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x66))  # 'f'
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var stamp_field = ed._completion_request_stamp_ms
    var req = ed.consume_completion_request(stamp_field + 1000)
    assert_true(Bool(req))
    assert_false(Bool(ed.pending_completion_request))


def test_editor_manual_completion_request_bypasses_debounce() raises:
    """Ctrl+Space is user-invoked: the user is explicitly waiting on
    results and the request must fire immediately regardless of how
    recently anything was typed."""
    var ed = Editor(String(""))
    var ev = Event.key_event(KEY_SPACE, MOD_CTRL)
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_completion_request(1)
    assert_true(Bool(req))
    var unwrapped = req.value()
    assert_true(unwrapped.manual)


def test_editor_close_completion_popup_clears_pending_request() raises:
    """Dismissing the popup clears any queued pending request *and*
    latches the cancel flag so the host can tell the LSP to drop
    in-flight work. Without this a late response would re-open the
    popup the user just dismissed."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x66))  # 'f'
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    assert_true(Bool(ed.pending_completion_request))
    ed.close_completion_popup()
    assert_false(Bool(ed.pending_completion_request))
    assert_true(ed.consume_completion_cancel())
    assert_false(ed.consume_completion_cancel())


def test_editor_accept_completion_replaces_prefix() raises:
    """Accepting a completion replaces ``[anchor_col, cursor_col)``
    with the chosen ``insert_text`` and leaves the cursor at the end
    of the replacement."""
    var ed = Editor(String("foo + abc"))
    ed.move_to(0, 9, False)
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("abcdef"), String("abcdef"), 6, String(""),
        String("abcdef"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 6)
    var ok = ed.accept_completion()
    assert_true(ok)
    assert_equal(ed.buffer.line(0), String("foo + abcdef"))
    assert_equal(ed.selections[0].col, 12)
    assert_false(ed.completion_popup_visible)


def test_editor_accept_completion_overlap_widens_anchor() raises:
    """When the server returns a label-only entry (no textEdit), the
    accept logic widens the replacement span by looking for the
    longest suffix of the typed line that is a byte-exact prefix of
    ``insert_text``. The ``reviews/re`` → ``reviews/reviews__tags.html``
    case: word-boundary anchor stops after the ``/`` (col 8), but the
    overlap scan finds that the whole ``reviews/re`` matches the start
    of the insert text, so the replacement covers all 10 bytes."""
    var ed = Editor(String("reviews/re"))
    ed.move_to(0, 10, False)
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("reviews/reviews__tags.html"),
        String("reviews/reviews__tags.html"),
        17, String(""), String("reviews/reviews__tags.html"),
        False, 0, 0, 0, 0,  # no textEdit range
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 8)  # word-boundary anchor
    var ok = ed.accept_completion()
    assert_true(ok)
    assert_equal(ed.buffer.line(0), String("reviews/reviews__tags.html"))
    assert_equal(ed.selections[0].col, 26)


def test_editor_accept_completion_overlap_leaves_disjoint_text_alone() raises:
    """When the inserted text shares no prefix with what's left of the
    cursor, the overlap heuristic must not widen the replacement —
    accepting falls back to the word-boundary anchor. Otherwise typing
    ``foo`` and accepting ``bar`` would silently eat the ``foo``."""
    var ed = Editor(String("foo"))
    ed.move_to(0, 3, False)
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("bar"), String("bar"), 6, String(""), String("bar"),
        False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 0)  # word-boundary anchor at start of ``foo``
    var ok = ed.accept_completion()
    assert_true(ok)
    # The word-boundary anchor (col 0..3) still drives the replacement
    # — overlap is 0 here, so it can't widen further left, but it also
    # mustn't shrink the existing span.
    assert_equal(ed.buffer.line(0), String("bar"))


def test_editor_accept_completion_uses_text_edit_range() raises:
    """When the item carries a ``textEdit`` range, the replacement
    span comes from the server — not from ``completion_prefix_start``.
    The path-completion case: the buffer holds ``reviews/re`` and the
    server returns ``newText="reviews/reviews__tags.html"`` covering
    the whole ``reviews/re`` span. The editor's word-boundary anchor
    would stop after the ``/`` and produce
    ``reviews/reviews/reviews__tags.html``; honoring the range
    yields the correct ``reviews/reviews__tags.html``."""
    var ed = Editor(String("reviews/re"))
    ed.move_to(0, 10, False)  # cursor at end of "reviews/re"
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("reviews/reviews__tags.html"),
        String("reviews/reviews__tags.html"),
        17, String(""), String("reviews/reviews__tags.html"),
        True, 0, 0, 0, 10,  # textEdit range covers [0..10)
        List[TextEditEntry](),
    ))
    # Anchor still arrives as the editor's heuristic (col 8 — after the
    # ``/``), but the item's range should override it.
    ed.set_completions(items^, 0, 8)
    var ok = ed.accept_completion()
    assert_true(ok)
    assert_equal(ed.buffer.line(0), String("reviews/reviews__tags.html"))
    assert_equal(ed.selections[0].col, 26)
    assert_false(ed.completion_popup_visible)


def test_editor_accept_completion_applies_additional_text_edits() raises:
    """Auto-import case: pyright returns a completion for ``foo_func``
    plus an ``additionalTextEdits`` entry that inserts an
    ``import foo_func\\n`` line at the top of the file. Accepting the
    completion must do BOTH the primary insert and the import line —
    earlier the import edit was silently dropped, so the user got the
    name but no import."""
    var ed = Editor(String("\n\nfoo"))
    # Cursor lands at end of ``foo`` (row 2, col 3). Primary edit will
    # replace ``foo`` with ``foo_func``; the auxiliary edit inserts an
    # ``import foo_func\n`` line at row 0 col 0.
    ed.move_to(2, 3, False)
    var aux = List[TextEditEntry]()
    aux.append(TextEditEntry(0, 0, 0, 0, String("import foo_func\n")))
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foo_func"), String("foo_func"), 3, String(""),
        String("foo_func"), False, 0, 0, 0, 0,
        aux^,
    ))
    ed.set_completions(items^, 2, 0)  # word-boundary anchor at start of ``foo``
    var ok = ed.accept_completion()
    assert_true(ok)
    # Buffer gained the import line, so the original row indices shift
    # down by one. ``foo_func`` lands on what was row 2 → now row 3.
    assert_equal(ed.buffer.line_count(), 4)
    assert_equal(ed.buffer.line(0), String("import foo_func"))
    assert_equal(ed.buffer.line(1), String(""))
    assert_equal(ed.buffer.line(2), String(""))
    assert_equal(ed.buffer.line(3), String("foo_func"))
    # Cursor must follow the shift — it sits at end of the inserted
    # ``foo_func`` on the post-import row, not on the now-blank row 2.
    assert_equal(ed.selections[0].row, 3)
    assert_equal(ed.selections[0].col, 8)
    assert_false(ed.completion_popup_visible)


def test_editor_diagnostic_at_cursor_picks_most_severe() raises:
    """``Editor.diagnostic_at_cursor`` returns the lowest-numbered (most
    severe) diagnostic whose range covers the cursor. With an error and
    a hint stacked on the same cell, error must win — same rule as the
    right-click hit logic in ``_maybe_request_diagnostic_menu``."""
    var ed = Editor(String("def f(x: timedelta) -> None: pass"))
    ed.selections[0].row = 0
    ed.selections[0].col = 10  # inside "timedelta"
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 9, 0, 18, DIAG_SEVERITY_HINT,
        String("unused import"), String("ty"),
    ))
    diags.append(Diagnostic(
        0, 9, 0, 18, DIAG_SEVERITY_ERROR,
        String("Name `timedelta` used when not defined"),
        String("ty"),
    ))
    ed.set_diagnostics(diags^)
    var picked = ed.diagnostic_at_cursor()
    assert_true(Bool(picked))
    assert_equal(picked.value().severity, DIAG_SEVERITY_ERROR)
    # Cursor outside any diagnostic range → None.
    ed.selections[0].col = 0
    assert_false(Bool(ed.diagnostic_at_cursor()))


def test_editor_apply_code_action_edits_inserts_typing_import() raises:
    """``Editor.apply_code_action_edits`` should apply the WorkspaceEdit
    a LSP quickfix carried for *this* editor's file. The canonical
    case: ty's ``import typing.Any`` quickfix inserts
    ``from typing import Any\\n`` at line 0, col 0. After apply, line 0
    holds the import line and the original code is shifted down by one
    row. Edits keyed to a different URI are ignored."""
    var ed = Editor(String("def f(x: Any) -> Any:\n    return x\n"))
    ed.file_path = _temp_path(String("_quickfix.py"))
    var my_uri = String("file://") + ed.file_path
    var edits = List[TextEditEntry]()
    edits.append(TextEditEntry(
        0, 0, 0, 0, String("from typing import Any\n"),
    ))
    var file_edits = List[CodeActionFileEdit]()
    file_edits.append(CodeActionFileEdit(my_uri, edits^))
    # Add an edit for a foreign URI to confirm it's silently dropped.
    var foreign = List[TextEditEntry]()
    foreign.append(TextEditEntry(
        0, 0, 0, 0, String("# do not apply me\n"),
    ))
    file_edits.append(CodeActionFileEdit(
        String("file:///not/this/file.py"), foreign^,
    ))
    var ok = ed.apply_code_action_edits(file_edits^)
    assert_true(ok)
    assert_equal(
        ed.buffer.line(0), String("from typing import Any"),
    )
    assert_equal(
        ed.buffer.line(1), String("def f(x: Any) -> Any:"),
    )
    assert_true(ed.dirty)


def test_editor_clear_diagnostics_drops_per_row_index() raises:
    """``clear_diagnostics`` empties both lists so the minimap collapses
    back to git/spell-only kinds — used when an LSP server crashes or
    a buffer is closed."""
    var ed = Editor(String("a\nb"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 1, DIAG_SEVERITY_ERROR, String("e"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    assert_equal(len(ed.diagnostic_lines), 2)
    ed.clear_diagnostics()
    assert_equal(len(ed.diagnostics), 0)
    assert_equal(len(ed.diagnostic_lines), 0)


def test_editor_diagnostics_unchanged_on_inline_edit() raises:
    """Typing within a line doesn't move any diagnostic — column-level
    offsets on the edited row may now be slightly off, but row
    positions are still correct and the LSP refresh will catch any
    real invalidation. Avoiding a blink on every keystroke matters
    more than instant column-accuracy here."""
    var ed = Editor(String("aaa\nbbb\nccc\nddd\neee"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 3, DIAG_SEVERITY_WARNING, String("w0"), String("t"),
    ))
    diags.append(Diagnostic(
        2, 0, 2, 3, DIAG_SEVERITY_HINT, String("h2"), String("t"),
    ))
    diags.append(Diagnostic(
        3, 0, 3, 3, DIAG_SEVERITY_ERROR, String("e3"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    ed.move_to(2, 1, False)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)
    assert_equal(len(ed.diagnostics), 3)
    assert_equal(ed.diagnostic_lines[0], DIAG_SEVERITY_WARNING)
    assert_equal(ed.diagnostic_lines[2], DIAG_SEVERITY_HINT)
    assert_equal(ed.diagnostic_lines[3], DIAG_SEVERITY_ERROR)


def test_editor_diagnostics_shifted_on_line_insertion() raises:
    """Pressing Enter at row 2 inserts a new line; diagnostics with
    ``start_row >= 2`` shift down by one so they stay attached to
    their original code while the LSP refresh is in flight."""
    var ed = Editor(String("aaa\nbbb\nccc\nddd\neee"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 3, DIAG_SEVERITY_WARNING, String("w0"), String("t"),
    ))
    diags.append(Diagnostic(
        3, 0, 3, 3, DIAG_SEVERITY_ERROR, String("e3"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    ed.move_to(2, 0, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(len(ed.diagnostics), 2)
    # Above-edit warning stays at row 0; below-edit error shifts 3 → 4.
    assert_equal(ed.diagnostics[0].start_row, 0)
    assert_equal(ed.diagnostics[1].start_row, 4)
    assert_equal(ed.diagnostics[1].end_row, 4)
    assert_equal(len(ed.diagnostic_lines), ed.buffer.line_count())
    assert_equal(ed.diagnostic_lines[4], DIAG_SEVERITY_ERROR)


def test_editor_diagnostics_dropped_on_deleted_row_shifted_below() raises:
    """Backspace at column 0 joins two rows. The diagnostic on the
    deleted row has nowhere to go and is dropped; diagnostics below
    shift up by one. The diagnostic on the row that absorbed the
    join is also dropped (its text changed) — slightly aggressive
    but the LSP refresh repopulates within ~150 ms."""
    var ed = Editor(String("aaa\nbbb\nccc\nddd\neee"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 3, DIAG_SEVERITY_WARNING, String("w0"), String("t"),
    ))
    diags.append(Diagnostic(
        2, 0, 2, 3, DIAG_SEVERITY_ERROR, String("e2"), String("t"),
    ))
    diags.append(Diagnostic(
        4, 0, 4, 3, DIAG_SEVERITY_HINT, String("h4"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    # Cursor at start of row 2 → Backspace joins rows 1 and 2.
    # Row 2 (the one being absorbed) and its diagnostic are gone;
    # row 4 hint shifts up to row 3.
    ed.move_to(2, 0, False)
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(len(ed.diagnostics), 2)
    assert_equal(ed.diagnostics[0].start_row, 0)
    assert_equal(ed.diagnostics[1].start_row, 3)
    assert_equal(ed.diagnostics[1].severity, DIAG_SEVERITY_HINT)
    assert_equal(len(ed.diagnostic_lines), ed.buffer.line_count())
    assert_equal(ed.diagnostic_lines[3], DIAG_SEVERITY_HINT)


def test_editor_diagnostics_preserved_above_edit() raises:
    """An edit never moves diagnostics on rows above it — those rows
    haven't changed, and shifting them would put squiggles on
    unrelated code."""
    var ed = Editor(String("aaa\nbbb\nccc"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 3, DIAG_SEVERITY_ERROR, String("e0"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    ed.move_to(2, 0, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(len(ed.diagnostics), 1)
    assert_equal(ed.diagnostics[0].start_row, 0)
    assert_equal(ed.diagnostic_lines[0], DIAG_SEVERITY_ERROR)


def test_editor_active_overlay_bounds_covers_painted_tooltip() raises:
    """Regression: the macOS smooth-scroll compositor re-blits the rect that
    ``active_overlay_bounds`` reports on top of its body overdraw (which
    suppresses overlays). That rect must cover *every* cell the tooltip
    actually paints — box + drop shadow — or mid-scroll the tooltip gets
    clipped away, leaving only the stray shadow on the minimap column (the
    reported bug). Diff a suppressed-overlay paint against a normal paint to
    isolate the tooltip cells, then assert they all fall inside the bounds."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_overlay_bounds.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    var view = Rect(0, 0, 40, 5)
    var hover = Event.mouse_event(
        Point(39, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    assert_equal(ed._minimap_hover_kind, 2)
    var bounds_opt = ed.active_overlay_bounds(view)
    assert_true(Bool(bounds_opt))
    var bounds = bounds_opt.value()
    # Body-only paint (overlays suppressed) vs. full paint — the diff is
    # exactly the tooltip's cells (box glyphs + darkened shadow).
    var body = Canvas(40, 5)
    body.fill(view, String(" "), default_attr())
    ed._suppress_overlays = True
    ed.paint(body, view, False)
    ed._suppress_overlays = False
    var full = Canvas(40, 5)
    full.fill(view, String(" "), default_attr())
    ed.paint(full, view, False)
    var painted_any = False
    for y in range(view.b.y):
        for x in range(view.b.x):
            if full.get(x, y) != body.get(x, y):
                painted_any = True
                assert_true(bounds.contains(Point(x, y)))
    assert_true(painted_any)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_long_diagnostic_tooltip_through_window() raises:
    """Same scenario as ``..._fills_popup_interior``, but painted via
    ``Window.paint`` so the window's body fill (LIGHT_GRAY on BLUE)
    runs first and the editor paints into the window's interior. The
    popup must still cover all interior cells with its own gray
    background — no blue (or window-bg) bleed-through past the text."""
    var w = Window.editor_window(
        String("scratch.py"), Rect(0, 0, 64, 14),
        String("alpha beta gamma\n"),
    )
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        String(
            "Cannot access attribute \"objects\" for class "
            "\"type[Action]\""
        ),
        String("pyright"),
    ))
    w.editor.set_diagnostics(diags^)
    var hover = Event.mouse_event(
        Point(8, 1), MOUSE_BUTTON_NONE, True, True,
    )
    _ = w.handle_mouse_in_body(hover)
    assert_equal(w.editor._minimap_hover_kind, 3)
    var canvas = Canvas(64, 14)
    canvas.fill(Rect(0, 0, 64, 14), String(" "), default_attr())
    w.paint(canvas, String("scratch.py"), True, 1)
    # Locate popup by scanning for ┌
    var top_y = -1
    var left_x = -1
    var right_x = -1
    for y in range(14):
        for x in range(64):
            if canvas.get(x, y).glyph == String("┌"):
                top_y = y
                left_x = x
                var xi = x + 1
                while xi < 64:
                    if canvas.get(xi, y).glyph == String("┐"):
                        right_x = xi
                        break
                    xi += 1
                break
        if top_y >= 0:
            break
    assert_true(top_y >= 0)
    var bottom_y = -1
    var by = top_y + 1
    while by < 14:
        if canvas.get(left_x, by).glyph == String("└"):
            bottom_y = by
            break
        by += 1
    assert_true(bottom_y > top_y)
    for y in range(top_y + 1, bottom_y):
        for x in range(left_x + 1, right_x):
            var bg = canvas.get(x, y).attr.bg
            assert_true(bg != BLUE)


def test_editor_long_diagnostic_tooltip_fills_popup_interior() raises:
    """A diagnostic message longer than the editor view forces the
    tooltip to wrap onto multiple rows. Every cell inside the popup's
    interior must come from the popup's own paint pass — light-gray
    background, not the editor's blue. Catches regressions where the
    wrap leaves the trailing tail of a wrapped row on the editor's
    blue fill instead of the popup's gray."""
    # Long enough that ``Error: <message>`` ends up wider than the
    # 60-cell view, forcing a wrap.
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        String(
            "Cannot access attribute \"objects\" for class "
            "\"type[Action]\""
        ),
        String("pyright"),
    ))
    ed.set_diagnostics(diags^)
    # Squeeze the view so the message has to wrap.
    var view = Rect(0, 0, 60, 12)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    var canvas = Canvas(60, 12)
    canvas.fill(view, String(" "), default_attr())
    ed.paint(canvas, view, False)
    # Find the popup by scanning for the top border row (a run of
    # ``─`` glyphs starting with ``┌``).
    var top_y = -1
    var left_x = -1
    var right_x = -1
    for y in range(view.b.y):
        for x in range(view.b.x):
            if canvas.get(x, y).glyph == String("┌"):
                top_y = y
                left_x = x
                # Walk right to find the matching ``┐``.
                var xi = x + 1
                while xi < view.b.x:
                    if canvas.get(xi, y).glyph == String("┐"):
                        right_x = xi
                        break
                    xi += 1
                break
        if top_y >= 0:
            break
    assert_true(top_y >= 0)
    assert_true(right_x > left_x + 2)
    # Find the bottom row — first ``└`` in the same column as ``┌``.
    var bottom_y = -1
    var by = top_y + 1
    while by < view.b.y:
        if canvas.get(left_x, by).glyph == String("└"):
            bottom_y = by
            break
        by += 1
    assert_true(bottom_y > top_y)
    # Every interior cell (the padding ring + content rows) must have
    # the popup's gray background, never the editor's blue. Border
    # rows are skipped — those carry frame glyphs whose attr we don't
    # constrain here.
    for y in range(top_y + 1, bottom_y):
        for x in range(left_x + 1, right_x):
            var bg = canvas.get(x, y).attr.bg
            assert_true(bg != BLUE)


def main() raises:
    setup_test_env()
    test_editor_meta_click_emits_definition_request()
    test_editor_meta_click_outside_identifier_is_silent()
    test_editor_hover_dwell_emits_request_for_word_under_mouse()
    test_editor_completion_prefix_start_walks_back_through_word()
    test_editor_cursor_move_inside_word_keeps_popup_alive()
    test_editor_ctrl_space_marks_request_manual()
    test_editor_autotrigger_request_is_not_manual()
    test_editor_autotrigger_request_debounced_until_settled()
    test_editor_autotrigger_request_released_after_debounce()
    test_editor_manual_completion_request_bypasses_debounce()
    test_editor_close_completion_popup_clears_pending_request()
    test_editor_accept_completion_replaces_prefix()
    test_editor_accept_completion_overlap_widens_anchor()
    test_editor_accept_completion_overlap_leaves_disjoint_text_alone()
    test_editor_accept_completion_uses_text_edit_range()
    test_editor_accept_completion_applies_additional_text_edits()
    test_editor_diagnostic_at_cursor_picks_most_severe()
    test_editor_apply_code_action_edits_inserts_typing_import()
    test_editor_clear_diagnostics_drops_per_row_index()
    test_editor_diagnostics_unchanged_on_inline_edit()
    test_editor_diagnostics_shifted_on_line_insertion()
    test_editor_diagnostics_dropped_on_deleted_row_shifted_below()
    test_editor_diagnostics_preserved_above_edit()
    test_editor_active_overlay_bounds_covers_painted_tooltip()
    test_editor_long_diagnostic_tooltip_through_window()
    test_editor_long_diagnostic_tooltip_fills_popup_interior()
    print("editor_lsp: 26 tests passed")
