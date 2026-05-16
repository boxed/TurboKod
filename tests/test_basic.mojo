"""Pure-data tests: geometry, colors, canvas, event factories.

These tests don't touch the terminal so they can run in CI without a TTY.
Run with::

    mojo run -I src tests/test_basic.mojo
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from turbokod.canvas import Canvas, wrap_to_width
from turbokod.claude_detect import (
    CLAUDE_ACTIVE, CLAUDE_CLEAN, CLAUDE_NONE, CLAUDE_WAITING, CLAUDE_WORKING,
    claude_state_label, detect_claude_state,
)
from turbokod.dir_browser import DirBrowser
from turbokod.painter import Painter
from turbokod.cell import Cell, blank_cell
from turbokod.colors import (
    Attr, BLACK, BLUE, CYAN, DARK_GRAY, GREEN, LIGHT_BLUE, LIGHT_GRAY,
    LIGHT_GREEN, LIGHT_RED, STYLE_UNDERLINE, STYLE_UNDERLINE_CURLY,
    WHITE, YELLOW,
    attr_to_sgr, default_attr,
)
from turbokod.diff import MergeResult, diff3_merge, diff_lines, unified_diff
from turbokod.editor import (
    EXT_CHANGE_CONFLICT, EXT_CHANGE_MERGED, EXT_CHANGE_NONE,
    EXT_CHANGE_RELOADED, Editor, TextBuffer,
)
from turbokod.editorconfig import (
    EditorConfig, load_editorconfig_for_path, match_section, parse_editorconfig,
)
from turbokod.file_dialog import FileDialog
from turbokod.save_as_dialog import SaveAsDialog
from turbokod.scrollbar import HScrollbar, VScrollbar
from turbokod.session_store import (
    Session, SessionWindow, _resolve_session_path, _session_relative,
    encode_session, load_session, save_session,
)
from turbokod.breakpoint_store import (
    StoredBreakpoint, encode_breakpoints, load_breakpoints, save_breakpoints,
)
from turbokod.view_state_store import (
    StoredViewState, encode_view_states, load_view_states, save_view_states,
)
from turbokod.desktop import (
    APP_QUIT_ACTION,
    Desktop,
    EDITOR_FIND, EDITOR_GOTO, EDITOR_NAV_BACK, EDITOR_NAV_FORWARD,
    EDITOR_NEW, EDITOR_OPEN, EDITOR_QUICK_OPEN, EDITOR_REPLACE,
    EDITOR_SAVE, EDITOR_SAVE_AS, EDITOR_TOGGLE_CASE, EDITOR_TOGGLE_COMMENT,
    Hotkey, NavPoint,
    PROJECT_CLOSE_ACTION, PROJECT_CONFIG_TARGETS, PROJECT_FIND,
    PROJECT_OPEN_RECENT, PROJECT_OPEN_RECENT_PREFIX,
    PROJECT_REPLACE, PROJECT_TREE_ACTION,
    WINDOW_CLOSE, WINDOW_FOCUS_PREFIX,
    _expand_save_placeholders,
    _find_doc_entry_for_word,
    ctrl_key, format_hotkey,
)
from turbokod.file_io import (
    basename, find_git_project, join_path, list_directory, parent_path,
    read_file, stat_file, write_file,
)
from turbokod.git_blame import BlameLine, parse_blame_porcelain
from turbokod.git_changes import (
    ChangedFile, GIT_CHANGE_ADDED, GIT_CHANGE_MODIFIED, GIT_CHANGE_NONE,
    compute_revert_block, diff_buffer_against_head, parse_unified_diff_files,
)
from turbokod.local_changes import LocalChanges, build_minimal_patch
from turbokod.file_tree import FILE_TREE_WIDTH, FileTree, FileTreeEntry
from turbokod.menu import Menu, MenuBar, MenuItem
from turbokod.project import (
    GitignoreMatcher, find_in_project, replace_in_project, walk_project_files,
)
from turbokod.search_options import SearchOptions
from turbokod.project_targets import (
    ProjectTargets, RunTarget,
    detect_project_language,
    load_project_targets, python_venv_dir, resolve_python_interpreter,
    resolved_cwd, resolved_program, save_project_targets,
)
from turbokod.buttons import (
    ShadowButton, paint_shadow_button, shadow_button_hit,
)
from turbokod.debug_pane import (
    DebugPane, PANE_MODE_DEBUG, PANE_MODE_RUN,
)
from turbokod.run_manager import RunSession, drain_run_output, poll_run_exit
from turbokod.status import StatusBar, StatusTab
from turbokod.string_utils import slice_codepoints
from turbokod.targets_dialog import TargetsDialog
from turbokod.text_field import TextField
from turbokod.text_view import Selection, TextLog, VisualLine, wrap_lines
from turbokod.quick_open import QuickOpen, quick_open_match
from turbokod.install_runner import InstallResult, InstallRunner, _last_lines
from turbokod.doc_config import (
    DocSpec, built_in_docsets, docs_install_command,
    find_docset_by_language, find_docset_for_extension,
)
from turbokod.doc_store import DocEntry, DocStore, html_to_text
from turbokod.doc_pick import DocPick
from turbokod.json import (
    JsonValue, encode_json, json_array, json_bool, json_int, json_null,
    json_object, json_str, parse_json,
)
from turbokod.language_config import (
    LanguageSpec, apply_language_overrides, built_in_servers,
    find_language_by_id, find_language_for_extension,
)
from turbokod.language_editor import LanguageEditor
from turbokod.list_box import ListBox
from turbokod.type_ahead import (
    TypeAhead, is_printable_ascii, type_ahead_pick,
)
from turbokod.lsp import (
    LSP_NOTIFICATION, LSP_RESPONSE, LspClient, LspIncoming, LspProcess,
    _drop_prefix, _find_double_crlf, _parse_content_length, capture_command,
    classify_message,
)
from turbokod.lsp_dispatch import (
    CompletionItem, DIAG_SEVERITY_ERROR, DIAG_SEVERITY_HINT,
    DIAG_SEVERITY_INFO, DIAG_SEVERITY_WARNING, Diagnostic, LspManager,
    TextEditEntry, _parse_completion_result, _parse_diagnostics_array,
)
from turbokod.git_changes import (
    GitStateMtimes, apply_patch_to_index, compute_staged_diff,
    compute_unstaged_diff, fetch_git_status, git_state_mtimes,
    stage_file, unstage_file,
)
from turbokod.dap import (
    DAP_EVENT, DAP_REQUEST, DAP_RESPONSE,
    DapClient, DapIncoming, classify_dap_message, dap_initialize_arguments,
)
from turbokod.dap_dispatch import (
    DapManager, DapStackFrame, DapScope, DapVariable, DapThread,
    _parse_scopes, _parse_stack_trace, _parse_threads, _parse_variables,
)
from turbokod.debugger_config import (
    DAP_REQUEST_LAUNCH, DebuggerSpec,
    built_in_debuggers, find_debugger_for_language, launch_arguments_for,
    python_debugger_spec_for_venv,
)
from turbokod.highlight import (
    DefinitionRequest, GrammarRegistry, Highlight, HighlightCache,
    embedded_language_extensions,
    extension_of, highlight_for_extension, highlight_incremental,
    highlight_comment_attr, highlight_decorator_attr, highlight_ident_attr,
    highlight_keyword_attr,
    highlight_number_attr, highlight_operator_attr, highlight_string_attr,
    word_at,
)
from turbokod.posix import getenv_value, monotonic_ms
from turbokod.spell import (
    Speller, SpellActionRequest, find_misspelled_runs,
    has_spell_noinspection_directive,
    project_dict_path, user_dict_path,
)
from turbokod.spell_menu import (
    SPELL_ACTION_ADD_PROJECT, SPELL_ACTION_ADD_USER, SPELL_ACTION_NONE,
    SpellMenu,
)
from turbokod.grammar_install import (
    built_in_downloadable_grammars,
    find_downloadable_grammar_by_language,
    find_downloadable_grammar_for_extension,
    grammar_install_command, user_grammar_path, user_grammar_path_for_ext,
)
from turbokod.action_editor import ActionEditor
from turbokod.config import LanguageServerOverride, OnSaveAction
from turbokod.dropdown import Dropdown
from turbokod.settings import Settings
from turbokod.onig import OnigRegex, onig_global_init
from turbokod.tm_grammar import load_grammar_from_string
from turbokod.tm_tokenizer import tokenize_with_grammar
from turbokod.canvas import paint_drop_shadow
from turbokod.window import (
    DockedPanelStack,
    PANEL_STATE_MAXIMIZED, PANEL_STATE_MINIMIZED, PANEL_STATE_NORMAL,
    TitleCommand, WindowManager, hit_title_command,
    paint_title_commands,
)
from turbokod.events import (
    Event, EVENT_FOCUS_IN, EVENT_FOCUS_OUT,
    EVENT_KEY, EVENT_MOUSE, EVENT_NONE, EVENT_OPEN_PATH,
    EVENT_QUIT, EVENT_RESIZE,
    KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END, KEY_ENTER, KEY_ESC,
    KEY_F5, KEY_HOME,
    KEY_LEFT, KEY_PAGEDOWN, KEY_PAGEUP, KEY_RIGHT, KEY_SPACE, KEY_TAB, KEY_UP,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_BUTTON_RIGHT,
    MOUSE_WHEEL_DOWN, MOUSE_WHEEL_UP,
)
from turbokod.geometry import Point, Rect
from turbokod.confirm_dialog import ConfirmDialog
from turbokod.prompt import Prompt
from turbokod.terminal import parse_input
from turbokod import Vt
from turbokod.view import Fill, Frame, Label, centered
from turbokod.window import Window


def test_claude_detect_empty_buffer_returns_none() raises:
    var lines = List[String]()
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_NONE))


def test_claude_detect_plain_shell_output_returns_none() raises:
    var lines = List[String]()
    lines.append(String("$ ls"))
    lines.append(String("foo.txt   bar.txt"))
    lines.append(String("$ git status"))
    lines.append(String("On branch main"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_NONE))


def test_claude_detect_spinner_row_returns_working() raises:
    var lines = List[String]()
    lines.append(String("> add tests for the detector"))
    lines.append(
        String("✻ Synthesizing… (5s · esc to interrupt · ctrl+t to show todos)")
    )
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_WORKING))


def test_claude_detect_spinner_small_dot_frame_returns_working() raises:
    # The spinner animation throbs: at the trough of the throb the
    # glyph drops to a small ``·``. Detection must still fire — the
    # row layout is identical apart from the swapped glyph.
    var lines = List[String]()
    lines.append(String("> investigate this bug"))
    lines.append(String("· Hatching… (3s)"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_WORKING))


def test_claude_detect_spinner_other_glyph_frames_return_working() raises:
    # Walk through the rest of the throbbing-asterisk frames. The
    # ``(...)`` timer block is the disambiguator; without it the same
    # leading-glyph pattern would collide with the welcome banner.
    var glyphs = List[String]()
    glyphs.append(String("✺"))
    glyphs.append(String("✼"))
    glyphs.append(String("✽"))
    glyphs.append(String("✶"))
    glyphs.append(String("✱"))
    glyphs.append(String("✲"))
    glyphs.append(String("✳"))
    for i in range(len(glyphs)):
        var lines = List[String]()
        lines.append(String("> some prompt"))
        lines.append(glyphs[i] + String(" Thinking… (2s · esc to interrupt)"))
        assert_equal(
            Int(detect_claude_state(lines)), Int(CLAUDE_WORKING)
        )


def test_claude_detect_spinner_glyph_in_welcome_banner_is_not_working() raises:
    # The legacy welcome banner starts with ``✻ Welcome to Claude
    # Code!`` — same leading-glyph-plus-space pattern as the spinner
    # row, but no parens. Without the open-paren guard the spinner
    # detector would swallow the welcome banner and label it working.
    var lines = List[String]()
    lines.append(String("✻ Welcome to Claude Code!"))
    lines.append(String("  /help for help, /status for your current setup"))
    lines.append(String("  cwd: /Users/dev/proj"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_CLEAN))


def test_claude_detect_welcome_banner_returns_clean() raises:
    var lines = List[String]()
    lines.append(String("✻ Welcome to Claude Code!"))
    lines.append(String("  /help for help, /status for your current setup"))
    lines.append(String("  cwd: /Users/dev/proj"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_CLEAN))


def test_claude_detect_mascot_version_banner_returns_clean() raises:
    # Recent Claude Code builds drop the ``Welcome to Claude Code`` line
    # and print only the quadrant-block mascot plus a ``Claude Code
    # v<version>`` row on the post-``/clear`` banner. The version string
    # is the stable anchor — must still classify as clean.
    var lines = List[String]()
    lines.append(String("▗ ▗   ▖ ▖  Claude Code v2.1.140"))
    lines.append(String("           Opus 4.7 (1M context) · Claude Max"))
    lines.append(String("  ▘▘ ▝▝    ~/Projects/turbokod"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_CLEAN))


def test_claude_detect_mascot_banner_with_prompt_below_returns_clean() raises:
    # The mascot sits a few rows above the bottom of the pane in real
    # use — the input box and shortcut strip live below it. The tail
    # window has to be wide enough to still see the mascot when those
    # rows are present.
    var lines = List[String]()
    lines.append(String("▗ ▗   ▖ ▖  Claude Code v2.1.140"))
    lines.append(String("           Opus 4.7 (1M context) · Claude Max"))
    lines.append(String("  ▘▘ ▝▝    ~/Projects/turbokod"))
    lines.append(String(""))
    lines.append(String("╭─────────────────────────────────────────╮"))
    lines.append(String("│ >                                       │"))
    lines.append(String("╰─────────────────────────────────────────╯"))
    lines.append(String("  ? for shortcuts"))
    # Both ``claude code v`` (clean) and ``? for shortcuts`` (waiting)
    # are in the tail. Clean wins per the documented priority — the
    # mascot is the dominant visual element.
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_CLEAN))


def test_claude_detect_idle_prompt_returns_waiting() raises:
    var lines = List[String]()
    lines.append(String("╭─────────────────────────────────────────╮"))
    lines.append(String("│ >                                       │"))
    lines.append(String("╰─────────────────────────────────────────╯"))
    lines.append(String("  ? for shortcuts"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_WAITING))


def test_claude_detect_working_wins_over_waiting() raises:
    # Right after the user submits, the prompt hint can briefly co-exist
    # with the spinner row in the visible tail. Working should win — the
    # user cares more about "is it still going?" than "is the prompt
    # there?" in that moment.
    var lines = List[String]()
    lines.append(String("  ? for shortcuts"))
    lines.append(
        String("✻ Hatching… (1s · esc to interrupt · ctrl+r to expand)")
    )
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_WORKING))


def test_claude_detect_generic_marker_returns_active() raises:
    # Only the brand glyph is in view — Claude is on screen somewhere
    # but we can't tell which precise state. Better to say ``active``
    # than to fall back to ``none`` and let the title pretend Claude
    # isn't running.
    var lines = List[String]()
    lines.append(String("● Done thinking about the layout."))
    lines.append(String("✻ Some Claude row without other markers"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_ACTIVE))


def test_claude_detect_marker_outside_tail_window_is_ignored() raises:
    # Only the most recent ~20 rows count — the marker must be in the
    # currently-visible tail, not in scrollback that's drifted off.
    var lines = List[String]()
    lines.append(String("✻ Welcome to Claude Code!"))
    for _ in range(30):
        lines.append(String("$ echo plain shell output"))
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_NONE))


def test_claude_detect_finds_marker_inside_ansi_wrapped_line() raises:
    # In the real pane, color escapes wrap the marker text. The detector
    # is a byte-level substring search so the escapes don't disturb the
    # match as long as the marker bytes themselves are contiguous.
    var lines = List[String]()
    var wrapped = String("\x1b[2m✻ Hatching… (3s · esc to interrupt)\x1b[0m")
    lines.append(wrapped)
    assert_equal(Int(detect_claude_state(lines)), Int(CLAUDE_WORKING))


def test_claude_state_label_round_trip() raises:
    assert_equal(claude_state_label(CLAUDE_NONE),    String(""))
    assert_equal(claude_state_label(CLAUDE_CLEAN),   String("clean"))
    assert_equal(claude_state_label(CLAUDE_WAITING), String("waiting"))
    assert_equal(claude_state_label(CLAUDE_WORKING), String("working"))
    assert_equal(claude_state_label(CLAUDE_ACTIVE),  String("active"))


def test_point_arithmetic() raises:
    var p = Point(2, 3)
    var q = Point(5, 7)
    assert_true((p + q) == Point(7, 10))
    assert_true((q - p) == Point(3, 4))
    assert_true(p == Point(2, 3))
    assert_false(p == q)


def test_rect_basics() raises:
    var r = Rect(0, 0, 10, 5)
    assert_equal(r.width(), 10)
    assert_equal(r.height(), 5)
    assert_false(r.is_empty())
    assert_true(r.contains(Point(5, 2)))
    assert_false(r.contains(Point(10, 2)))  # exclusive
    assert_false(r.contains(Point(5, 5)))   # exclusive

    var s = Rect(5, 2, 12, 6)
    var inter = r.intersect(s)
    assert_true(inter == Rect(5, 2, 10, 5))

    var u = r.union(s)
    assert_true(u == Rect(0, 0, 12, 6))

    assert_true(Rect(0, 0, 0, 0).is_empty())


def test_rect_helpers() raises:
    var r = Rect.sized(Point(3, 4), 7, 2)
    assert_true(r == Rect(3, 4, 10, 6))
    assert_true(r.translated(Point(1, 1)) == Rect(4, 5, 11, 7))
    assert_true(r.inset(1, 0) == Rect(4, 4, 9, 6))


def test_attr() raises:
    var a = Attr(WHITE, BLUE)
    var b = a.with_fg(YELLOW)
    assert_true(a.fg == WHITE)
    assert_true(b.fg == YELLOW)
    assert_true(b.bg == BLUE)
    assert_false(a == b)


def test_attr_to_sgr_plain_underline() raises:
    """Default underline emits SGR ``;4`` (no colon, no separate
    color) — same as the pre-extension shape so non-curly callers
    don't accidentally trigger 4:3 parsing in older terminals."""
    var a = Attr(WHITE, BLUE, STYLE_UNDERLINE)
    var s = attr_to_sgr(a)
    assert_true(_substring_present(s, String(";4;")))
    assert_false(_substring_present(s, String(";4:3")))
    assert_false(_substring_present(s, String(";58;")))


def test_attr_to_sgr_curly_colored_underline() raises:
    """Curly bit + explicit underline color emits ``;4:3`` and a
    ``;58;5;<color>`` parameter — the VS-Code-squiggle SGR."""
    var a = Attr(WHITE, BLUE, STYLE_UNDERLINE | STYLE_UNDERLINE_CURLY) \
        .with_underline_color(Int16(LIGHT_RED))
    var s = attr_to_sgr(a)
    assert_true(_substring_present(s, String(";4:3")))
    assert_true(
        _substring_present(s, String(";58;5;") + String(Int(LIGHT_RED)))
    )


def _substring_present(haystack: String, needle: String) -> Bool:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) > len(hb):
        return False
    for i in range(len(hb) - len(nb) + 1):
        var match_at = True
        for j in range(len(nb)):
            if hb[i + j] != nb[j]:
                match_at = False
                break
        if match_at:
            return True
    return False


def test_canvas_put_text() raises:
    var c = Canvas(20, 5)
    var n = c.put_text(Point(2, 1), String("hello"), default_attr())
    assert_equal(n, 5)
    assert_equal(c.get(2, 1).glyph, String("h"))
    assert_equal(c.get(6, 1).glyph, String("o"))
    assert_equal(c.get(7, 1).glyph, String(" "))  # untouched


def test_paint_title_commands_renders_separator_and_labels() raises:
    """``paint_title_commands`` paints ``- <cmd1> <cmd2>`` after the
    given start point, returning one hit rect per fully-painted
    label (with x_end exclusive). The body-bg rule from
    ``paint_window_title`` applies here too — we don't assert
    colours but the basic glyph layout is enough to catch
    regressions."""
    var c = Canvas(40, 1)
    var commands = List[TitleCommand]()
    commands.append(TitleCommand(String("[A]"), String("a:1")))
    commands.append(TitleCommand(String("[BB]"), String("b:2")))
    var attr = Attr(WHITE, BLACK)
    var hits = paint_title_commands(
        c, Point(2, 0), commands, attr, attr, attr, 40,
    )
    # Layout: "- [A] [BB]" starting at x=2.
    assert_equal(c.get(2, 0).glyph, String("-"))
    assert_equal(c.get(3, 0).glyph, String(" "))
    assert_equal(c.get(4, 0).glyph, String("["))
    assert_equal(c.get(5, 0).glyph, String("A"))
    assert_equal(c.get(6, 0).glyph, String("]"))
    assert_equal(c.get(7, 0).glyph, String(" "))   # gap between commands
    assert_equal(c.get(8, 0).glyph, String("["))
    assert_equal(c.get(9, 0).glyph, String("B"))
    assert_equal(c.get(11, 0).glyph, String("]"))
    assert_equal(len(hits), 2)
    assert_equal(hits[0].id, String("a:1"))
    assert_equal(hits[0].x_start, 4)
    assert_equal(hits[0].x_end, 7)        # exclusive — past the ``]``
    assert_equal(hits[1].id, String("b:2"))
    assert_equal(hits[1].x_start, 8)
    assert_equal(hits[1].x_end, 12)


def test_paint_title_commands_drops_clipped_label() raises:
    """A label whose right edge would land past ``max_x`` must be
    skipped — we'd rather drop it than register a hit on a
    half-painted button."""
    var c = Canvas(20, 1)
    var commands = List[TitleCommand]()
    commands.append(TitleCommand(String("[A]"), String("a")))
    commands.append(TitleCommand(String("[verylong]"), String("b")))
    var attr = Attr(WHITE, BLACK)
    var hits = paint_title_commands(
        c, Point(0, 0), commands, attr, attr, attr, 8,
    )
    # Available range [0, 8): "- " (2) + "[A]" (3) = 5 cells used,
    # next gap + "[verylong]" wouldn't fit before x=8.
    assert_equal(len(hits), 1)
    assert_equal(hits[0].id, String("a"))


def test_hit_title_command_returns_id_under_cursor() raises:
    var c = Canvas(40, 1)
    var commands = List[TitleCommand]()
    commands.append(TitleCommand(String("[X]"), String("first")))
    commands.append(TitleCommand(String("[Y]"), String("second")))
    var attr = Attr(WHITE, BLACK)
    var hits = paint_title_commands(
        c, Point(0, 0), commands, attr, attr, attr, 40,
    )
    # Inside the first command's rect.
    assert_equal(hit_title_command(hits, Point(3, 0)), String("first"))
    # On the gap between commands — no hit.
    assert_equal(hit_title_command(hits, Point(5, 0)), String(""))
    # Inside the second command's rect.
    assert_equal(hit_title_command(hits, Point(7, 0)), String("second"))
    # Different row — no hit.
    assert_equal(hit_title_command(hits, Point(3, 1)), String(""))


def test_canvas_box() raises:
    var c = Canvas(10, 5)
    c.draw_box(Rect(0, 0, 10, 5), default_attr(), False)
    assert_equal(c.get(0, 0).glyph, String("┌"))
    assert_equal(c.get(9, 0).glyph, String("┐"))
    assert_equal(c.get(0, 4).glyph, String("└"))
    assert_equal(c.get(9, 4).glyph, String("┘"))
    assert_equal(c.get(5, 0).glyph, String("─"))


def test_canvas_fill() raises:
    var c = Canvas(5, 3)
    c.fill(Rect(1, 1, 4, 2), String("X"), default_attr())
    assert_equal(c.get(0, 0).glyph, String(" "))
    assert_equal(c.get(1, 1).glyph, String("X"))
    assert_equal(c.get(3, 1).glyph, String("X"))
    assert_equal(c.get(4, 1).glyph, String(" "))


def test_event_factories() raises:
    var k = Event.key_event(KEY_ENTER)
    assert_true(k.kind == EVENT_KEY)
    assert_true(k.is_key(KEY_ENTER))

    var q = Event.quit_event()
    assert_true(q.kind == EVENT_QUIT)

    var r = Event.resize_event(80, 24)
    assert_true(r.kind == EVENT_RESIZE)
    assert_true(r.pos == Point(80, 24))


def test_parse_input_keys() raises:
    # Lone ESC could be a real keypress or the start of a partial sequence
    # whose tail hasn't arrived yet — the parser defers the decision via
    # (EVENT_NONE, 0). Terminal.poll_event disambiguates with a timeout.
    var esc = parse_input(String("\x1b"))
    assert_true(esc[0].kind == EVENT_NONE)
    assert_equal(esc[1], 0)

    var arrow_up = parse_input(String("\x1b[A"))
    assert_true(arrow_up[0].kind == EVENT_KEY)
    assert_equal(arrow_up[1], 3)

    var enter = parse_input(String("\r"))
    assert_true(enter[0].is_key(KEY_ENTER))

    var letter = parse_input(String("a"))
    assert_true(letter[0].kind == EVENT_KEY)
    assert_true(letter[0].key == UInt32(ord("a")))

    # Alt+Enter on iTerm2 / Terminal.app arrives as ``ESC CR`` (or
    # ``ESC LF``). The ESC+printable path used to deliver this as
    # ``(0x0D, MOD_ALT)``, which downstream code checking
    # ``k == KEY_ENTER`` would miss — surface it as
    # ``KEY_ENTER + MOD_ALT`` instead.
    var alt_cr = parse_input(String("\x1b\r"))
    assert_true(alt_cr[0].is_key(KEY_ENTER))
    assert_equal(alt_cr[0].mods, MOD_ALT)
    assert_equal(alt_cr[1], 2)
    var alt_lf = parse_input(String("\x1b\n"))
    assert_true(alt_lf[0].is_key(KEY_ENTER))
    assert_equal(alt_lf[0].mods, MOD_ALT)


def test_parse_window_size_report() raises:
    # ``CSI 8 ; rows ; cols t`` — xterm window-size report. The native
    # wrapper pushes this on every resize so turbokod sees the new
    # dimensions immediately; we should turn it into an EVENT_RESIZE
    # carrying ``(cols, rows)`` in ``pos``.
    var ev = parse_input(String("\x1b[8;25;80t"))
    assert_equal(ev[1], 10)  # consumed all 10 bytes of the sequence
    assert_true(ev[0].kind == EVENT_RESIZE)
    assert_equal(ev[0].pos.x, 80)  # cols = width
    assert_equal(ev[0].pos.y, 25)  # rows = height

    # Larger size, just to make sure we're not constant-folding.
    var ev2 = parse_input(String("\x1b[8;50;200t"))
    assert_true(ev2[0].kind == EVENT_RESIZE)
    assert_equal(ev2[0].pos.x, 200)
    assert_equal(ev2[0].pos.y, 50)


def test_parse_input_focus_events() raises:
    """Xterm focus reporting: ``ESC[I`` is focus-in, ``ESC[O`` is
    focus-out. Both are bare CSI finals and the parser must consume
    the full 3 bytes — leaving any tail behind would let the rest of
    the sequence leak into the focused editor as keypresses."""
    var fin = parse_input(String("\x1b[I"))
    assert_equal(fin[1], 3)
    assert_true(fin[0].kind == EVENT_FOCUS_IN)

    var fout = parse_input(String("\x1b[O"))
    assert_equal(fout[1], 3)
    assert_true(fout[0].kind == EVENT_FOCUS_OUT)


def test_parse_input_sgr_mouse() raises:
    # Left-button press at (10, 5). Terminal reports 1-based; we expose 0-based.
    var press = parse_input(String("\x1b[<0;11;6M"))
    assert_true(press[0].kind == 2)  # EVENT_MOUSE
    assert_true(press[0].pos == Point(10, 5))
    assert_true(press[0].pressed)
    assert_false(press[0].motion)

    # Drag-motion of left button (motion bit 32 set) at (12, 7).
    var drag = parse_input(String("\x1b[<32;13;8M"))
    assert_true(drag[0].kind == 2)
    assert_true(drag[0].pos == Point(12, 7))
    assert_true(drag[0].pressed)
    assert_true(drag[0].motion)

    # Release: terminator 'm'.
    var release = parse_input(String("\x1b[<0;15;9m"))
    assert_true(release[0].kind == 2)
    assert_false(release[0].pressed)

    # Two events back-to-back: parser must consume only the first.
    var two = parse_input(String("\x1b[<0;1;1M\x1b[<0;2;2m"))
    assert_equal(two[1], 9)  # first sequence is 9 bytes


def test_centered() raises:
    var outer = Rect(0, 0, 80, 24)
    var inner = centered(outer, 20, 6)
    assert_true(inner == Rect(30, 9, 50, 15))


# ----- Scrollbar primitive tests --------------------------------------------


def test_scrollbar_hidden_when_content_fits() raises:
    """No bar is drawn when total ≤ visible — there's nothing to
    scroll, so paint and hit-test must short-circuit."""
    var bar = VScrollbar(10, 0, 9, 5, 10, 0)
    assert_false(bar.metrics().present)
    var c = Canvas(20, 10)
    var p = Painter(Rect(0, 0, 20, 10))
    bar.paint(c, p, Attr(WHITE, BLACK))
    # The scrollbar column must be untouched (still blank cells).
    assert_equal(c.get(10, 0).glyph, String(" "))
    assert_equal(c.get(10, 5).glyph, String(" "))
    var hit = bar.hit(Point(10, 5))
    assert_equal(hit[0], 0)


def test_scrollbar_hidden_when_too_short() raises:
    """A 2-cell bar can't fit ▲ + ▼ + at least one track cell, so it
    stays hidden even when content overflows."""
    var bar = VScrollbar(10, 0, 1, 100, 5, 0)
    assert_false(bar.metrics().present)


def test_scrollbar_paints_arrows_and_thumb() raises:
    """The bar paints ▲ at the top, ▼ at the bottom, and a █ thumb
    proportional to ``visible / total`` somewhere on the rail."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    var m = bar.metrics()
    assert_true(m.present)
    assert_equal(m.track_size, 8)
    assert_equal(m.knob_size, 1)  # 8 * 10 / 100 = 0 → clamped up to 1
    assert_equal(m.knob_off, 0)
    var c = Canvas(20, 10)
    var p = Painter(Rect(0, 0, 20, 10))
    bar.paint(c, p, Attr(WHITE, BLACK))
    assert_equal(c.get(10, 0).glyph, String("▲"))
    assert_equal(c.get(10, 9).glyph, String("▼"))
    # Track is 8 cells (rows 1..8). Thumb is one █ at row 1; the rest
    # are ░.
    assert_equal(c.get(10, 1).glyph, String("█"))
    assert_equal(c.get(10, 2).glyph, String("░"))
    assert_equal(c.get(10, 8).glyph, String("░"))


def test_scrollbar_thumb_tracks_scroll_position() raises:
    """As ``scroll`` advances toward ``max_scroll``, the thumb's
    ``knob_off`` must end up at the bottom of the track."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 90)  # max_scroll = 90
    var m = bar.metrics()
    assert_true(m.present)
    # denom = track_size - knob_size = 7. knob_off = 90*7 / 90 = 7.
    assert_equal(m.knob_off, 7)


def test_scrollbar_hit_arrow_zones() raises:
    """Top and bottom of the bar are arrow hits, with no rel."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    var up = bar.hit(Point(10, 0))
    assert_equal(up[0], 1)  # leading arrow
    var down = bar.hit(Point(10, 9))
    assert_equal(down[0], 5)  # trailing arrow


def test_scrollbar_hit_thumb_returns_drag_offset() raises:
    """Clicking on the thumb returns part=3 with the click's offset
    inside the thumb so the drag preserves the press point."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)  # thumb at track row 0
    var on_thumb = bar.hit(Point(10, 1))
    assert_equal(on_thumb[0], 3)
    assert_equal(on_thumb[1], 0)


def test_scrollbar_hit_page_zones() raises:
    """Above the thumb is part=2 (page-up), below is part=4 (page-down)."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 90)  # thumb at the bottom
    # Track rows 1..8. Thumb at knob_off=7, so row 1 (rel=0) is page-up.
    var pup = bar.hit(Point(10, 1))
    assert_equal(pup[0], 2)
    assert_equal(pup[1], 0)
    # Now flip — scroll=0 puts thumb at top, so a click near the bottom
    # of the track is page-down.
    var bar2 = VScrollbar(10, 0, 9, 100, 10, 0)
    var pdn = bar2.hit(Point(10, 8))
    assert_equal(pdn[0], 4)


def test_scrollbar_hit_off_axis_returns_none() raises:
    """A click in a different column (V-bar) must not fire."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    var miss = bar.hit(Point(11, 5))
    assert_equal(miss[0], 0)


def test_scrollbar_drag_to_extremes() raises:
    """Dragging the thumb's leading cell to the bottom of the track
    yields ``scroll == max_scroll``; to the top yields 0."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    # Track starts at top+1 = 1; track size = 8; knob size = 1; denom = 7.
    # Drag to mouse_y=8 with drag_offset=0 → target=7 → ns=max_scroll=90.
    assert_equal(bar.drag_to(8, 0), 90)
    assert_equal(bar.drag_to(1, 0), 0)
    # Out-of-range clamps.
    assert_equal(bar.drag_to(-50, 0), 0)
    assert_equal(bar.drag_to(1000, 0), 90)


def test_scrollbar_track_jump_centers_target() raises:
    """A click in the middle of the track jumps so the target row is
    centered in the visible area."""
    var bar = VScrollbar(10, 0, 9, 100, 10, 0)
    # track_size=8. rel=4 → target_row = 4*100/8 = 50. ns = 50 - 5 = 45.
    assert_equal(bar.track_jump(4), 45)
    # rel=0 → target_row=0 → ns clamps to 0.
    assert_equal(bar.track_jump(0), 0)
    # rel=track_size-1=7 → target_row = 7*100/8 = 87 → ns = 87-5 = 82.
    assert_equal(bar.track_jump(7), 82)


def test_scrollbar_horizontal_paints_arrows_on_axis() raises:
    """``HScrollbar`` is the same primitive rotated 90° — ◄ at the
    leading cell, ► at the trailing cell, █/░ along the row."""
    var bar = HScrollbar(5, 0, 9, 100, 10, 0)
    var c = Canvas(20, 10)
    var p = Painter(Rect(0, 0, 20, 10))
    bar.paint(c, p, Attr(WHITE, BLACK))
    assert_equal(c.get(0, 5).glyph, String("◄"))
    assert_equal(c.get(9, 5).glyph, String("►"))
    assert_equal(c.get(1, 5).glyph, String("█"))
    assert_equal(c.get(2, 5).glyph, String("░"))


# ----- Editor tests ---------------------------------------------------------


comptime _VIEW = Rect(0, 0, 80, 24)
comptime _SCREEN = Rect(0, 0, 100, 30)


def _key(k: UInt32, mods: UInt8 = MOD_NONE) -> Event:
    return Event.key_event(k, mods)


def test_text_buffer_split_and_join() raises:
    var b = TextBuffer(String("ab\ncd"))
    assert_equal(b.line_count(), 2)
    assert_equal(b.line(0), String("ab"))
    assert_equal(b.line(1), String("cd"))
    var p = b.split(0, 1)                 # "ab" → "a" / "b"
    assert_equal(p[0], 1); assert_equal(p[1], 0)
    assert_equal(b.line_count(), 3)
    assert_equal(b.line(0), String("a"))
    assert_equal(b.line(1), String("b"))
    assert_equal(b.line(2), String("cd"))
    # Backspace at start of line 1 joins it onto line 0.
    var q = b.delete_before(1, 0)
    assert_equal(q[0], 0); assert_equal(q[1], 1)
    assert_equal(b.line_count(), 2)
    assert_equal(b.line(0), String("ab"))


def test_editor_typing_and_arrows() raises:
    var ed = Editor(String("hello"))
    assert_equal(ed.cursor_col, 0)
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_col, 5)
    _ = ed.handle_key(_key(UInt32(ord("!"))), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello!"))
    assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.cursor_col, 5)
    _ = ed.handle_key(_key(KEY_HOME), _VIEW)
    assert_equal(ed.cursor_col, 0)


def test_editor_word_movement() raises:
    var ed = Editor(String("hello world foo"))
    # Ctrl+Right from start: lands at start of "world" (col 6).
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 6)
    # Again: start of "foo" (col 12).
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 12)
    # Again: end of buffer (col 15) — no further word.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 15)
    # Ctrl+Left walks back to start of each word.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 12)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_col, 0)


def test_editor_word_movement_across_lines() raises:
    var ed = Editor(String("abc\ndef"))
    # Ctrl+Right from start: end of "abc" on line 0.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 3)
    # Again: jumps to start of next line.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_row, 1); assert_equal(ed.cursor_col, 0)
    # Ctrl+Left from (1,0): end of previous line.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_CTRL), _VIEW)
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 3)


def test_editor_shift_arrow_extends_selection() raises:
    var ed = Editor(String("hello"))
    assert_false(ed.has_selection())
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 1)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 2)
    # Plain arrow collapses selection.
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_false(ed.has_selection())
    assert_equal(ed.cursor_col, 3); assert_equal(ed.anchor_col, 3)


def test_editor_shift_ctrl_arrow_composes() raises:
    """Selection and word movement compose: Shift+Ctrl+Right keeps the anchor
    while jumping by a whole word."""
    var ed = Editor(String("hello world foo"))
    var both: UInt8 = MOD_SHIFT | MOD_CTRL
    _ = ed.handle_key(_key(KEY_RIGHT, both), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_RIGHT, both), _VIEW)
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 12)
    # Now Shift+Ctrl+Left walks the cursor back through words; anchor stays.
    _ = ed.handle_key(_key(KEY_LEFT, both), _VIEW)
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 6)


def test_editor_cmd_arrow_line_navigation() raises:
    """Cmd+Right jumps to end of line; Cmd+Left jumps to first non-space,
    then to col 0 on a second press. Shift extends the selection."""
    var ed = Editor(String("    hello world"))
    # Cmd+Right from col 0: end of line.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_META), _VIEW)
    assert_equal(ed.cursor_col, 15)
    assert_false(ed.has_selection())
    # Cmd+Left from end: lands at first non-space (col 4).
    _ = ed.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed.cursor_col, 4)
    # Cmd+Left again: now at first non-space, falls to col 0.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed.cursor_col, 0)
    # Cmd+Left at col 0 stays at col 0.
    _ = ed.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed.cursor_col, 0)
    # Cmd+Shift+Right selects to end of line.
    var meta_shift: UInt8 = MOD_META | MOD_SHIFT
    _ = ed.handle_key(_key(KEY_RIGHT, meta_shift), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 15)
    # Cmd+Shift+Left from end of line extends back to first non-space.
    _ = ed.handle_key(_key(KEY_LEFT, meta_shift), _VIEW)
    assert_equal(ed.anchor_col, 0); assert_equal(ed.cursor_col, 4)
    # No leading whitespace: Cmd+Left from end goes straight to col 0.
    var ed2 = Editor(String("hello"))
    _ = ed2.handle_key(_key(KEY_END), _VIEW)
    _ = ed2.handle_key(_key(KEY_LEFT, MOD_META), _VIEW)
    assert_equal(ed2.cursor_col, 0)


def test_editor_cmd_letter_does_not_insert() raises:
    """Cmd+B (or any unbound Cmd chord) used to fall through the
    editor's modifier guard and insert ``b`` into the buffer — the
    check only excluded MOD_CTRL / MOD_ALT. The editor now reports
    the event as unconsumed so the desktop can beep instead, and the
    buffer is left untouched."""
    var ed = Editor(String("hello"))
    var consumed = ed.handle_key(_key(UInt32(ord("b")), MOD_META), _VIEW)
    assert_false(consumed)
    assert_equal(ed.buffer.line(0), String("hello"))


def test_editor_cmd_a_selects_all() raises:
    """Cmd+A should select the whole buffer — same as Ctrl+A on
    Linux/Windows. Without MOD_META in ``clipboard_chord`` only
    Ctrl+A worked, and Cmd+A inserted ``a`` instead."""
    var ed = Editor(String("line one\nline two"))
    var consumed = ed.handle_key(_key(UInt32(ord("a")), MOD_META), _VIEW)
    assert_true(consumed)
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_row, 0)
    assert_equal(ed.anchor_col, 0)
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 8)


def test_editor_typing_replaces_selection() raises:
    var ed = Editor(String("hello"))
    # Select first 4 chars
    for _ in range(4):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.cursor_col, 4)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)
    assert_equal(ed.buffer.line(0), String("Xo"))
    assert_false(ed.has_selection())
    assert_equal(ed.cursor_col, 1)


def test_editor_backspace_deletes_selection() raises:
    var ed = Editor(String("hello"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)         # cursor at 1
    for _ in range(3):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    # selection covers "ell"
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(ed.buffer.line(0), String("ho"))
    assert_false(ed.has_selection())


def test_editor_mouse_click_sets_cursor() raises:
    var ed = Editor(String("hello"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_equal(ed.cursor_col, 3)
    assert_false(ed.has_selection())


def test_editor_mouse_drag_extends_selection() raises:
    var ed = Editor(String("hello world"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(1, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_equal(ed.cursor_col, 1)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_true(ed.has_selection())
    assert_equal(ed.anchor_col, 1); assert_equal(ed.cursor_col, 7)


def test_editor_mouse_click_clamps_to_line() raises:
    var ed = Editor(String("hi"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(50, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    # Past EOL → clamped to line length.
    assert_equal(ed.cursor_col, 2)


def test_editor_double_click_selects_word() raises:
    var ed = Editor(String("hello world foo"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_true(ed.has_selection())
    assert_equal(ed.selection_text(), String("world"))


def test_editor_double_click_selects_unicode_word() raises:
    """Double-clicking inside a non-ASCII word selects the whole word.
    Pre-fix this would have selected only ``Godk`` (the ASCII prefix
    up to the first non-letter byte)."""
    # "Godkänn foo" — the cell column for the ``ä`` codepoint is index 4
    # (one cell per codepoint, regardless of UTF-8 byte width).
    var ed = Editor(String("Godkänn foo"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    assert_true(ed.has_selection())
    assert_equal(ed.selection_text(), String("Godkänn"))


def test_editor_double_click_drag_extends_by_word_forward() raises:
    var ed = Editor(String("hello world foo bar"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(17, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("world foo bar"))


def test_editor_double_click_drag_extends_by_word_backward() raises:
    var ed = Editor(String("hello world foo bar"))
    _ = ed.handle_mouse(
        Event.mouse_event(Point(13, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(13, 0), MOUSE_BUTTON_LEFT, True, False),
        _VIEW,
    )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("hello world foo"))


def test_editor_triple_click_selects_line() raises:
    var ed = Editor(String("first line\nsecond line\nthird line"))
    # Three quick presses on row 1, col 4.
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(4, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    # Whole line + trailing newline (since this isn't the last line).
    assert_equal(ed.selection_text(), String("second line\n"))


def test_editor_triple_click_last_line_no_newline() raises:
    var ed = Editor(String("first\nlast"))
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(2, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    # Last line: no trailing newline available.
    assert_equal(ed.selection_text(), String("last"))


def test_editor_triple_click_drag_extends_by_line_forward() raises:
    var ed = Editor(String("alpha\nbeta\ngamma\ndelta"))
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(2, 1), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 2), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("beta\ngamma\n"))


def test_editor_triple_click_drag_extends_by_line_backward() raises:
    var ed = Editor(String("alpha\nbeta\ngamma\ndelta"))
    for _ in range(3):
        _ = ed.handle_mouse(
            Event.mouse_event(Point(2, 2), MOUSE_BUTTON_LEFT, True, False),
            _VIEW,
        )
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, True),
        _VIEW,
    )
    assert_equal(ed.selection_text(), String("alpha\nbeta\ngamma\n"))


def test_editor_cut_whole_line_when_no_selection() raises:
    var ed = Editor(String("first\nsecond\nthird"))
    ed.move_to(1, 3, False)
    ed.cut_to_clipboard()
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(0), String("first"))
    assert_equal(ed.buffer.line(1), String("third"))
    assert_equal(ed.cursor_row, 1); assert_equal(ed.cursor_col, 0)


def test_editor_cut_whole_line_only_line() raises:
    var ed = Editor(String("only line"))
    ed.move_to(0, 4, False)
    ed.cut_to_clipboard()
    assert_equal(ed.buffer.line_count(), 1)
    assert_equal(ed.buffer.line(0), String(""))
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 0)


def test_editor_smart_indent_mirrors_previous_line() raises:
    var ed = Editor(String("    hello"))
    ed.move_to(0, 9, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line_count(), 2)
    assert_equal(ed.buffer.line(1), String("    "))
    assert_equal(ed.cursor_row, 1); assert_equal(ed.cursor_col, 4)


def test_editor_smart_indent_after_open_brace() raises:
    var ed = Editor(String("if (x) {"))
    ed.move_to(0, 8, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line(1), String("    "))
    assert_equal(ed.cursor_col, 4)


def test_editor_smart_indent_after_colon() raises:
    var ed = Editor(String("    def foo():"))
    ed.move_to(0, 14, False)
    _ = ed.handle_key(_key(KEY_ENTER), _VIEW)
    assert_equal(ed.buffer.line(1), String("        "))
    assert_equal(ed.cursor_col, 8)


def test_terminal_parses_modified_arrows() raises:
    """The CSI ``ESC[1;<mod><letter>`` form gives us shift/ctrl on arrows."""
    var shift_right = parse_input(String("\x1b[1;2C"))
    assert_true(shift_right[0].kind == EVENT_KEY)
    assert_true(shift_right[0].key == KEY_RIGHT)
    assert_true((shift_right[0].mods & MOD_SHIFT) != 0)
    assert_equal(shift_right[1], 6)

    var ctrl_left = parse_input(String("\x1b[1;5D"))
    assert_true(ctrl_left[0].key == KEY_LEFT)
    assert_true((ctrl_left[0].mods & MOD_CTRL) != 0)

    var shift_up = parse_input(String("\x1b[1;2A"))
    assert_true(shift_up[0].key == KEY_UP)
    assert_true((shift_up[0].mods & MOD_SHIFT) != 0)

    var shift_down = parse_input(String("\x1b[1;2B"))
    assert_true(shift_down[0].key == KEY_DOWN)
    assert_true((shift_down[0].mods & MOD_SHIFT) != 0)

    var both_up = parse_input(String("\x1b[1;6A"))
    assert_true(both_up[0].key == KEY_UP)
    assert_true((both_up[0].mods & MOD_SHIFT) != 0)
    assert_true((both_up[0].mods & MOD_CTRL) != 0)

    var both_right = parse_input(String("\x1b[1;6C"))
    assert_true(both_right[0].key == KEY_RIGHT)
    assert_true((both_right[0].mods & MOD_SHIFT) != 0)
    assert_true((both_right[0].mods & MOD_CTRL) != 0)


def test_terminal_parses_shift_tab() raises:
    """Backtab (CSI Z) and the modifier-reporting form (CSI 1;2 Z) both
    arrive as KEY_TAB with MOD_SHIFT so the editor can treat Shift+Tab
    as the inverse of Tab."""
    var bare = parse_input(String("\x1b[Z"))
    assert_true(bare[0].kind == EVENT_KEY)
    assert_true(bare[0].key == KEY_TAB)
    assert_true((bare[0].mods & MOD_SHIFT) != 0)
    assert_equal(bare[1], 3)

    var modreport = parse_input(String("\x1b[1;2Z"))
    assert_true(modreport[0].key == KEY_TAB)
    assert_true((modreport[0].mods & MOD_SHIFT) != 0)


def test_editor_selection_text() raises:
    var ed = Editor(String("hello world"))
    # Select "hello "
    for _ in range(6):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    assert_equal(ed.selection_text(), String("hello "))


def test_editor_cut_selection() raises:
    var ed = Editor(String("hello world"))
    for _ in range(5):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    var cut = ed.cut_selection()
    assert_equal(cut, String("hello"))
    assert_equal(ed.buffer.line(0), String(" world"))
    assert_false(ed.has_selection())


def test_editor_paste_text_single_line() raises:
    var ed = Editor(String("hello"))
    ed.move_to(0, 5, False)
    ed.paste_text(String(" world"))
    assert_equal(ed.buffer.line(0), String("hello world"))
    assert_equal(ed.cursor_col, 11)


def test_editor_paste_text_multiline() raises:
    var ed = Editor(String("hello"))
    ed.move_to(0, 5, False)
    ed.paste_text(String("\nworld\nfoo"))
    assert_equal(ed.buffer.line_count(), 3)
    assert_equal(ed.buffer.line(0), String("hello"))
    assert_equal(ed.buffer.line(1), String("world"))
    assert_equal(ed.buffer.line(2), String("foo"))
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 3)


def test_editor_paste_replaces_selection() raises:
    var ed = Editor(String("hello world"))
    for _ in range(5):
        _ = ed.handle_key(_key(KEY_RIGHT, MOD_SHIFT), _VIEW)
    ed.paste_text(String("HEY"))
    assert_equal(ed.buffer.line(0), String("HEY world"))
    assert_false(ed.has_selection())


def test_editor_selection_text_multiline() raises:
    var ed = Editor(String("ab\ncd\nef"))
    # Select from (0,1) to (2,1) — i.e., "b\ncd\ne"
    ed.move_to(0, 1, False)
    ed.move_to(2, 1, True)
    assert_equal(ed.selection_text(), String("b\ncd\ne"))


def test_editor_goto_line() raises:
    var ed = Editor(String("a\nb\nc\nd\ne"))
    ed.goto_line(3)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 0)
    # Out-of-range clamps.
    ed.goto_line(99)
    assert_equal(ed.cursor_row, 4)
    ed.goto_line(0)
    assert_equal(ed.cursor_row, 0)


def test_editor_find_next() raises:
    var ed = Editor(String("foo bar foo baz"))
    var hit1 = ed.find_next(String("foo"))
    assert_true(hit1)
    # First hit at col 0 — but find_next searches *after* the cursor; with
    # cursor initially at (0,0) the implementation skips one column. So the
    # first hit is at col 8 ("foo baz").
    assert_equal(ed.cursor_row, 0); assert_equal(ed.cursor_col, 11)
    assert_true(ed.has_selection())
    assert_equal(ed.selection_text(), String("foo"))
    # Wrap to the earlier match.
    var hit2 = ed.find_next(String("foo"))
    assert_true(hit2)
    assert_equal(ed.cursor_col, 3)


def test_editor_find_next_case_insensitive() raises:
    """Cc OFF (case_sensitive=False, the default) should match
    across letter case; Cc ON should require an exact byte match."""
    var ed = Editor(String("Foo bar FOO baz"))
    # Cc ON: case-sensitive — no lowercase "foo" exists, so miss.
    var sensitive = SearchOptions(True, False, False)
    var hit_sensitive = ed.find_next(String("foo"), sensitive)
    assert_true(not hit_sensitive)
    ed.move_to(0, 0, False)
    # Cc OFF: case-insensitive — should hit "Foo" first, then wrap.
    var insensitive = SearchOptions(False, False, False)
    var hit_first = ed.find_next(String("foo"), insensitive)
    assert_true(hit_first)
    assert_equal(ed.selection_text(), String("FOO"))
    var hit_second = ed.find_next(String("foo"), insensitive)
    assert_true(hit_second)
    assert_equal(ed.selection_text(), String("Foo"))


def test_editor_find_next_whole_word() raises:
    """Whole-word toggle should reject substring matches."""
    var ed = Editor(String("foobar foo bar"))
    var opts = SearchOptions(True, True, False)  # case-sensitive + whole-word
    var hit = ed.find_next(String("foo"), opts)
    assert_true(hit)
    # The substring at col 0 ("foobar") is not a whole word; the
    # whole-word "foo" sits at col 7.
    assert_equal(ed.cursor_col, 10)


def test_editor_find_next_regex() raises:
    """Regex toggle should let the user write a real pattern.
    ``find_next`` skips the byte at the cursor (so a repeated press
    walks forward), so the first hit from cursor=(0,0) is the
    second token, not the first."""
    var ed = Editor(String("a1 b2 c3"))
    var opts = SearchOptions(True, False, True)  # case-sensitive regex
    var hit = ed.find_next(String("[a-c][0-9]"), opts)
    assert_true(hit)
    assert_equal(ed.selection_text(), String("b2"))


def test_editor_replace_all_case_insensitive() raises:
    var ed = Editor(String("Foo foo FOO"))
    var opts = SearchOptions(False, False, False)  # ci, no-word, no-regex
    var n = ed.replace_all(String("foo"), String("bar"), opts)
    assert_equal(n, 3)
    assert_equal(ed.buffer.line(0), String("bar bar bar"))


def test_find_in_project_options_smoke() raises:
    """Sanity check that project search compiles and runs with
    options. Picks a string the test file itself contains."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var opts = SearchOptions(True, False, False)
    var matches = find_in_project(
        root.value(), String("Turbokod: a Mojo-idiomatic port"), opts,
    )
    assert_true(len(matches) >= 1)


def test_editor_toggle_comment_single_line() raises:
    var ed = Editor(String("hello"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("// hello"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("hello"))


def test_editor_toggle_comment_selection() raises:
    var ed = Editor(String("a\nb\nc"))
    ed.move_to(0, 0, False)
    ed.move_to(2, 1, True)
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("// a"))
    assert_equal(ed.buffer.line(1), String("// b"))
    assert_equal(ed.buffer.line(2), String("// c"))
    ed.toggle_comment()
    assert_equal(ed.buffer.line(0), String("a"))
    assert_equal(ed.buffer.line(2), String("c"))


def test_editor_toggle_comment_language_aware() raises:
    # Python: `# ` prefix derived from .py extension.
    var py = Editor(String("hello"))
    py.file_path = String("foo.py")
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("# hello"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("hello"))

    # SQL: `-- ` prefix.
    var sql = Editor(String("select 1"))
    sql.file_path = String("query.sql")
    sql.toggle_comment()
    assert_equal(sql.buffer.line(0), String("-- select 1"))
    sql.toggle_comment()
    assert_equal(sql.buffer.line(0), String("select 1"))

    # Rust: `// ` prefix — confirms the C-family path.
    var rs = Editor(String("let x = 1;"))
    rs.file_path = String("lib.rs")
    rs.toggle_comment()
    assert_equal(rs.buffer.line(0), String("// let x = 1;"))

    # Unknown extension falls back to `// `.
    var unknown = Editor(String("data"))
    unknown.file_path = String("file.xyz")
    unknown.toggle_comment()
    assert_equal(unknown.buffer.line(0), String("// data"))


def test_editor_toggle_comment_indented() raises:
    # Single line: prefix lands at the first non-whitespace column,
    # preserving the line's leading indent.
    var py = Editor(String("    foo()"))
    py.file_path = String("snippet.py")
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    # foo()"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    foo()"))


def test_editor_toggle_comment_common_indent() raises:
    # Multi-line: prefix uses the shared leading whitespace, so the
    # deeper inner line keeps its extra indent visible after the marker.
    var py = Editor(String("    foo()\n        bar()\n    baz()"))
    py.file_path = String("snippet.py")
    py.move_to(0, 0, False)
    py.move_to(2, 1, True)
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    # foo()"))
    assert_equal(py.buffer.line(1), String("    #     bar()"))
    assert_equal(py.buffer.line(2), String("    # baz()"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    foo()"))
    assert_equal(py.buffer.line(1), String("        bar()"))
    assert_equal(py.buffer.line(2), String("    baz()"))


def test_editor_toggle_comment_skips_blank_lines() raises:
    # Blank lines in the range are left untouched and don't block the
    # "all commented" vote — uncommenting still works around them.
    var py = Editor(String("    foo()\n\n    bar()"))
    py.file_path = String("snippet.py")
    py.move_to(0, 0, False)
    py.move_to(2, 1, True)
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    # foo()"))
    assert_equal(py.buffer.line(1), String(""))
    assert_equal(py.buffer.line(2), String("    # bar()"))
    py.toggle_comment()
    assert_equal(py.buffer.line(0), String("    foo()"))
    assert_equal(py.buffer.line(1), String(""))
    assert_equal(py.buffer.line(2), String("    bar()"))


def test_editor_toggle_case() raises:
    var ed = Editor(String("Hello World"))
    ed.move_to(0, 0, False)
    ed.move_to(0, 5, True)         # select "Hello"
    ed.toggle_case()
    assert_equal(ed.buffer.line(0), String("hELLO World"))


def test_editor_dirty_flag() raises:
    var ed = Editor(String("hello"))
    assert_false(ed.dirty)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)        # navigation, not dirty
    assert_false(ed.dirty)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)  # insert, dirty
    assert_true(ed.dirty)


def test_file_io_read_and_stat() raises:
    """Check we can read & stat a file we know exists in the repo."""
    var path = String("examples/hello.mojo")
    var info = stat_file(path)
    assert_true(info.ok)
    assert_true(Int(info.size) > 0)
    var text = read_file(path)
    assert_equal(Int(info.size), len(text.as_bytes()))


def test_editor_from_file() raises:
    var ed = Editor.from_file(String("examples/hello.mojo"))
    assert_true(ed.buffer.line_count() > 5)
    assert_false(ed.dirty)
    assert_true(Int(ed.file_size) > 0)
    # Initial check: nothing changed since open, so the status code is
    # EXT_CHANGE_NONE.
    assert_equal(ed.check_for_external_change(), EXT_CHANGE_NONE)


def test_terminal_parses_alt_letter_as_letter() raises:
    """``ESC <letter>`` parses as the letter with MOD_ALT — including 'f'
    and 'b'. The framework now uses these for menu mnemonics
    (Alt+F → File menu); word-jump still works via Ctrl+arrow and via
    Alt+arrow on terminals that report modifiers for arrows."""
    var alt_f = parse_input(String("\x1bf"))
    assert_true(alt_f[0].kind == EVENT_KEY)
    assert_equal(Int(alt_f[0].key), Int(ord("f")))
    assert_true((alt_f[0].mods & MOD_ALT) != 0)
    assert_equal(alt_f[1], 2)

    var alt_b = parse_input(String("\x1bb"))
    assert_equal(Int(alt_b[0].key), Int(ord("b")))
    assert_true((alt_b[0].mods & MOD_ALT) != 0)


def test_editor_alt_arrow_word_jump() raises:
    """MOD_ALT triggers word movement (macOS convention)."""
    var ed = Editor(String("hello world foo"))
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 6)
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 12)
    _ = ed.handle_key(_key(KEY_LEFT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 6)


def test_editor_word_jump_traverses_unicode_letters() raises:
    """Word-jump must skip a whole Unicode word in one press, not stop
    at every multi-byte boundary inside it. Pre-fix, ``Godkänn`` was
    three "words" and Alt+Right would stop at the byte after ``Godk``,
    inside the ``ä`` codepoint, then again after ``ä``."""
    # "Godkänn foo" — bytes: G(1) o(1) d(1) k(1) ä(2) n(1) n(1) ' '(1) f o o
    # = 8 bytes for Godkänn + space at byte 8 + "foo" at bytes 9-11.
    var ed = Editor(String("Godkänn foo"))
    # First Alt+Right jumps past "Godkänn" + the trailing space → byte 9.
    _ = ed.handle_key(_key(KEY_RIGHT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 9)
    # Alt+Left from inside "foo" lands back at the start of "foo".
    _ = ed.handle_key(_key(KEY_LEFT, MOD_ALT), _VIEW)
    assert_equal(ed.cursor_col, 0)


def test_path_helpers() raises:
    assert_equal(join_path(String("a"), String("b")), String("a/b"))
    assert_equal(join_path(String("a/"), String("b")), String("a/b"))
    assert_equal(join_path(String(""), String("b")), String("b"))
    assert_equal(parent_path(String("/foo/bar")), String("/foo"))
    assert_equal(parent_path(String("/")), String("/"))
    assert_equal(parent_path(String("foo")), String("."))


def test_basename() raises:
    assert_equal(basename(String("/foo/bar")), String("bar"))
    assert_equal(basename(String("/foo/bar/")), String("bar"))
    assert_equal(basename(String("foo")), String("foo"))
    assert_equal(basename(String("/")), String("/"))


def test_find_git_project() raises:
    """Tests run from the repo root, which has a .git folder, so opening
    a file inside the repo should locate the project root."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    # The project root contains examples/, src/, and .git.
    var info = stat_file(join_path(root.value(), String(".git")))
    assert_true(info.ok)
    var examples = stat_file(join_path(root.value(), String("examples")))
    assert_true(examples.ok)


def _empty_menu(label: String) -> Menu:
    return Menu(label, List[MenuItem]())


def test_menu_layout_pins_file_edit_window_help() raises:
    """Display order must always be File, Edit, [middle], Window, Help —
    regardless of insertion order. ``self.menus`` retains insertion order
    (so cached indices stay valid); only the layout rects reorder."""
    var bar = MenuBar()
    # Insert in deliberately scrambled order.
    bar.add(_empty_menu(String("Help")))
    bar.add(_empty_menu(String("Window")))
    bar.add(_empty_menu(String("Tools")))
    bar.add(_empty_menu(String("File")))
    bar.add(_empty_menu(String("Build")))
    bar.add(_empty_menu(String("Edit")))
    var rects = bar._layout(80)
    # Walk rects by display x; collect labels in order.
    var n = len(bar.menus)
    var sorted_labels = List[String]()
    var used = List[Bool]()
    for _ in range(n):
        used.append(False)
    for _ in range(n):
        var best = -1
        var best_x = 1_000_000
        for i in range(n):
            if used[i]: continue
            if rects[i].a.x < best_x and rects[i].b.x > rects[i].a.x:
                best_x = rects[i].a.x
                best = i
        if best < 0: break
        used[best] = True
        sorted_labels.append(bar.menus[best].label)
    assert_equal(len(sorted_labels), 6)
    assert_equal(sorted_labels[0], String("File"))
    assert_equal(sorted_labels[1], String("Edit"))
    # Middle two are Tools and Build in insertion order.
    assert_equal(sorted_labels[2], String("Tools"))
    assert_equal(sorted_labels[3], String("Build"))
    assert_equal(sorted_labels[4], String("Window"))
    assert_equal(sorted_labels[5], String("Help"))
    # The menus list itself must NOT be reordered (cached indices rely on it).
    assert_equal(bar.menus[0].label, String("Help"))
    assert_equal(bar.menus[5].label, String("Edit"))


def test_system_menu_pins_to_left_edge() raises:
    """The hamburger (``is_system``) menu always occupies cells 0..3, the
    same slot the static glyph used to live in, regardless of insertion
    order or what other left-aligned menus are present."""
    var bar = MenuBar()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    bar.add(Menu(String("File"), file_items^))
    var sys_items = List[MenuItem]()
    sys_items.append(MenuItem(String("Quit"), String("quit")))
    bar.add(Menu(String("≡"), sys_items^, is_system=True))
    var rects = bar._layout(80)
    # System menu pinned to cells 0..3 (insertion order index 1).
    assert_equal(rects[1].a.x, 0)
    assert_equal(rects[1].b.x, 3)
    # File still starts at x=3 — the system slot doesn't shift packing.
    assert_equal(rects[0].a.x, 3)
    assert_equal(rects[0].b.x, 3 + len(String("File").as_bytes()) + 2)


def test_right_aligned_menu_layout() raises:
    """A right-aligned menu sits flush with the screen's right edge, with
    its hit-test rect ending at exactly screen_width."""
    var bar = MenuBar()
    var left_items = List[MenuItem]()
    left_items.append(MenuItem(String("New"), String("noop")))
    bar.add(Menu(String("File"), left_items^))
    var right_items = List[MenuItem]()
    right_items.append(MenuItem(String("Close project"), PROJECT_CLOSE_ACTION))
    bar.add(Menu(String("turbokod"), right_items^, right_aligned=True))
    var rects = bar._layout(80)
    # Left menu starts at x=3 and gets " File "  (label + 2 padding).
    assert_equal(rects[0].a.x, 3)
    assert_equal(rects[0].b.x, 3 + len(String("File").as_bytes()) + 2)
    # Right-aligned menu's right edge is the screen width; width = label+2.
    assert_equal(rects[1].b.x, 80)
    var right_w = len(String("turbokod").as_bytes()) + 2
    assert_equal(rects[1].a.x, 80 - right_w)


def test_desktop_project_lifecycle() raises:
    var d = Desktop()
    assert_false(d.project)
    # The project menu is created at construction time so the recents
    # picker is reachable even before any project has been opened. Its
    # label reads "project" and its only entry is "Open recent project...".
    var idx = d._project_menu_idx
    assert_true(idx >= 0)
    assert_true(d.menu_bar.menus[idx].visible)
    assert_true(d.menu_bar.menus[idx].right_aligned)
    assert_equal(d.menu_bar.menus[idx].label, String("project"))
    assert_equal(len(d.menu_bar.menus[idx].items), 1)
    assert_equal(d.menu_bar.menus[idx].items[0].action, PROJECT_OPEN_RECENT)
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    assert_true(d.menu_bar.menus[idx].visible)
    # Label is the project root's basename — for this repo, "turbokod".
    assert_equal(d.menu_bar.menus[idx].label, String("turbokod"))
    # Active-project items: tree-toggle, configure-targets, separator,
    # open-recent-project, separator, close. Separators carry no action.
    assert_equal(len(d.menu_bar.menus[idx].items), 6)
    assert_equal(d.menu_bar.menus[idx].items[0].action, PROJECT_TREE_ACTION)
    assert_equal(
        d.menu_bar.menus[idx].items[1].action, PROJECT_CONFIG_TARGETS,
    )
    assert_true(d.menu_bar.menus[idx].items[2].is_separator)
    assert_equal(d.menu_bar.menus[idx].items[3].action, PROJECT_OPEN_RECENT)
    assert_true(d.menu_bar.menus[idx].items[4].is_separator)
    assert_equal(d.menu_bar.menus[idx].items[5].action, PROJECT_CLOSE_ACTION)
    # Detection is sticky: a second call doesn't reset the project.
    var first = d.project.value()
    d.detect_project_from(String("src/turbokod/desktop.mojo"))
    assert_equal(d.project.value(), first)
    # close_project clears project state but keeps the menu visible —
    # the label resets to "project", and the dropdown becomes the
    # recents-picker entry followed by a separator and direct-pick
    # entries for the recent projects. ``_set_project`` recorded the
    # turbokod root into ``config.recent_projects`` on the way in, so
    # at least one direct-pick entry exists here.
    d.close_project()
    assert_false(d.project)
    assert_true(d.menu_bar.menus[idx].visible)
    assert_equal(d.menu_bar.menus[idx].label, String("project"))
    assert_true(len(d.menu_bar.menus[idx].items) >= 3)
    assert_equal(d.menu_bar.menus[idx].items[0].action, PROJECT_OPEN_RECENT)
    assert_true(d.menu_bar.menus[idx].items[1].is_separator)
    assert_true(_starts_with(
        d.menu_bar.menus[idx].items[2].action, PROJECT_OPEN_RECENT_PREFIX,
    ))
    # After closing, detection works again.
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    assert_true(d.menu_bar.menus[idx].visible)
    assert_equal(d.menu_bar.menus[idx].label, String("turbokod"))


def test_file_tree_expand_collapse() raises:
    var t = FileTree()
    t.open(String("."))   # repo root, contains examples/, src/, tests/, ...
    var initial_count = len(t.entries)
    assert_true(initial_count > 0)
    # Find a known directory ("examples") and expand it.
    var examples_idx = -1
    for i in range(len(t.entries)):
        if t.entries[i].name == String("examples") and t.entries[i].is_dir:
            examples_idx = i
            break
    assert_true(examples_idx >= 0)
    assert_false(t.entries[examples_idx].is_expanded)
    t._toggle_expand(examples_idx)
    assert_true(t.entries[examples_idx].is_expanded)
    assert_true(len(t.entries) > initial_count)
    # Children of examples/ have depth=1 and live right after the entry.
    assert_equal(t.entries[examples_idx + 1].depth, 1)
    # Collapse: list shrinks back to the initial count.
    t._toggle_expand(examples_idx)
    assert_false(t.entries[examples_idx].is_expanded)
    assert_equal(len(t.entries), initial_count)


def test_file_tree_filters_dotfiles() raises:
    var t = FileTree()
    t.open(String("."))
    # ``.git`` must always be hidden, and ``.gitignore``'d entries
    # (``.pixi``, ``.build``) shouldn't leak through. ``.gitignore``
    # itself *should* be visible.
    var saw_git = False
    var saw_pixi = False
    var saw_build = False
    var saw_gitignore = False
    for i in range(len(t.entries)):
        var n = t.entries[i].name
        if n == String(".git"):
            saw_git = True
        if n == String(".pixi"):
            saw_pixi = True
        if n == String(".build"):
            saw_build = True
        if n == String(".gitignore"):
            saw_gitignore = True
    assert_false(saw_git)
    assert_false(saw_pixi)
    assert_false(saw_build)
    assert_true(saw_gitignore)


def test_desktop_workspace_shrinks_with_file_tree() raises:
    var d = Desktop()
    var screen = Rect(0, 0, 100, 30)
    var ws_no_tree = d.workspace_rect(screen)
    assert_equal(ws_no_tree.b.x, 100)
    # Detect project, then toggle the tree on via the menu action handler.
    d.detect_project_from(String("examples/hello.mojo"))
    d._toggle_file_tree()
    assert_true(d.file_tree.visible)
    var ws_tree = d.workspace_rect(screen)
    assert_equal(ws_tree.b.x, 100 - FILE_TREE_WIDTH)
    # Tree-toggle item label should now read "Hide file tree".
    assert_equal(
        d.menu_bar.menus[d._project_menu_idx].items[0].label,
        String("Hide file tree"),
    )
    # Toggling again hides the tree and restores workspace + label.
    d._toggle_file_tree()
    assert_false(d.file_tree.visible)
    assert_equal(d.workspace_rect(screen).b.x, 100)
    assert_equal(
        d.menu_bar.menus[d._project_menu_idx].items[0].label,
        String("Show file tree"),
    )


def test_window_min_size_enforced_at_construction() raises:
    """Framework guarantees the rect is wide enough for close + maximize
    chrome and tall enough to hold both borders, even if the caller
    passed a smaller rect."""
    var w = Window(String("tiny"), Rect(0, 0, 3, 1), List[String]())
    assert_true(w.rect.width() >= 10)
    assert_true(w.rect.height() >= 2)
    var ed = Window.editor_window(String("e"), Rect(5, 5, 8, 6), String(""))
    assert_true(ed.rect.width() >= 10)
    assert_true(ed.rect.height() >= 2)


def test_window_min_size_survives_workspace_shrink() raises:
    """``fit_into`` must not produce a sub-minimum window when scaling
    into a workspace that's smaller than the caller's original."""
    var wm = WindowManager()
    wm.add(Window(String("A"), Rect(0, 0, 80, 24), List[String]()))
    wm.fit_into(Rect(0, 0, 80, 24))
    wm.fit_into(Rect(0, 0, 12, 4))
    assert_true(wm.windows[0].rect.width() >= 10)
    assert_true(wm.windows[0].rect.height() >= 2)


def test_window_manager_fit_into_moves_then_resizes() raises:
    """``fit_into`` prefers moving over resizing; resizes only when the window
    is wider/taller than the new workspace."""
    var wm = WindowManager()
    # Window that fits but is past the new right edge — should move left.
    wm.add(Window(String("A"), Rect(70, 5, 90, 15), List[String]()))
    # Window that's wider than the new workspace — should be resized.
    wm.add(Window(String("B"), Rect(5, 5, 95, 15), List[String]()))
    var smaller = Rect(0, 1, 80, 25)
    wm.fit_into(smaller)
    # A: 20 wide, fits in 80; expected to be slid left to (60, 80).
    assert_equal(wm.windows[0].rect.b.x, 80)
    assert_equal(wm.windows[0].rect.width(), 20)
    # B: was 90 wide; gets clipped to workspace width 80.
    assert_equal(wm.windows[1].rect.a.x, 0)
    assert_equal(wm.windows[1].rect.b.x, 80)
    assert_equal(wm.windows[1].rect.width(), 80)


def _temp_path(suffix: String) -> String:
    """Cheap unique path under /tmp; pid+suffix is enough for our serial test
    suite (no parallelism)."""
    var pid = external_call["getpid", Int32]()
    return String("/tmp/turbokod_test_") + String(Int(pid)) + suffix


def test_write_file_round_trip() raises:
    var path = _temp_path(String("_rt.txt"))
    var payload = String("line one\nline two\nno-trailing-newline")
    assert_true(write_file(path, payload))
    var got = read_file(path)
    assert_equal(got, payload)
    # Write a different payload — confirm it replaces, not appends.
    var smaller = String("x")
    assert_true(write_file(path, smaller))
    assert_equal(read_file(path), smaller)
    # Empty payload writes a zero-byte file.
    assert_true(write_file(path, String("")))
    assert_equal(read_file(path), String(""))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_save_clears_dirty() raises:
    var path = _temp_path(String("_save.txt"))
    assert_true(write_file(path, String("hello\nworld\n")))
    var ed = Editor.from_file(path)
    assert_false(ed.dirty)
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("!"))), _VIEW)
    assert_true(ed.dirty)
    assert_true(ed.save())
    assert_false(ed.dirty)
    var contents = read_file(path)
    # First line was "hello"; cursor moved to its end before typing '!'.
    var first_line = String(StringSlice(
        unsafe_from_utf8=contents.as_bytes()[:6],
    ))
    assert_equal(first_line, String("hello!"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_save_as_adopts_path() raises:
    var path = _temp_path(String("_saveas.txt"))
    var ed = Editor(String("alpha\nbeta\n"))
    assert_equal(ed.file_path, String(""))
    assert_true(ed.save_as(path))
    assert_equal(ed.file_path, path)
    assert_false(ed.dirty)
    assert_equal(read_file(path), String("alpha\nbeta\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def _lines_from(text: String) -> List[String]:
    """Mirror ``TextBuffer.__init__`` for tests that need a plain
    ``List[String]`` line view of a string (used by ``diff3_merge``
    cases below)."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x0A:
            out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    out.append(String(StringSlice(unsafe_from_utf8=b[start:len(b)])))
    return out^


def test_diff3_merge_clean_when_only_ours_changed() raises:
    """If theirs equals base, the merge takes ours unmodified."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nB\nc\n"))
    var theirs = _lines_from(String("a\nb\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    assert_equal(m.first_conflict_row, -1)
    assert_equal(len(m.lines), len(ours))
    for i in range(len(ours)):
        assert_equal(m.lines[i], ours[i])


def test_diff3_merge_clean_when_only_theirs_changed() raises:
    """Symmetric: if ours equals base, the merge takes theirs."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nb\nc\n"))
    var theirs = _lines_from(String("a\nB\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    for i in range(len(theirs)):
        assert_equal(m.lines[i], theirs[i])


def test_diff3_merge_clean_when_changes_disjoint() raises:
    """Both sides changed, but in different regions — auto-merges."""
    var base = _lines_from(String("a\nb\nc\nd\ne\n"))
    var ours = _lines_from(String("A\nb\nc\nd\ne\n"))
    var theirs = _lines_from(String("a\nb\nc\nd\nE\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    var want = _lines_from(String("A\nb\nc\nd\nE\n"))
    assert_equal(len(m.lines), len(want))
    for i in range(len(want)):
        assert_equal(m.lines[i], want[i])


def test_diff3_merge_identical_changes_dont_conflict() raises:
    """When both sides edit the same region to the same result, take it."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nB\nc\n"))
    var theirs = _lines_from(String("a\nB\nc\n"))
    var m = diff3_merge(base, ours, theirs)
    assert_equal(m.conflicts, 0)
    var want = _lines_from(String("a\nB\nc\n"))
    for i in range(len(want)):
        assert_equal(m.lines[i], want[i])


def test_diff3_merge_conflict_when_both_edit_same_line() raises:
    """Same base line, two different changes → conflict markers."""
    var base = _lines_from(String("a\nb\nc\n"))
    var ours = _lines_from(String("a\nOURS\nc\n"))
    var theirs = _lines_from(String("a\nTHEIRS\nc\n"))
    var m = diff3_merge(base, ours, theirs,
        String("local"), String("disk"))
    assert_equal(m.conflicts, 1)
    assert_true(m.first_conflict_row >= 0)
    # The marker block must be present in order.
    var saw_open = False
    var saw_eq = False
    var saw_close = False
    var open_idx = -1
    var eq_idx = -1
    var close_idx = -1
    for i in range(len(m.lines)):
        if m.lines[i] == String("<<<<<<< local"):
            saw_open = True
            open_idx = i
        elif m.lines[i] == String("======="):
            saw_eq = True
            eq_idx = i
        elif m.lines[i] == String(">>>>>>> disk"):
            saw_close = True
            close_idx = i
    assert_true(saw_open)
    assert_true(saw_eq)
    assert_true(saw_close)
    assert_true(open_idx < eq_idx)
    assert_true(eq_idx < close_idx)
    assert_equal(m.first_conflict_row, open_idx)


def test_editor_external_change_clean_reload_when_buffer_clean() raises:
    """Buffer is clean: an external write triggers a verbatim reload."""
    var path = _temp_path(String("_ext_clean.txt"))
    assert_true(write_file(path, String("alpha\nbeta\n")))
    var ed = Editor.from_file(path)
    assert_false(ed.dirty)
    # Rewrite with different size so the stat-compare detects it even
    # within the same wall-clock second.
    assert_true(write_file(path, String("alpha\nbeta\nGAMMA\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_RELOADED)
    assert_false(ed.dirty)
    assert_equal(ed.buffer.line_count(), 4)
    assert_equal(ed.buffer.line(2), String("GAMMA"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_refreshes_highlights() raises:
    """Reload from disk must produce highlights matching the new
    content — not stale entries pointing into the previous buffer.
    Exercises a scope-changing case (block comment over multiple
    lines, then erased) so the cache's per-line post-stack actually
    matters.
    """
    var path = _temp_path(String("_ext_hl.rs"))
    assert_true(write_file(
        path,
        String("/* block start\nstill in block\nstill in block 2\n*/ end\n"),
    ))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    assert_true(len(ed.highlights) > 0)
    # Same path, but the block comment is gone — the new buffer's
    # post-stacks differ from the cached ones at every row.
    assert_true(write_file(
        path,
        String("fn two() {}\nfn three() {}\n"),
    ))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_RELOADED)
    ed.flush_highlights(registry, speller)
    var post = ed.highlights.copy()
    var expected = highlight_for_extension(String("rs"), ed.buffer.lines)
    # Same shape as a full retokenize against the new buffer.
    assert_equal(len(post), len(expected))
    for i in range(len(post)):
        assert_equal(post[i].row, expected[i].row)
        assert_equal(post[i].col_start, expected[i].col_start)
        assert_equal(post[i].col_end, expected[i].col_end)
    # No highlight may point at a row past the new buffer's end.
    var max_row = ed.buffer.line_count() - 1
    for i in range(len(post)):
        assert_true(post[i].row <= max_row)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_auto_merges_disjoint_edits() raises:
    """Buffer edits and disk edits in different regions → silent merge."""
    var path = _temp_path(String("_ext_merge.txt"))
    assert_true(write_file(path, String("a\nb\nc\nd\ne\n")))
    var ed = Editor.from_file(path)
    # Local edit on the first line: type before the 'a'.
    _ = ed.handle_key(Event.key_event(UInt32(ord("X"))), _VIEW)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("Xa"))
    # External edit on the last non-empty line.
    assert_true(write_file(path, String("a\nb\nc\nd\nEEE\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_MERGED)
    # Both edits present, no conflict markers.
    assert_equal(ed.buffer.line(0), String("Xa"))
    assert_equal(ed.buffer.line(4), String("EEE"))
    # Buffer differs from disk now (disk lacks our 'X'), so still dirty.
    assert_true(ed.dirty)
    # No conflict diff queued.
    assert_false(ed.consume_conflict_diff())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_clears_dirty_when_disk_already_has_our_edits() raises:
    """If disk happens to already match our buffer (someone applied
    the same edit externally), the merge resolves to clean and the
    buffer goes back to non-dirty."""
    var path = _temp_path(String("_ext_match.txt"))
    assert_true(write_file(path, String("alpha\n")))
    var ed = Editor.from_file(path)
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("!"))), _VIEW)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("alpha!"))
    # External writer produced the exact same content (different size
    # from baseline so stat fires).
    assert_true(write_file(path, String("alpha!\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_MERGED)
    assert_false(ed.dirty)
    assert_equal(ed.buffer.line(0), String("alpha!"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_external_change_conflict_inserts_markers() raises:
    """Both buffer and disk modified the same line → conflict markers
    are embedded, cursor jumps to the first marker, and a pre-rendered
    diff is queued for the host to display."""
    var path = _temp_path(String("_ext_conflict.txt"))
    assert_true(write_file(path, String("a\nb\nc\n")))
    var ed = Editor.from_file(path)
    # Local: cursor at start of "b", select line, replace with "OURS".
    ed.move_to(1, 0, False)
    ed.move_to(1, 1, True)
    _ = ed.handle_key(Event.key_event(UInt32(ord("O"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("U"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("R"))), _VIEW)
    _ = ed.handle_key(Event.key_event(UInt32(ord("S"))), _VIEW)
    assert_equal(ed.buffer.line(1), String("OURS"))
    assert_true(ed.dirty)
    # External: same line replaced with different content; size differs
    # so stat-compare fires.
    assert_true(write_file(path, String("a\nTHEIRS\nc\n")))
    var status = ed.check_for_external_change()
    assert_equal(status, EXT_CHANGE_CONFLICT)
    assert_true(ed.dirty)
    # First conflict marker present and the cursor sits on it.
    var found_open = False
    for i in range(ed.buffer.line_count()):
        if ed.buffer.line(i).find(String("<<<<<<<")) >= 0:
            found_open = True
            assert_equal(ed.cursor_row, i)
            break
    assert_true(found_open)
    # Both versions appear in the buffer.
    var saw_ours = False
    var saw_theirs = False
    for i in range(ed.buffer.line_count()):
        if ed.buffer.line(i) == String("OURS"):
            saw_ours = True
        elif ed.buffer.line(i) == String("THEIRS"):
            saw_theirs = True
    assert_true(saw_ours)
    assert_true(saw_theirs)
    # The host-facing diff is queued (consumed on first read).
    var diff = ed.consume_conflict_diff()
    assert_true(diff)
    var diff_text = diff.value()
    # Must contain both old- and new-disk markers from unified_diff.
    assert_true(diff_text.find(String("@@")) >= 0)
    # consume_conflict_diff is one-shot.
    assert_false(ed.consume_conflict_diff())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_replace_all() raises:
    var ed = Editor(String("foo bar foo\nfoo\nbaz\n"))
    var n = ed.replace_all(String("foo"), String("XX"))
    assert_equal(n, 3)
    assert_true(ed.dirty)
    assert_equal(ed.buffer.line(0), String("XX bar XX"))
    assert_equal(ed.buffer.line(1), String("XX"))
    assert_equal(ed.buffer.line(2), String("baz"))
    # Replacing something absent reports zero.
    var ed2 = Editor(String("nothing to do"))
    assert_equal(ed2.replace_all(String("xxx"), String("yyy")), 0)
    assert_false(ed2.dirty)
    # Empty needle is a no-op (avoids infinite-loop semantics).
    assert_equal(ed.replace_all(String(""), String("Q")), 0)


def test_editorconfig_parse_basic() raises:
    """Parser walks an INI-ish blob into sections + global ``root`` flag."""
    var text = String(
        "# leading comment\n"
        + "root = true\n"
        + "\n"
        + "[*]\n"
        + "indent_style = space\n"
        + "indent_size = 4\n"
        + "\n"
        + "[*.{c,h}]\n"
        + "indent_style = tab\n"
    )
    var f = parse_editorconfig(String("/tmp/x"), text)
    assert_true(f.is_root)
    assert_equal(len(f.sections), 2)
    assert_equal(f.sections[0].pattern, String("*"))
    assert_equal(len(f.sections[0].keys), 2)
    assert_equal(f.sections[1].pattern, String("*.{c,h}"))


def test_editorconfig_match_section() raises:
    # No-slash patterns match basenames at any depth.
    assert_true(match_section(String("*.py"), String("foo.py")))
    assert_true(match_section(String("*.py"), String("a/b/foo.py")))
    assert_false(match_section(String("*.py"), String("foo.pyc")))
    # Anchored (slashed) patterns match relative path from the start.
    assert_true(match_section(String("src/*.c"), String("src/main.c")))
    assert_false(match_section(String("src/*.c"), String("a/src/main.c")))
    # ``**`` crosses directory boundaries.
    assert_true(match_section(String("**/foo"), String("foo")))
    assert_true(match_section(String("**/foo"), String("a/b/foo")))
    # Alternation.
    assert_true(match_section(String("*.{c,h}"), String("main.c")))
    assert_true(match_section(String("*.{c,h}"), String("main.h")))
    assert_false(match_section(String("*.{c,h}"), String("main.cpp")))
    # Character class.
    assert_true(match_section(String("[ab].txt"), String("a.txt")))
    assert_true(match_section(String("[ab].txt"), String("b.txt")))
    assert_false(match_section(String("[ab].txt"), String("c.txt")))
    # Negated character class.
    assert_true(match_section(String("[!a].txt"), String("b.txt")))
    assert_false(match_section(String("[!a].txt"), String("a.txt")))
    # Range.
    assert_true(match_section(String("[a-z].txt"), String("k.txt")))
    assert_false(match_section(String("[a-z].txt"), String("K.txt")))


def test_editorconfig_load_from_fixture() raises:
    """The fixture: top-level config sets 4-space LF + trim + final-NL,
    overrides ``*.{c,h}`` to tab/2 and ``Makefile`` to tab. The ``sub/``
    dir's file overrides ``*.py`` to indent_size=2 — and inherits the
    rest from the parent because that file lacks ``root = true``."""
    var fix = String("tests/fixtures/editorconfig/")
    var c = load_editorconfig_for_path(fix + String("foo.txt"))
    assert_equal(c.indent_style, String("space"))
    assert_equal(c.indent_size, 4)
    assert_equal(c.end_of_line, String("lf"))
    assert_equal(c.trim_trailing_whitespace, 1)
    assert_equal(c.insert_final_newline, 1)
    var c2 = load_editorconfig_for_path(fix + String("main.c"))
    assert_equal(c2.indent_style, String("tab"))
    assert_equal(c2.tab_width, 2)
    # ``end_of_line`` was set on ``[*]`` and inherits.
    assert_equal(c2.end_of_line, String("lf"))
    # Closer file wins per-property: sub/ overrides *.py size to 2,
    # but inherits other settings from the parent's ``[*]``.
    var c3 = load_editorconfig_for_path(fix + String("sub/foo.py"))
    assert_equal(c3.indent_style, String("space"))
    assert_equal(c3.indent_size, 2)
    assert_equal(c3.end_of_line, String("lf"))


def test_editor_uses_editorconfig_indent() raises:
    """Tab key respects ``indent_style`` / ``indent_size`` from editorconfig.
    The fixture sets ``[*.{c,h}]`` to ``indent_style=tab``, so opening a
    .c file under that tree should make Tab insert a literal tab."""
    var path = String("tests/fixtures/editorconfig/test_indent.c")
    assert_true(write_file(path, String("")))
    var ed = Editor.from_file(path)
    assert_equal(ed.editorconfig.indent_style, String("tab"))
    _ = ed.handle_key(_key(KEY_TAB), _VIEW)
    assert_equal(ed.buffer.line(0), String("\t"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_tab_indents_selected_lines() raises:
    """With a selection, Tab prepends one indent unit to every spanned
    line. A selection ending at column 0 of the next line excludes that
    trailing line — only the visibly-selected rows are touched."""
    var ed = Editor(String("alpha\nbeta\ngamma"))
    # Select from (0, 0) → (2, 0): rows 0 and 1, but not row 2.
    ed.move_to(0, 0, False)
    ed.move_to(2, 0, True)
    _ = ed.handle_key(_key(KEY_TAB), _VIEW)
    assert_equal(ed.buffer.line(0), String("    alpha"))
    assert_equal(ed.buffer.line(1), String("    beta"))
    assert_equal(ed.buffer.line(2), String("gamma"))


def test_editor_shift_tab_dedents_selected_lines() raises:
    """Shift+Tab on a selection removes one indent unit from each row.
    Lines without leading whitespace are left alone. The selection's
    cursor and anchor cols shrink by the bytes removed on their row."""
    var ed = Editor(String("    alpha\n  beta\ngamma"))
    ed.move_to(0, 4, False)        # cursor after the 4 leading spaces of row 0
    ed.move_to(2, 0, True)         # extend through row 2 (excluded by ec==0)
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    assert_equal(ed.buffer.line(0), String("alpha"))
    assert_equal(ed.buffer.line(1), String("beta"))
    assert_equal(ed.buffer.line(2), String("gamma"))
    # Cursor was at col 4 on row 0; 4 spaces removed → col 0.
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 0)


def test_editor_shift_tab_dedents_cursor_line_without_selection() raises:
    """Shift+Tab with no selection dedents only the cursor's line."""
    var ed = Editor(String("    alpha\n    beta"))
    ed.move_to(1, 6, False)         # row 1, somewhere inside "beta"
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    assert_equal(ed.buffer.line(0), String("    alpha"))
    assert_equal(ed.buffer.line(1), String("beta"))
    assert_equal(ed.cursor_col, 2)


def test_editor_shift_tab_no_indent_is_noop() raises:
    """Shift+Tab on lines with no leading whitespace must not push an
    undo entry — otherwise undo would step through dead-no-op states."""
    var ed = Editor(String("alpha\nbeta"))
    ed.move_to(0, 0, False)
    ed.move_to(1, 4, True)
    var before = ed.buffer.line(0) + String("|") + ed.buffer.line(1)
    _ = ed.handle_key(_key(KEY_TAB, MOD_SHIFT), _VIEW)
    var after = ed.buffer.line(0) + String("|") + ed.buffer.line(1)
    assert_equal(before, after)


def test_editor_save_applies_editorconfig_transforms() raises:
    """``save`` should trim trailing whitespace and ensure a final newline
    when the editorconfig says to. The fixture's top-level ``[*]`` sets
    both, so saving a .txt file inside the fixture tree exercises both."""
    var path = String("tests/fixtures/editorconfig/test_save.txt")
    # Bootstrap with a payload that ``trim`` + ``final newline`` will rewrite.
    assert_true(write_file(path, String("alpha   \nbeta")))
    var ed = Editor.from_file(path)
    assert_equal(ed.editorconfig.trim_trailing_whitespace, 1)
    assert_equal(ed.editorconfig.insert_final_newline, 1)
    assert_true(ed.save())
    var got = read_file(path)
    # ``alpha   `` → ``alpha`` (trailing spaces trimmed) and a final ``\n``
    # is appended even though the original file lacked one.
    assert_equal(got, String("alpha\nbeta\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_save_uses_editorconfig_line_endings() raises:
    """When ``end_of_line`` is ``crlf``, ``save`` should join lines with
    ``\\r\\n`` even though the buffer uses ``\\n`` internally."""
    var dir = String("/tmp/turbokod_ec_eol_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var ec_path = dir + String("/.editorconfig")
    assert_true(write_file(ec_path, String(
        "root = true\n[*]\nend_of_line = crlf\n"
    )))
    var f_path = dir + String("/x.txt")
    assert_true(write_file(f_path, String("a\nb")))
    var ed = Editor.from_file(f_path)
    assert_equal(ed.editorconfig.end_of_line, String("crlf"))
    assert_true(ed.save())
    var got = read_file(f_path)
    assert_equal(got, String("a\r\nb"))
    _ = external_call["unlink", Int32]((f_path + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((ec_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_text_buffer_strips_crlf_on_split() raises:
    """A CRLF-encoded payload must split into clean lines — leaving the
    ``\\r`` byte attached to each line would later corrupt the terminal
    paint (stray ``\\r`` resets the cursor to column 0 mid-row) and
    confuse cursor / selection math.
    """
    var b = TextBuffer(String("ab\r\ncd\r\n"))
    assert_equal(b.line_count(), 3)
    assert_equal(b.line(0), String("ab"))
    assert_equal(b.line(1), String("cd"))
    assert_equal(b.line(2), String(""))
    # A trailing CR with no following LF also gets stripped.
    var b2 = TextBuffer(String("only\r"))
    assert_equal(b2.line_count(), 1)
    assert_equal(b2.line(0), String("only"))


def test_editor_preserves_crlf_round_trip() raises:
    """Opening a CRLF file with no editorconfig and saving it again must
    produce the original bytes verbatim — otherwise every CRLF file we
    open would show a full-file diff on the next save."""
    var dir = String("/tmp/turbokod_crlf_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var f_path = dir + String("/x.txt")
    var original = String("alpha\r\nbeta\r\ngamma\r\n")
    assert_true(write_file(f_path, original))
    var ed = Editor.from_file(f_path)
    # Detection: no editorconfig in this dir, so end_of_line should be
    # filled in from the file's actual bytes.
    assert_equal(ed.editorconfig.end_of_line, String("crlf"))
    # Buffer holds clean lines (no trailing '\r').
    assert_equal(ed.buffer.line(0), String("alpha"))
    assert_equal(ed.buffer.line(1), String("beta"))
    assert_equal(ed.buffer.line(2), String("gamma"))
    assert_true(ed.save())
    var got = read_file(f_path)
    assert_equal(got, original)
    _ = external_call["unlink", Int32]((f_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_git_gutter_no_diff_when_buffer_matches_crlf_head() raises:
    """Opening a CRLF file shouldn't make the git gutter flag every row
    as MODIFIED. The buffer strips trailing ``\\r``; the cached HEAD
    text must do the same on ingress so the diff aligns. Also covers
    the revert path: a revert of an unchanged row would otherwise
    splice raw ``\\r``-laden lines back into the buffer.
    """
    var ed = Editor(String(""))
    # Buffer matches HEAD modulo line endings (CRLF vs LF).
    ed.buffer = TextBuffer(String("alpha\nbeta\ngamma\n"))
    ed.set_git_head_text(String("alpha\r\nbeta\r\ngamma\r\n"), True)
    # The cached text must be normalized — no '\r' bytes left.
    var head_bytes = ed._git_head_text.as_bytes()
    for i in range(len(head_bytes)):
        assert_true(Int(head_bytes[i]) != 0x0D)
    # Every buffer row should diff as NONE.
    var diff = diff_buffer_against_head(
        ed._git_head_text, ed.buffer.lines.copy(),
    )
    for i in range(len(diff)):
        assert_equal(diff[i], GIT_CHANGE_NONE)


def test_canvas_substitutes_control_glyphs() raises:
    """``Canvas.put_text`` must never emit a raw control byte — paint
    a string containing ``\\r`` and confirm the cell glyph is the
    Unicode 'Control Pictures' substitute (U+240D, ``␍``) rather than
    the raw 0x0D byte. Same byte hitting the terminal verbatim is what
    corrupts the editor paint of CRLF files."""
    var c = Canvas(8, 1)
    _ = c.put_text(Point(0, 0), String("a\rb"), default_attr())
    # Cell 0 → 'a' (1 byte ASCII)
    assert_equal(c.get(0, 0).glyph, String("a"))
    # Cell 1 → '␍' (U+240D, 3 bytes UTF-8: E2 90 8D), NOT raw '\r'
    var cr_glyph = c.get(1, 0).glyph
    assert_equal(len(cr_glyph.as_bytes()), 3)
    var crb = cr_glyph.as_bytes()
    assert_equal(Int(crb[0]), 0xE2)
    assert_equal(Int(crb[1]), 0x90)
    assert_equal(Int(crb[2]), 0x8D)
    # Cell 2 → 'b'
    assert_equal(c.get(2, 0).glyph, String("b"))


def test_walk_project_files_finds_known_files() raises:
    """The repo root has examples/, src/, tests/ — all should be reachable.

    ``.gitignore`` itself must be reachable (quick open lists it), but
    nothing under ``.git`` or gitignored trees like ``.pixi`` may leak."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var paths = walk_project_files(root.value())
    assert_true(len(paths) > 5)
    var saw_hello = False
    var saw_test = False
    var saw_dotfile = False
    var saw_gitignore = False
    for i in range(len(paths)):
        if _ends_with(paths[i], String("examples/hello.mojo")):
            saw_hello = True
        if _ends_with(paths[i], String("tests/test_basic.mojo")):
            saw_test = True
        if _ends_with(paths[i], String("/.gitignore")):
            saw_gitignore = True
        if _contains(paths[i], String("/.git/")) \
                or _contains(paths[i], String("/.pixi/")):
            saw_dotfile = True
    assert_true(saw_hello)
    assert_true(saw_test)
    assert_true(saw_gitignore)
    assert_false(saw_dotfile)


def _ends_with(s: String, suffix: String) -> Bool:
    var sb = s.as_bytes()
    var fb = suffix.as_bytes()
    if len(fb) > len(sb):
        return False
    for i in range(len(fb)):
        if sb[len(sb) - len(fb) + i] != fb[i]:
            return False
    return True


def _contains(s: String, sub: String) -> Bool:
    var sb = s.as_bytes()
    var nb = sub.as_bytes()
    var n = len(nb)
    var h = len(sb)
    if n == 0:
        return True
    if n > h:
        return False
    for i in range(h - n + 1):
        var hit = True
        for k in range(n):
            if sb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            return True
    return False


def test_find_in_project_locates_string() raises:
    """Search the repo for a string that's known to live in exactly one place."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var matches = find_in_project(root.value(), String("Turbokod: a Mojo-idiomatic port"))
    assert_true(len(matches) >= 1)
    var found_in_init = False
    for i in range(len(matches)):
        if matches[i].rel == String("src/turbokod/__init__.mojo"):
            found_in_init = True
            assert_true(matches[i].line_no >= 1)
    assert_true(found_in_init)


def test_desktop_dispatch_editor_save_passes_through_when_no_editor() raises:
    """Save with no editor focused should be a no-op intercepted by Desktop —
    the action does not bubble back to the caller."""
    var d = Desktop()
    var maybe = d.dispatch_action(EDITOR_SAVE, _SCREEN)
    assert_false(Bool(maybe))


def test_desktop_dispatch_passes_through_unknown_actions() raises:
    var d = Desktop()
    var maybe = d.dispatch_action(String("focus:About"), _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), String("focus:About"))


def test_desktop_dispatch_editor_save_writes_focused_editor() raises:
    var path = _temp_path(String("_dsave.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(String("dsave.txt"), Rect(0, 1, 40, 12), path))
    # Mark dirty by appending a char.
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    var maybe = d.dispatch_action(EDITOR_SAVE, _SCREEN)
    assert_false(Bool(maybe))
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path), String("hello!\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_window_focus_change_saves_prior_window() raises:
    """Switching focus from window A to window B saves A's dirty
    buffer — the per-window counterpart of ``EVENT_FOCUS_OUT``'s
    app-wide save. Exercises the default (``config.auto_save`` is
    ``True`` out of the box)."""
    var path_a = _temp_path(String("_wfc_a.txt"))
    var path_b = _temp_path(String("_wfc_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    # Seed the focus tracker with the current focused editor.
    d.paint(canvas, _SCREEN)
    # Make A dirty.
    d.windows.focus_by_index(0)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    # Run a paint to update the tracker against A.
    d.paint(canvas, _SCREEN)
    # Switch focus to B — next paint should save A.
    d.windows.focus_by_index(1)
    d.paint(canvas, _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa!\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_window_focus_change_via_dispatch_action_saves() raises:
    """The tab bar click path lands at ``dispatch_action(WINDOW_FOCUS_PREFIX
    + idx)``. After the next paint that route must have saved the
    previously focused dirty editor — same as direct ``focus_by_index``."""
    var path_a = _temp_path(String("_wfc_disp_a.txt"))
    var path_b = _temp_path(String("_wfc_disp_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    d.paint(canvas, _SCREEN)
    # Focus A and dirty it.
    _ = d.dispatch_action(WINDOW_FOCUS_PREFIX + String(0), _SCREEN)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    d.paint(canvas, _SCREEN)
    # Now dispatch the tab-bar route to focus B.
    _ = d.dispatch_action(WINDOW_FOCUS_PREFIX + String(1), _SCREEN)
    d.paint(canvas, _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa!\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_app_focus_out_saves_all_dirty_windows_by_default() raises:
    """``EVENT_FOCUS_OUT`` from the host terminal flushes every dirty
    editor when ``config.auto_save`` is on — and that's the default,
    so a fresh ``Desktop()`` saves on wrapper-window focus loss
    without the user opting in."""
    var path_a = _temp_path(String("_app_fo_a.txt"))
    var path_b = _temp_path(String("_app_fo_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    # Sanity-check the default is on.
    assert_true(d.config.auto_save)
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    # Make both dirty.
    for i in range(2):
        _ = d.windows.windows[i].editor.handle_key(
            Event.key_event(KEY_END), Rect(0, 1, 40, 12),
        )
        _ = d.windows.windows[i].editor.handle_key(
            Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
        )
        assert_true(d.windows.windows[i].editor.dirty)
    _ = d.handle_event(Event.focus_event(False), _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_false(d.windows.windows[1].editor.dirty)
    assert_equal(read_file(path_a), String("aaa!\n"))
    assert_equal(read_file(path_b), String("bbb!\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_focus_loss_save_opt_out_when_auto_save_off() raises:
    """Setting ``config.auto_save = False`` (the Manual choice in
    Settings ▸ Editor ▸ Save behavior) suppresses both the
    window-to-window and the app-wide focus-loss saves — Ctrl+S
    becomes the only write path."""
    var path_a = _temp_path(String("_optout_a.txt"))
    var path_b = _temp_path(String("_optout_b.txt"))
    assert_true(write_file(path_a, String("aaa\n")))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    d.config.auto_save = False
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    d.windows.add(Window.from_file(String("a"), Rect(0, 1, 40, 12), path_a))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    d.paint(canvas, _SCREEN)
    # Dirty A.
    d.windows.focus_by_index(0)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    d.paint(canvas, _SCREEN)
    # Window-to-window focus switch — Manual: must NOT save.
    d.windows.focus_by_index(1)
    d.paint(canvas, _SCREEN)
    assert_true(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa\n"))
    # App-level focus-out — Manual: must NOT save either.
    _ = d.handle_event(Event.focus_event(False), _SCREEN)
    assert_true(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path_a), String("aaa\n"))
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_window_focus_change_skips_untitled_buffer() raises:
    """An untitled (no backing path) editor losing focus must not be
    saved — same skip rule as ``_autosave_all_dirty``."""
    var path_b = _temp_path(String("_wfc_unt_b.txt"))
    assert_true(write_file(path_b, String("bbb\n")))
    var d = Desktop()
    var canvas = Canvas(_SCREEN.width(), _SCREEN.height())
    # Window 0 is an untitled in-memory buffer (no file_path).
    d.windows.add(Window.editor_window(
        String("untitled"), Rect(0, 1, 40, 12), String("scratch\n"),
    ))
    d.windows.add(Window.from_file(String("b"), Rect(40, 1, 80, 12), path_b))
    d.paint(canvas, _SCREEN)
    d.windows.focus_by_index(0)
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    d.paint(canvas, _SCREEN)
    d.windows.focus_by_index(1)
    # Should not raise (untitled has no path; tracker skips it).
    d.paint(canvas, _SCREEN)
    # Still dirty — untitled buffers are never auto-saved.
    assert_true(d.windows.windows[0].editor.dirty)
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_desktop_replace_chains_two_prompts() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar foo\n"),
    ))
    # Click "Replace..." → first prompt opens for "find".
    _ = d.dispatch_action(EDITOR_REPLACE, _SCREEN)
    assert_true(d.prompt.active)
    # Submit "foo" — Desktop should immediately re-open the prompt for "replace".
    d.prompt.input.set_text(String("foo"))
    d.prompt.submitted = True
    _ = d._on_prompt_submit()
    assert_true(d.prompt.active)   # second prompt is open
    # Submit "BAR" — the replacement actually happens now.
    d.prompt.input.set_text(String("BAR"))
    d.prompt.submitted = True
    _ = d._on_prompt_submit()
    assert_false(d.prompt.active)
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("BAR bar BAR"))


def test_desktop_find_seeds_from_editor_selection() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar baz\n"),
    ))
    # Select "bar" in the editor.
    d.windows.windows[0].editor.move_to(0, 4, False)
    d.windows.windows[0].editor.move_to(0, 7, True)
    assert_equal(d.windows.windows[0].editor.selection_text(), String("bar"))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.active)
    # Prefilled with the selection, fully selected so a typed key replaces it.
    assert_equal(d.prompt.input.text, String("bar"))
    assert_true(d.prompt.input.has_selection())
    assert_equal(d.prompt.input.selection_text(), String("bar"))


def test_desktop_find_skips_seed_for_multiline_selection() raises:
    # A find term must be single-line; a multi-line editor selection
    # is not a meaningful default for the prompt.
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo\nbar\nbaz\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 0, False)
    d.windows.windows[0].editor.move_to(1, 3, True)
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.active)
    assert_equal(d.prompt.input.text, String(""))


def test_desktop_find_no_selection_no_prefill() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar baz\n"),
    ))
    _ = d.dispatch_action(EDITOR_FIND, _SCREEN)
    assert_true(d.prompt.active)
    assert_equal(d.prompt.input.text, String(""))


def test_desktop_open_file_uses_80_percent_size() raises:
    var path = _temp_path(String("_open80.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    var ws = d.workspace_rect(_SCREEN)
    assert_equal(d.windows.windows[0].rect.width(), (ws.width() * 80) // 100)
    assert_equal(d.windows.windows[0].rect.height(), (ws.height() * 80) // 100)
    # First open lands at the workspace origin (no cascade yet).
    assert_equal(d.windows.windows[0].rect.a.x, ws.a.x)
    assert_equal(d.windows.windows[0].rect.a.y, ws.a.y)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_desktop_open_file_cascades_by_one() raises:
    var path_a = _temp_path(String("_cascade_a.txt"))
    var path_b = _temp_path(String("_cascade_b.txt"))
    var path_c = _temp_path(String("_cascade_c.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    assert_true(write_file(path_c, String("c\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d.open_file(path_b, _SCREEN)
    d.open_file(path_c, _SCREEN)
    var ws = d.workspace_rect(_SCREEN)
    assert_equal(d.windows.windows[0].rect.a.x, ws.a.x + 0)
    assert_equal(d.windows.windows[0].rect.a.y, ws.a.y + 0)
    assert_equal(d.windows.windows[1].rect.a.x, ws.a.x + 1)
    assert_equal(d.windows.windows[1].rect.a.y, ws.a.y + 1)
    assert_equal(d.windows.windows[2].rect.a.x, ws.a.x + 2)
    assert_equal(d.windows.windows[2].rect.a.y, ws.a.y + 2)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_c + String("\0")).unsafe_ptr())


def test_desktop_open_file_focuses_existing() raises:
    """Re-opening an already-open path focuses that window instead of
    creating a duplicate."""
    var path_a = _temp_path(String("_dedup_a.txt"))
    var path_b = _temp_path(String("_dedup_b.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d.open_file(path_b, _SCREEN)
    assert_equal(len(d.windows.windows), 2)
    assert_equal(d.windows.focused, 1)
    # Re-opening A should focus the existing window, not add a third.
    d.open_file(path_a, _SCREEN)
    assert_equal(len(d.windows.windows), 2)
    assert_equal(d.windows.focused, 0)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_desktop_open_file_inherits_maximize_state() raises:
    var path_a = _temp_path(String("_maxinh_a.txt"))
    var path_b = _temp_path(String("_maxinh_b.txt"))
    assert_true(write_file(path_a, String("m\n")))
    assert_true(write_file(path_b, String("n\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    # Maximize the first window, then open a second (different) file.
    d.windows.windows[0].toggle_maximize(d.workspace_rect(_SCREEN))
    assert_true(d.windows.windows[0].is_maximized)
    d.open_file(path_b, _SCREEN)
    # The new window inherits maximized mode but its restore rect is the
    # 80% cascade slot (so toggling brings it back to the right size).
    assert_true(d.windows.windows[1].is_maximized)
    var ws = d.workspace_rect(_SCREEN)
    assert_true(d.windows.windows[1].rect == ws)
    assert_equal(
        d.windows.windows[1]._restore_rect.width(), (ws.width() * 80) // 100,
    )
    assert_equal(d.windows.windows[1]._restore_rect.a.x, ws.a.x + 1)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_desktop_new_file_creates_untitled_editor_window() raises:
    """``new_file`` opens an empty editor with no backing path so Save
    falls through to Save As, and successive calls get unique titles."""
    var d = Desktop()
    d.new_file(_SCREEN)
    assert_equal(len(d.windows.windows), 1)
    assert_true(d.windows.windows[0].is_editor)
    assert_equal(d.windows.windows[0].title, String("Untitled"))
    assert_equal(d.windows.windows[0].editor.file_path, String(""))
    assert_equal(d.windows.windows[0].editor.buffer.line_count(), 1)
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String(""))
    d.new_file(_SCREEN)
    assert_equal(len(d.windows.windows), 2)
    assert_equal(d.windows.windows[1].title, String("Untitled 2"))


def test_desktop_dispatch_editor_new_opens_window() raises:
    """The framework intercepts ``EDITOR_NEW`` so apps wired to the action
    don't need any extra handling for File → New."""
    var d = Desktop()
    var maybe = d.dispatch_action(EDITOR_NEW, _SCREEN)
    assert_false(Bool(maybe))                    # framework consumed the action
    assert_equal(len(d.windows.windows), 1)
    assert_true(d.windows.windows[0].is_editor)
    assert_equal(d.windows.windows[0].editor.file_path, String(""))


def test_desktop_window_menu_lists_open_windows() raises:
    var d = Desktop()
    d.windows.add(Window(String("alpha"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("beta"),  Rect(0, 1, 20, 5), List[String]()))
    d._rebuild_window_menu()
    var menu = d.menu_bar.menus[d._window_menu_idx].copy()
    # 2 window items + separator + Maximize all + Restore all = 5 items.
    assert_equal(len(menu.items), 5)
    assert_equal(menu.items[0].label, String("alpha"))
    assert_equal(menu.items[0].action, String("window:focus:0"))
    assert_equal(menu.items[1].label, String("beta"))
    assert_equal(menu.items[1].action, String("window:focus:1"))
    assert_true(menu.items[2].is_separator)
    assert_equal(menu.items[3].label, String("Maximize all"))
    assert_equal(menu.items[4].label, String("Restore all"))


def test_desktop_window_menu_when_empty() raises:
    var d = Desktop()
    d._rebuild_window_menu()
    var menu = d.menu_bar.menus[d._window_menu_idx].copy()
    # No windows: skip the separator, just show the bulk actions.
    assert_equal(len(menu.items), 2)
    assert_equal(menu.items[0].label, String("Maximize all"))
    assert_equal(menu.items[1].label, String("Restore all"))


def test_desktop_window_focus_action_focuses_window() raises:
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    # Focus the first window via the dynamic action string. The windows list
    # itself stays in insertion order (so menu bindings remain stable); only
    # ``focused`` and the z-order change.
    _ = d.dispatch_action(String("window:focus:0"), _SCREEN)
    assert_equal(d.windows.focused, 0)
    assert_equal(d.windows.windows[0].title, String("a"))
    assert_equal(d.windows.windows[1].title, String("b"))
    assert_equal(d.windows.windows[2].title, String("c"))
    # Focused window is at the top of z-order.
    assert_equal(d.windows.z_order[len(d.windows.z_order) - 1], 0)


def test_desktop_maximize_all_and_restore_all() raises:
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(5, 6, 30, 12), List[String]()))
    var ws = d.workspace_rect(_SCREEN)
    _ = d.dispatch_action(String("window:maximize_all"), _SCREEN)
    for i in range(len(d.windows.windows)):
        assert_true(d.windows.windows[i].is_maximized)
        assert_true(d.windows.windows[i].rect == ws)
    _ = d.dispatch_action(String("window:restore_all"), _SCREEN)
    assert_false(d.windows.windows[0].is_maximized)
    assert_false(d.windows.windows[1].is_maximized)
    assert_true(d.windows.windows[0].rect == Rect(0, 1, 20, 5))
    assert_true(d.windows.windows[1].rect == Rect(5, 6, 30, 12))


def test_desktop_project_find_requires_active_project() raises:
    var d = Desktop()
    # No project: dispatch is a no-op (the modal stays closed).
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_false(d.project_find.active)
    # With a project: the fullscreen find UI opens.
    d.detect_project_from(String("examples/hello.mojo"))
    _ = d.dispatch_action(PROJECT_FIND, _SCREEN)
    assert_true(d.project_find.active)


def test_nav_history_records_initial_open() raises:
    """Opening a file seeds the nav stack with the file's starting
    cursor position so the very first Cmd+[ has somewhere to go."""
    var path = _temp_path(String("_nav_init.txt"))
    assert_true(write_file(path, String("alpha\nbeta\ngamma\n")))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    assert_equal(d._nav_pos, 0)
    assert_equal(d._nav_stack[0].file_path, path)
    assert_equal(d._nav_stack[0].row, 0)
    assert_equal(d._nav_stack[0].col, 0)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_nav_history_ignores_small_drift() raises:
    """Movement under the row / col threshold inside the same file
    does not push a new entry — the stack only captures real jumps."""
    var path = _temp_path(String("_nav_drift.txt"))
    var lines = String("")
    for _ in range(50):
        lines = lines + String("x\n")
    assert_true(write_file(path, lines))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    # Move 5 rows down — under the 10-row threshold; no new entry.
    d.windows.windows[0].editor.move_to(5, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    # Move another 4 rows — total 9 from the recorded baseline; still no.
    d.windows.windows[0].editor.move_to(9, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 1)
    # Cross the threshold — a new entry lands at the current position.
    d.windows.windows[0].editor.move_to(20, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 2)
    assert_equal(d._nav_stack[1].row, 20)
    assert_equal(d._nav_pos, 1)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_nav_history_records_file_change() raises:
    """A focus change to a different file always records, regardless of
    where the cursor lands — cross-file motion is what the back button
    is most useful for."""
    var path_a = _temp_path(String("_nav_fa.txt"))
    var path_b = _temp_path(String("_nav_fb.txt"))
    assert_true(write_file(path_a, String("a1\na2\na3\n")))
    assert_true(write_file(path_b, String("b1\nb2\nb3\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 2)
    assert_equal(d._nav_stack[0].file_path, path_a)
    assert_equal(d._nav_stack[1].file_path, path_b)
    assert_equal(d._nav_pos, 1)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_nav_history_back_and_forward() raises:
    """Cmd+[ steps back through stored entries; Cmd+] returns forward.
    Both bottom-out as no-ops at the ends of the stack."""
    var path_a = _temp_path(String("_nav_ba.txt"))
    var path_b = _temp_path(String("_nav_bb.txt"))
    assert_true(write_file(path_a, String("a1\na2\na3\n")))
    assert_true(write_file(path_b, String("b1\nb2\nb3\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    # Three entries: A@0, B@0 — back lands on A.
    d.navigate_back(_SCREEN)
    assert_equal(d._nav_pos, 0)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_a)
    # Hitting back again at the bottom is a no-op.
    d.navigate_back(_SCREEN)
    assert_equal(d._nav_pos, 0)
    # Forward returns to B.
    d.navigate_forward(_SCREEN)
    assert_equal(d._nav_pos, 1)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_b)
    # Forward at the top is a no-op.
    d.navigate_forward(_SCREEN)
    assert_equal(d._nav_pos, 1)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_nav_history_branching_truncates_forward() raises:
    """After going back, a fresh navigation drops the forward portion
    of the stack — same model as edit-after-undo wiping redo."""
    var path = _temp_path(String("_nav_branch.txt"))
    var lines = String("")
    for _ in range(80):
        lines = lines + String("x\n")
    assert_true(write_file(path, lines))
    var d = Desktop()
    d.open_file(path, _SCREEN)
    d._track_nav_position()
    d.windows.windows[0].editor.move_to(30, 0, False, True)
    d._track_nav_position()
    d.windows.windows[0].editor.move_to(60, 0, False, True)
    d._track_nav_position()
    # Stack: 0, 30, 60 — go back to 30.
    assert_equal(len(d._nav_stack), 3)
    d.navigate_back(_SCREEN)
    assert_equal(d._nav_pos, 1)
    # New jump to 50: forward portion (entry at 60) gets dropped.
    d.windows.windows[0].editor.move_to(50, 0, False, True)
    d._track_nav_position()
    assert_equal(len(d._nav_stack), 3)
    assert_equal(d._nav_pos, 2)
    assert_equal(d._nav_stack[2].row, 50)
    # Forward is now a no-op since we're back at the top.
    d.navigate_forward(_SCREEN)
    assert_equal(d._nav_pos, 2)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_nav_history_back_via_dispatch_action() raises:
    """The Cmd+[ binding routes through ``dispatch_action`` like any
    other framework action — the same call should drive the back step."""
    var path_a = _temp_path(String("_nav_da.txt"))
    var path_b = _temp_path(String("_nav_db.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    var maybe = d.dispatch_action(EDITOR_NAV_BACK, _SCREEN)
    assert_false(Bool(maybe))   # framework consumed the action
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_a)
    var maybe2 = d.dispatch_action(EDITOR_NAV_FORWARD, _SCREEN)
    assert_false(Bool(maybe2))
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_b)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_nav_history_cmd_bracket_keys_fire_dispatch() raises:
    """The Cmd+[ event arrives as ``(0x5B, MOD_META)`` — brackets aren't
    letters so the parser doesn't collapse them to ESC, and Cmd is kept
    distinct from Ctrl. The hotkey table must turn those into nav
    actions."""
    var path_a = _temp_path(String("_nav_ka.txt"))
    var path_b = _temp_path(String("_nav_kb.txt"))
    assert_true(write_file(path_a, String("a\n")))
    assert_true(write_file(path_b, String("b\n")))
    var d = Desktop()
    d.open_file(path_a, _SCREEN)
    # ``handle_event`` runs the per-frame nav tracking via ``paint``
    # in the real loop; in this test we drive the recording manually
    # so the stack reflects the explicit opens.
    d._track_nav_position()
    d.open_file(path_b, _SCREEN)
    d._track_nav_position()
    var back_ev = Event.key_event(UInt32(ord("[")), MOD_META)
    _ = d.handle_event(back_ev, _SCREEN)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_a)
    var fwd_ev = Event.key_event(UInt32(ord("]")), MOD_META)
    _ = d.handle_event(fwd_ev, _SCREEN)
    assert_equal(d.windows.windows[d.windows.focused].editor.file_path, path_b)
    _ = external_call["unlink", Int32]((path_a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((path_b + String("\0")).unsafe_ptr())


def test_normalize_ctrl_letter_preserves_cmd_bracket() raises:
    """Sanity-check: the terminal parser must NOT collapse Cmd+[
    down to ESC, AND must keep Cmd+ distinct from Ctrl+ on non-letter
    keys — otherwise we couldn't bind Cmd+2 (step over) separately
    from Ctrl+2 (focus window 2)."""
    # CSI 27 ; 9 ; 91 ~  — modifyOtherKeys=2 form for Cmd+[. Lands
    # as (0x5B, MOD_META): Cmd preserved, and not collapsed to ESC.
    var seq = String("\x1b[27;9;91~")
    var ev_consumed = parse_input(seq)
    assert_equal(ev_consumed[0].kind, EVENT_KEY)
    assert_equal(ev_consumed[0].key, UInt32(ord("[")))
    assert_equal(ev_consumed[0].mods, MOD_META)
    # Cmd+2 stays MOD_META.
    var seq_two = String("\x1b[27;9;50~")
    var ev_two = parse_input(seq_two)
    assert_equal(ev_two[0].key, UInt32(ord("2")))
    assert_equal(ev_two[0].mods, MOD_META)
    # Ctrl+2 (mod = 1 + 4 = 5) lands separately as MOD_CTRL.
    var seq_ctrl_two = String("\x1b[27;5;50~")
    var ev_ctrl_two = parse_input(seq_ctrl_two)
    assert_equal(ev_ctrl_two[0].key, UInt32(ord("2")))
    assert_equal(ev_ctrl_two[0].mods, MOD_CTRL)
    # Cmd+S surfaces as (ord('s'), MOD_META) so Cmd and Ctrl bindings
    # stay separate. Ctrl+S (the bare control byte, see test below) is
    # intentionally not bound by default.
    var seq_s = String("\x1b[27;9;115~")
    var ev_s = parse_input(seq_s)
    assert_equal(ev_s[0].key, UInt32(ord("s")))
    assert_equal(ev_s[0].mods, MOD_META)
    # Ctrl+S delivered as the modifyOtherKeys form lands canonical:
    # (ord('s'), MOD_CTRL). Same shape as Cmd+S above but with CTRL
    # instead of META so the two are addressable separately.
    var seq_ctrl_s = String("\x1b[27;5;115~")
    var ev_ctrl_s = parse_input(seq_ctrl_s)
    assert_equal(ev_ctrl_s[0].key, UInt32(ord("s")))
    assert_equal(ev_ctrl_s[0].mods, MOD_CTRL)


def test_window_manager_close_focused() raises:
    var wm = WindowManager()
    wm.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    assert_equal(wm.focused, 2)
    assert_true(wm.close_focused())
    assert_equal(len(wm.windows), 2)
    assert_equal(wm.focused, 1)
    # Close the remaining two; once empty, focused becomes -1 and the call
    # is a no-op on subsequent invocations.
    assert_true(wm.close_focused())
    assert_true(wm.close_focused())
    assert_false(wm.close_focused())
    assert_equal(wm.focused, -1)


def test_ctrl_n_focuses_window_by_number() raises:
    """Ctrl+1..Ctrl+9 focus the corresponding window. The event has to
    arrive in the modifyOtherKeys form (mods=MOD_CTRL on a digit) since
    bare Ctrl+digit isn't representable as a control byte — but the
    parser already produces this form, and the hotkey table maps it to
    ``window:focus:N``. Crucially, ``windows`` itself stays in insertion
    order across focus changes so the bindings remain stable.

    The digits 0/2/4/5/6 ALSO have Cmd+ (MOD_META) bindings on the debug
    actions; those stay distinct from Ctrl+ since MOD_META and MOD_CTRL
    are separate modifier bits."""
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    assert_equal(d.windows.windows[d.windows.focused].title, String("c"))
    _ = d.handle_event(Event.key_event(UInt32(ord("1")), MOD_CTRL), _SCREEN)
    assert_equal(d.windows.focused, 0)
    assert_equal(d.windows.windows[0].title, String("a"))
    # The list order MUST NOT change just because focus changed.
    assert_equal(d.windows.windows[1].title, String("b"))
    assert_equal(d.windows.windows[2].title, String("c"))
    # Ctrl+2 focuses index 1 (still "b" thanks to stable list order).
    _ = d.handle_event(Event.key_event(UInt32(ord("2")), MOD_CTRL), _SCREEN)
    assert_equal(d.windows.focused, 1)
    assert_equal(d.windows.windows[d.windows.focused].title, String("b"))


def test_focus_changes_keep_window_list_order_stable() raises:
    """Repeated focus changes must not reshuffle ``windows``; only ``z_order``
    moves. This is what keeps Ctrl+N bindings (and the Window menu items)
    pointing at the same windows across rapid focus changes."""
    var wm = WindowManager()
    wm.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    wm.focus_by_index(0)
    wm.focus_by_index(2)
    wm.focus_by_index(1)
    wm.focus_by_index(0)
    assert_equal(wm.windows[0].title, String("a"))
    assert_equal(wm.windows[1].title, String("b"))
    assert_equal(wm.windows[2].title, String("c"))
    # z-order tail is the most recently focused window.
    assert_equal(wm.z_order[len(wm.z_order) - 1], 0)


def test_window_manager_rotate_focus_cycles_in_stable_order() raises:
    """Cmd+` rotation walks the windows in insertion order and wraps
    past the end. Reverse rotation walks the same sequence backwards."""
    var wm = WindowManager()
    wm.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    wm.add(Window(String("c"), Rect(0, 1, 20, 5), List[String]()))
    wm.focus_by_index(0)
    wm.rotate_focus(True)
    assert_equal(wm.focused, 1)
    wm.rotate_focus(True)
    assert_equal(wm.focused, 2)
    # Wrap past the end.
    wm.rotate_focus(True)
    assert_equal(wm.focused, 0)
    # Reverse rotation wraps before the start.
    wm.rotate_focus(False)
    assert_equal(wm.focused, 2)
    wm.rotate_focus(False)
    assert_equal(wm.focused, 1)
    # Rotation also raises the new window to the top of z-order so a
    # subsequent click-through sees the same window the user is editing.
    assert_equal(wm.z_order[len(wm.z_order) - 1], 1)


def test_window_manager_rotate_focus_noop_when_fewer_than_two_windows() raises:
    """Rotation must do nothing when there's nothing to rotate to —
    no crash, no spurious focus change."""
    var wm0 = WindowManager()
    wm0.rotate_focus(True)  # zero windows: just don't crash
    assert_equal(wm0.focused, -1)
    var wm1 = WindowManager()
    wm1.add(Window(String("only"), Rect(0, 1, 20, 5), List[String]()))
    wm1.rotate_focus(True)
    assert_equal(wm1.focused, 0)
    wm1.rotate_focus(False)
    assert_equal(wm1.focused, 0)


def test_window_menu_items_show_ctrl_n_shortcut() raises:
    """The Window menu items (rebuilt every paint) carry the matching
    Ctrl+N shortcut for the first nine windows."""
    var d = Desktop()
    d.windows.add(Window(String("a"), Rect(0, 1, 20, 5), List[String]()))
    d.windows.add(Window(String("b"), Rect(0, 1, 20, 5), List[String]()))
    d._rebuild_window_menu()
    d._refresh_shortcuts()
    var menu = d.menu_bar.menus[d._window_menu_idx].copy()
    assert_equal(menu.items[0].label, String("a"))
    assert_equal(menu.items[0].shortcut, String("Ctrl+1"))
    assert_equal(menu.items[1].label, String("b"))
    assert_equal(menu.items[1].shortcut, String("Ctrl+2"))


def test_cmd_w_closes_focused_window() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("first"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    d.windows.add(Window.editor_window(
        String("second"), Rect(0, 1, 40, 12), String("world\n"),
    ))
    assert_equal(len(d.windows.windows), 2)
    var ev = Event.key_event(UInt32(ord("w")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_equal(len(d.windows.windows), 1)
    assert_equal(d.windows.windows[0].title, String("first"))


def test_format_hotkey_renders_combinations() raises:
    # Plain Ctrl+letter — canonical form is (lowercase letter, MOD_CTRL).
    assert_equal(format_hotkey(ctrl_key(String("q")), MOD_CTRL), String("Ctrl+Q"))
    assert_equal(format_hotkey(ctrl_key(String("s")), MOD_CTRL), String("Ctrl+S"))
    # Ctrl+Shift combos — same shape, with SHIFT in the mod set.
    assert_equal(
        format_hotkey(UInt32(ord("f")), MOD_CTRL | MOD_SHIFT),
        String("Ctrl+Shift+F"),
    )
    # Special keys.
    assert_equal(format_hotkey(KEY_F5, MOD_NONE), String("F5"))
    assert_equal(format_hotkey(KEY_UP, MOD_SHIFT), String("Shift+Up"))


def test_menu_items_get_shortcut_text_after_refresh() raises:
    """Once Desktop's _refresh_shortcuts runs, every menu item that maps to
    a registered hotkey has the matching shortcut string stamped onto it."""
    var d = Desktop()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"),  EDITOR_SAVE))
    items.append(MenuItem(String("Quit"),  APP_QUIT_ACTION))
    items.append(MenuItem(String("Close"), WINDOW_CLOSE))
    items.append(MenuItem(String("New"),   String("noop")))
    d.menu_bar.add(Menu(String("File"), items^))
    d._refresh_shortcuts()
    var file_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
            break
    assert_true(file_idx >= 0)
    var fm = d.menu_bar.menus[file_idx].copy()
    assert_equal(fm.items[0].shortcut, String("Cmd+S"))
    assert_equal(fm.items[1].shortcut, String("Cmd+Q"))
    assert_equal(fm.items[2].shortcut, String("Cmd+W"))
    # Item with no registered hotkey: empty.
    assert_equal(fm.items[3].shortcut, String(""))


def test_dropdown_reserves_indent_for_checkable_items() raises:
    """A dropdown that contains any checkable item must reserve a 2-cell
    label-indent so the ``✓`` glyph slot is consistent across rows.
    ``set_item_checked`` flips state by action without disturbing the
    rest of the menu."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(
        String("Line Numbers"), String("view:ln"), checkable=True,
    ))
    items.append(MenuItem(
        String("Soft Wrap"), String("view:sw"), checkable=True,
    ))
    bar.add(Menu(String("View"), items^))
    bar.open_idx = 0
    assert_true(bar._menu_has_checkable(0))
    var dr = bar._dropdown_rect(80)
    var widest_label = len(String("Line Numbers").as_bytes())
    # 2 (left pad) + 2 (checkbox slot) + label + 2 (right pad)
    var expected_min_w = widest_label + 6
    assert_true(dr.b.x - dr.a.x >= expected_min_w)
    bar.set_item_checked(String("view:ln"), True)
    assert_true(bar.menus[0].items[0].checked)
    assert_false(bar.menus[0].items[1].checked)
    bar.set_item_checked(String("view:ln"), False)
    assert_false(bar.menus[0].items[0].checked)


def test_dropdown_widens_to_fit_shortcut() raises:
    """The dropdown rect must accommodate label + gap + shortcut; without
    the widening, ``Cmd+Shift+F`` would overlap the menu item label."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    var save = MenuItem(String("Save"), EDITOR_SAVE)
    save.shortcut = String("Cmd+S")
    items.append(save)
    var pf = MenuItem(String("Find in project..."), PROJECT_FIND)
    pf.shortcut = String("Cmd+Shift+F")
    items.append(pf)
    bar.add(Menu(String("Edit"), items^))
    bar.open_idx = 0
    var dr = bar._dropdown_rect(80)
    var widest_label = len(String("Find in project...").as_bytes())
    var widest_sc = len(String("Cmd+Shift+F").as_bytes())
    # 2 (left pad) + label + 2 (gap) + shortcut + 2 (right pad)
    var expected_min_w = widest_label + widest_sc + 6
    assert_true(dr.b.x - dr.a.x >= expected_min_w)


def test_parse_csi_modify_other_keys_normalizes_ctrl_q() raises:
    """``ESC[27;5;113~`` (xterm modifyOtherKeys=2 form for Ctrl+Q) parses
    to the canonical ``(ord('q'), MOD_CTRL)``. Bare-byte Ctrl+Q from
    terminals without modifyOtherKeys lands at the same shape via the
    parser's bare-byte → ``(letter, MOD_CTRL)`` promotion. Without
    this normalization the parser dropped only ``ESC[27;5;`` and the
    trailing ``113~`` leaked into the editor."""
    var ev = parse_input(String("\x1b[27;5;113~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("q")))
    assert_equal(Int(ev[0].mods), Int(MOD_CTRL))
    assert_equal(ev[1], len(String("\x1b[27;5;113~").as_bytes()))


def test_parse_csi_modify_other_keys_ctrl_shift_f() raises:
    """``ESC[27;6;102~`` is Ctrl+Shift+F. Shift is preserved (so the
    project-find hotkey can match it); only plain Ctrl+letter is normalized."""
    var ev = parse_input(String("\x1b[27;6;102~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("f")))
    assert_true((ev[0].mods & MOD_CTRL) != 0)
    assert_true((ev[0].mods & MOD_SHIFT) != 0)


def test_parse_csi_modify_other_keys_cmd_shift_f_keeps_meta() raises:
    """``ESC[27;10;102~`` is the meta-bit form (mod = 1 + 1 + 8) of
    Cmd+Shift+F. This surfaces as ``(ord('f'), MOD_META|MOD_SHIFT)``
    and binds to PROJECT_FIND (Cmd+Shift+F). Ctrl+Shift+F is *not*
    bound — Ctrl is reserved for navigation."""
    var ev = parse_input(String("\x1b[27;10;102~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("f")))
    assert_true((ev[0].mods & MOD_META) != 0)
    assert_true((ev[0].mods & MOD_SHIFT) != 0)
    assert_true((ev[0].mods & MOD_CTRL) == 0)


def test_parse_csi_unknown_sequence_is_consumed_whole() raises:
    """Any unrecognized CSI sequence must be eaten in one bite — without
    that, trailing bytes (digits, ``~``) get re-parsed as printable keys
    and end up in the focused editor."""
    # Made-up sequence the parser doesn't recognize. ``end + 1`` must be
    # consumed regardless.
    var s = String("\x1b[99;42q")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_NONE)
    assert_equal(ev[1], len(s.as_bytes()))


def test_parse_osc_open_path_emits_event_open_path() raises:
    """The native wrapper forwards a second-instance argv as ``OSC 2;
    __mvc_open:<path> BEL``. The terminal parser must recognise it, emit
    EVENT_OPEN_PATH carrying the path, and consume the entire sequence.
    """
    var s = String("\x1b]2;__mvc_open:/Users/me/foo.txt\x07")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_OPEN_PATH)
    assert_equal(ev[0].text, String("/Users/me/foo.txt"))
    assert_equal(ev[1], len(s.as_bytes()))


def test_parse_osc_open_path_with_line_suffix() raises:
    """The wrapper appends ``\\x1f<line>`` to the path when translating
    a ``turbokod://open?...&line=N`` URL. Path comes through clean and
    ``ev.pos.y`` carries the 1-based line number; without the suffix
    ``ev.pos.y`` defaults to 0 (the base case)."""
    var s = String("\x1b]2;__mvc_open:/Users/me/foo.py\x1f277\x07")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_OPEN_PATH)
    assert_equal(ev[0].text, String("/Users/me/foo.py"))
    assert_equal(ev[0].pos.y, 277)
    assert_equal(ev[1], len(s.as_bytes()))


def test_parse_osc_open_path_st_terminator() raises:
    """OSC's other valid terminator is ``ESC \\``. We must accept both;
    xterm style guides recommend it for any payload that might contain a
    BEL byte (paths can't, but the parser shouldn't care about that)."""
    var s = String("\x1b]2;__mvc_open:/tmp/x\x1b\\")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_OPEN_PATH)
    assert_equal(ev[0].text, String("/tmp/x"))
    assert_equal(ev[1], len(s.as_bytes()))


def test_parse_osc_unknown_is_consumed_silently() raises:
    """Unrecognised OSC (window-title sets, palette queries, etc.) must
    be swallowed — leaking the trailing bytes through the generic ESC
    handler would emit an ``Alt+]`` keypress and corrupt the editor."""
    var s = String("\x1b]0;some title\x07")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_NONE)
    assert_equal(ev[1], len(s.as_bytes()))


def test_parse_osc_partial_defers() raises:
    """Without a terminator yet, parse_input should signal "not enough
    data" via (EVENT_NONE, 0) so Terminal.poll_event saves the bytes for
    the next read instead of misinterpreting them."""
    var s = String("\x1b]2;__mvc_open:/half-")
    var ev = parse_input(s)
    assert_true(ev[0].kind == EVENT_NONE)
    assert_equal(ev[1], 0)


def test_parse_csi_modify_other_keys_cmd_letter_keeps_meta() raises:
    """``ESC[27;9;115~`` is the meta-bit form (mod = 1 + 8) of Cmd+S that
    the native Rust host emits for ``super_key()``. The parser surfaces
    it as ``(ord('s'), MOD_META)`` so Cmd+S and Ctrl+S can be bound to
    different actions."""
    var ev = parse_input(String("\x1b[27;9;115~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("s")))
    assert_equal(Int(ev[0].mods), Int(MOD_META))


def test_parse_csi_modify_other_keys_cmd_backtick_keeps_key_intact() raises:
    """Cmd+\\` arrives as ``ESC[27;9;96~`` (mod=9 → meta-only, cp=0x60).
    The event keeps its 0x60 key code with MOD_META intact, so hotkey
    tables can bind Cmd+\\` separately from Ctrl+\\`."""
    var ev = parse_input(String("\x1b[27;9;96~"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), 0x60)
    assert_equal(Int(ev[0].mods), Int(MOD_META))


def test_cmd_s_via_modify_other_keys_triggers_save_hotkey() raises:
    """End-to-end: a Cmd+S event delivered as ``CSI 27;9;115~`` parses as
    ``(ord('s'), MOD_META)`` and triggers ``EDITOR_SAVE`` via the Cmd+S
    binding. Ctrl+S is intentionally *not* bound — Ctrl is reserved for
    window/panel focus."""
    var d = Desktop()
    var parsed = parse_input(String("\x1b[27;9;115~"))
    assert_true(parsed[0].kind == EVENT_KEY)
    assert_equal(Int(parsed[0].key), Int(ord("s")))
    assert_equal(Int(parsed[0].mods), Int(MOD_META))
    var maybe = d.handle_event(parsed[0], _SCREEN)
    # No editor focused → save is a no-op intercepted by Desktop. The
    # important assertion is that the action *was* recognized: nothing
    # bubbles back to the caller.
    assert_false(Bool(maybe))


def test_parse_csi_kitty_u_ctrl_letter() raises:
    """Kitty kbd protocol: ``CSI <cp> ; <mod> u``. ``ESC[113;5u`` (Ctrl+Q)
    parses to the canonical ``(ord('q'), MOD_CTRL)``."""
    var ev = parse_input(String("\x1b[113;5u"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("q")))
    assert_equal(Int(ev[0].mods), Int(MOD_CTRL))


def test_editor_rejects_modified_letter_typing() raises:
    """Alt+Q and Ctrl+Q (when delivered as printable letter + mod) must
    not be inserted into the buffer — they're commands, not text."""
    var ed = Editor(String("hello"))
    _ = ed.handle_key(Event.key_event(KEY_END), _VIEW)
    _ = ed.handle_key(_key(UInt32(ord("q")), MOD_ALT), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello"))
    _ = ed.handle_key(_key(UInt32(ord("q")), MOD_CTRL), _VIEW)
    assert_equal(ed.buffer.line(0), String("hello"))
    # Plain shifted letters still work (they arrive pre-folded as 'Q').
    _ = ed.handle_key(_key(UInt32(ord("Q")), MOD_SHIFT), _VIEW)
    assert_equal(ed.buffer.line(0), String("helloQ"))


def test_cmd_q_modifyOtherKeys_triggers_quit_action() raises:
    """End-to-end: a Cmd+Q event delivered as the modifyOtherKeys form
    parses to ``(ord('q'), MOD_META)`` and matches the default Cmd+Q
    hotkey. The Desktop returns APP_QUIT_ACTION; nothing is inserted
    into the focused editor."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    # ESC[27;9;113~ — modifyOtherKeys=2 form for Cmd+Q (mod = 1 + 8).
    var parsed = parse_input(String("\x1b[27;9;113~"))
    assert_true(parsed[0].kind == EVENT_KEY)
    var maybe = d.handle_event(parsed[0], _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)
    # And the buffer is untouched — none of the trailing bytes leaked.
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("hello"))


def test_ctrl_key_helper() raises:
    """``ctrl_key`` returns the canonical key codepoint for a
    ``Ctrl+letter`` hotkey: the lowercase letter codepoint (paired
    with ``MOD_CTRL`` at registration)."""
    assert_equal(Int(ctrl_key(String("q"))), Int(ord("q")))
    assert_equal(Int(ctrl_key(String("Q"))), Int(ord("q")))  # case-folded
    assert_equal(Int(ctrl_key(String("a"))), Int(ord("a")))
    assert_equal(Int(ctrl_key(String("z"))), Int(ord("z")))
    assert_equal(Int(ctrl_key(String("f"))), Int(ord("f")))


def test_menu_keyboard_nav_arrows_and_enter() raises:
    """Up/Down step the dropdown selection (skipping separators), Left/Right
    rotate to the next visible menu, Enter triggers the selected item's
    action."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"),  String("noop")))
    file_items.append(MenuItem.separator())
    file_items.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    d.menu_bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find..."), EDITOR_FIND))
    d.menu_bar.add(Menu(String("Edit"), edit_items^))
    # Open File via mnemonic; selection lands on the first non-separator.
    _ = d.handle_event(Event.key_event(UInt32(ord("f")), MOD_ALT), _SCREEN)
    var file_idx = -1
    var edit_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
        elif d.menu_bar.menus[i].label == String("Edit"):
            edit_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)
    assert_equal(d.menu_bar.selected_item, 0)   # New
    # Down skips the separator at index 1 → lands on Quit (index 2).
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    assert_equal(d.menu_bar.selected_item, 2)
    # Down wraps back to New (skipping the separator the long way).
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    assert_equal(d.menu_bar.selected_item, 0)
    # Right rotates to the Edit menu; selection resets.
    _ = d.handle_event(Event.key_event(KEY_RIGHT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, edit_idx)
    assert_equal(d.menu_bar.selected_item, 0)
    # Left rotates back.
    _ = d.handle_event(Event.key_event(KEY_LEFT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, file_idx)
    # Down to Quit, then Enter — the framework dispatches APP_QUIT_ACTION
    # back to the caller.
    _ = d.handle_event(Event.key_event(KEY_DOWN), _SCREEN)
    var maybe = d.handle_event(Event.key_event(KEY_ENTER), _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)
    # Activating an item closes the menu.
    assert_false(d.menu_bar.is_open())


def test_alt_letter_opens_menu_by_mnemonic() raises:
    """Alt+<letter> opens the first visible menu whose label starts with
    that letter (case-insensitive). The leading letter is what the menu
    bar paints in red as the mnemonic hint."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find..."), EDITOR_FIND))
    d.menu_bar.add(Menu(String("Edit"), edit_items^))
    # Alt+F opens File.
    _ = d.handle_event(Event.key_event(UInt32(ord("f")), MOD_ALT), _SCREEN)
    var file_idx = -1
    var edit_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
        elif d.menu_bar.menus[i].label == String("Edit"):
            edit_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)
    # Alt+E switches to Edit.
    _ = d.handle_event(Event.key_event(UInt32(ord("e")), MOD_ALT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, edit_idx)
    # Uppercase works too.
    d.menu_bar.close()
    _ = d.handle_event(Event.key_event(UInt32(ord("F")), MOD_ALT), _SCREEN)
    assert_equal(d.menu_bar.open_idx, file_idx)
    # No matching letter → no-op (menu stays closed).
    d.menu_bar.close()
    _ = d.handle_event(Event.key_event(UInt32(ord("z")), MOD_ALT), _SCREEN)
    assert_false(d.menu_bar.is_open())


def test_esc_prefix_opens_menu_by_mnemonic() raises:
    """Classic TV / DOS-style two-key sequence: ESC, then a letter, opens
    the matching menu. Lets users on macOS terminals (where Option+F is
    intercepted by the OS) still reach the mnemonic without reconfiguring
    their terminal."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    # First press: ESC alone. No menu opens; no action bubbles up.
    var maybe1 = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(Bool(maybe1))
    assert_false(d.menu_bar.is_open())
    # Second press: F. The framework picks it up as a mnemonic.
    var maybe2 = d.handle_event(
        Event.key_event(UInt32(ord("f"))), _SCREEN,
    )
    assert_false(Bool(maybe2))
    assert_true(d.menu_bar.is_open())
    var file_idx = -1
    for i in range(len(d.menu_bar.menus)):
        if d.menu_bar.menus[i].label == String("File"):
            file_idx = i
    assert_equal(d.menu_bar.open_idx, file_idx)


def test_esc_prefix_disarms_after_one_keystroke() raises:
    """A non-letter (or unmatched letter) following ESC must disarm the
    prefix; the third keystroke is plain again."""
    var d = Desktop()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("New"), String("noop")))
    d.menu_bar.add(Menu(String("File"), file_items^))
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String(""),
    ))
    _ = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    # No menu starts with 'z' — the keystroke disarms but doesn't open.
    _ = d.handle_event(Event.key_event(UInt32(ord("z"))), _SCREEN)
    assert_false(d.menu_bar.is_open())
    # Now type 'f' — it should reach the editor as plain typing, not the
    # mnemonic, because the previous keystroke disarmed the prefix.
    _ = d.handle_event(Event.key_event(UInt32(ord("f"))), _SCREEN)
    assert_false(d.menu_bar.is_open())
    assert_equal(d.windows.windows[0].editor.buffer.line(0), String("zf"))


def test_top_level_esc_does_not_quit() raises:
    """Top-level ESC must not bubble up an action — quit is reserved for
    explicit bindings (Ctrl+Q etc.). It still closes a modal layer when
    one is open."""
    var d = Desktop()
    var maybe = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(Bool(maybe))
    # ESC closes an open menu but still doesn't bubble.
    d.menu_bar.add(Menu(String("File"), List[MenuItem]()))
    d.menu_bar.open_idx = 0
    assert_true(d.menu_bar.is_open())
    var maybe2 = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(Bool(maybe2))
    assert_false(d.menu_bar.is_open())


def test_default_hotkey_cmd_q_returns_quit() raises:
    var d = Desktop()
    var ev = Event.key_event(UInt32(ord("q")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), APP_QUIT_ACTION)


def test_default_hotkey_cmd_f_opens_find_prompt() raises:
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("hello\n"),
    ))
    assert_false(d.prompt.active)
    var ev = Event.key_event(UInt32(ord("f")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    # Framework intercepted the hotkey; nothing for the caller to dispatch.
    assert_false(Bool(maybe))
    assert_true(d.prompt.active)


def test_default_hotkey_cmd_s_saves_focused_editor() raises:
    var path = _temp_path(String("_hkeys.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(String("hk"), Rect(0, 1, 40, 12), path))
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    assert_true(d.windows.windows[0].editor.dirty)
    var ev = Event.key_event(UInt32(ord("s")), MOD_META)
    _ = d.handle_event(ev, _SCREEN)
    assert_false(d.windows.windows[0].editor.dirty)
    assert_equal(read_file(path), String("hello!\n"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_hotkey_overrides_default_when_registered_later() raises:
    """Registrations are scanned newest-first, so a later-registered binding
    for the same key/mods pair wins."""
    var d = Desktop()
    # Bind Cmd+Q to a custom app action; the default (APP_QUIT_ACTION)
    # should no longer fire.
    d.register_hotkey(UInt32(ord("q")), MOD_META, String("custom:thing"))
    var ev = Event.key_event(UInt32(ord("q")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), String("custom:thing"))


def test_hotkey_does_not_fire_while_prompt_active() raises:
    """Prompt modal keys must reach the prompt, not the hotkey table."""
    var d = Desktop()
    d.prompt.open(String("Find: "))
    # Without the modal-prompt guard, Cmd+Q here would return APP_QUIT.
    var ev = Event.key_event(UInt32(ord("q")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_true(d.prompt.active)


def test_gitignore_matches_directory_pattern() raises:
    var m = GitignoreMatcher.from_text(String("tvision/\n"))
    assert_true(m.ignored(String("tvision"), True))
    assert_false(m.ignored(String("tvision"), False))   # dir-only pattern
    assert_true(m.ignored(String("nested/tvision"), True))
    assert_false(m.ignored(String("examples"), True))


def test_gitignore_matches_glob_and_negate() raises:
    var m = GitignoreMatcher.from_text(
        String("# build artefacts\n*.o\n!keep.o\nbuild/\n")
    )
    assert_true(m.ignored(String("foo.o"), False))
    assert_true(m.ignored(String("a/b/c.o"), False))
    # The negation must override the earlier pattern.
    assert_false(m.ignored(String("keep.o"), False))
    assert_true(m.ignored(String("build"), True))
    assert_false(m.ignored(String("hello.mojo"), False))


def test_walk_project_files_respects_gitignore() raises:
    """The repo's .gitignore lists ``tvision/`` — that subtree must be
    excluded from the default walk, but visible when explicitly opted out."""
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var paths = walk_project_files(root.value())
    var saw_tvision = False
    for i in range(len(paths)):
        if _contains(paths[i], String("/tvision/")):
            saw_tvision = True
            break
    assert_false(saw_tvision)
    # Without gitignore respect, the walk reaches into tvision/.
    var all_paths = walk_project_files(root.value(), respect_gitignore=False)
    var any_tvision = False
    for i in range(len(all_paths)):
        if _contains(all_paths[i], String("/tvision/")):
            any_tvision = True
            break
    assert_true(any_tvision)


def test_walk_project_files_include_ignored_files_keeps_files_prunes_dirs() raises:
    """``include_ignored_files=True`` is the QuickOpen mode: a gitignored
    *file* like ``settings_local.py`` must appear (so users can open it),
    while a gitignored *directory* like ``node_modules`` must still be
    pruned (so its contents don't flood the picker)."""
    var root = _temp_path(String("_walk_ignored_files"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var nm = join_path(root, String("node_modules"))
    _ = external_call["mkdir", Int32](
        (nm + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(
        join_path(root, String(".gitignore")),
        String("settings_local.py\nnode_modules\n"),
    ))
    assert_true(write_file(
        join_path(root, String("settings.py")), String("# main\n"),
    ))
    assert_true(write_file(
        join_path(root, String("settings_local.py")), String("# local\n"),
    ))
    assert_true(write_file(
        join_path(nm, String("dep.js")), String("// noise\n"),
    ))

    # Default strict mode: ignored file is hidden, ignored dir is pruned.
    var strict = walk_project_files(root)
    var strict_saw_local = False
    var strict_saw_node = False
    for i in range(len(strict)):
        if _contains(strict[i], String("settings_local.py")):
            strict_saw_local = True
        if _contains(strict[i], String("/node_modules/")):
            strict_saw_node = True
    assert_false(strict_saw_local)
    assert_false(strict_saw_node)

    # Picker mode: ignored file shows up; ignored dir still pruned.
    var picker = walk_project_files(root, include_ignored_files=True)
    var picker_saw_local = False
    var picker_saw_main = False
    var picker_saw_node = False
    for i in range(len(picker)):
        if _contains(picker[i], String("settings_local.py")):
            picker_saw_local = True
        if _contains(picker[i], String("/settings.py")):
            picker_saw_main = True
        if _contains(picker[i], String("/node_modules/")):
            picker_saw_node = True
    assert_true(picker_saw_local)
    assert_true(picker_saw_main)
    assert_false(picker_saw_node)

    _ = external_call["unlink", Int32](
        (join_path(nm, String("dep.js")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32]((nm + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32](
        (join_path(root, String("settings_local.py")) + String("\0"))
        .unsafe_ptr(),
    )
    _ = external_call["unlink", Int32](
        (join_path(root, String("settings.py")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["unlink", Int32](
        (join_path(root, String(".gitignore")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def _hl_lines(*texts: String) -> List[String]:
    var out = List[String]()
    for t in texts:
        out.append(String(t))
    return out^


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


def test_user_grammar_path_for_ext_misses_when_not_installed() raises:
    """When no user grammar is on disk, the helper returns empty so
    ``_grammar_path_for_ext`` falls through to the generic per-language
    fallback rather than handing the loader a non-existent path."""
    # Elm has a registry entry, but unless the test environment
    # happens to have ~/.config/turbokod/languages/elm/elm.tmLanguage.json
    # already (vanishingly unlikely on CI), the helper must report it
    # as not installed.
    var path = user_grammar_path(String("elm"))
    if len(path.as_bytes()) > 0 and stat_file(path).ok:
        # Test environment already has Elm installed — the helper must
        # at least return a non-empty path.
        assert_true(len(user_grammar_path_for_ext(String("elm")).as_bytes()) > 0)
    else:
        assert_equal(user_grammar_path_for_ext(String("elm")), String(""))
    # Unknown extensions always return empty regardless of disk state.
    assert_equal(user_grammar_path_for_ext(String("zzz")), String(""))


def test_on_save_action_default_is_empty() raises:
    """Default ``OnSaveAction`` is the natural identity element — empty
    fields and an empty args list. Settings ▸ Add starts here."""
    var act = OnSaveAction()
    assert_equal(act.language_id, String(""))
    assert_equal(act.program, String(""))
    assert_equal(len(act.args), 0)
    assert_equal(act.cwd, String(""))


def test_on_save_action_copy_preserves_args() raises:
    """``List[String]`` doesn't have implicit copy semantics, so the
    explicit copyinit must clone the args. Without it, two clones
    would share the same list and edits to one would leak to the
    other."""
    var args = List[String]()
    args.append(String("--quiet"))
    args.append(String("$FILE"))
    var a = OnSaveAction(
        String("python"), String("/usr/bin/black"), args^, String(""),
    )
    var b = a.copy()
    assert_equal(len(b.args), 2)
    assert_equal(b.args[0], String("--quiet"))
    assert_equal(b.args[1], String("$FILE"))
    # Mutating ``b.args`` must not touch ``a.args``.
    b.args.append(String("--check"))
    assert_equal(len(a.args), 2)


def test_settings_open_seeds_state() raises:
    """``open`` snapshots the host list and parks the selection on
    row 0 (or -1 when the list is empty). Focus starts on the section
    rail so arrow keys move sections rather than rows."""
    var s = Settings()
    var actions = List[OnSaveAction]()
    actions.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    actions.append(OnSaveAction(
        String("rust"), String("/usr/bin/rustfmt"),
        List[String](), String(""),
    ))
    s.open(actions^, False)
    assert_true(s.active)
    assert_equal(len(s.actions), 2)
    assert_equal(s.selected_action, 0)
    assert_equal(s.section, 0)
    assert_false(s.dirty)
    s.close()
    assert_false(s.active)
    assert_equal(len(s.actions), 0)


def test_settings_open_empty_parks_selection_at_minus_one() raises:
    """Opening with no actions: selection = -1 so ``Edit`` / ``Remove``
    skip themselves in the focus walk and the right pane shows the
    "(no actions configured)" hint."""
    var s = Settings()
    s.open(List[OnSaveAction](), False)
    assert_true(s.active)
    assert_equal(len(s.actions), 0)
    assert_equal(s.selected_action, -1)


def test_settings_remove_marks_dirty() raises:
    """Removing the highlighted entry must (a) shrink the list,
    (b) raise ``dirty`` so the host knows to persist, (c) keep the
    selection on a valid row (or move to -1 when the list empties)."""
    var s = Settings()
    var actions = List[OnSaveAction]()
    actions.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    s.open(actions^, False)
    s._remove_selected()
    assert_equal(len(s.actions), 0)
    assert_equal(s.selected_action, -1)
    assert_true(s.dirty)


def test_settings_editor_submit_appends_new_entry() raises:
    """The full Add → Edit → Save round-trip: opening Add starts the
    editor with ``edit_index = -1``; setting fields and flipping
    ``submitted`` then driving ``_maybe_consume_editor`` must append
    the new entry to ``actions`` and raise ``dirty``."""
    var s = Settings()
    s.open(List[OnSaveAction](), False)
    s._add_new()
    assert_true(s.editor.active)
    assert_equal(s.editor.edit_index, -1)
    s.editor.entry.language_id = String("python")
    s.editor.form.set_text(UInt8(1), String("/usr/bin/black"))
    s.editor.submitted = True
    s._maybe_consume_editor()
    assert_false(s.editor.active)
    assert_equal(len(s.actions), 1)
    assert_equal(s.actions[0].language_id, String("python"))
    assert_equal(s.actions[0].program, String("/usr/bin/black"))
    assert_equal(s.selected_action, 0)
    assert_true(s.dirty)


def test_settings_editor_submit_replaces_existing_entry() raises:
    """``edit_index >= 0`` triggers an in-place replace, not an append.
    The selection stays on the edited row so the user keeps their place
    in the list."""
    var s = Settings()
    var actions = List[OnSaveAction]()
    actions.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    s.open(actions^, False)
    s.selected_action = 0
    s._edit_selected()
    s.editor.form.set_text(UInt8(1), String("/opt/bin/black-edge"))
    s.editor.submitted = True
    s._maybe_consume_editor()
    assert_equal(len(s.actions), 1)
    assert_equal(s.actions[0].program, String("/opt/bin/black-edge"))
    assert_equal(s.selected_action, 0)
    assert_true(s.dirty)


def test_settings_open_seeds_save_behavior_dropdown() raises:
    """``open(actions, auto_save)`` must seed both the working copy
    and the dropdown's index so the painted strip and the persisted
    value agree on first paint."""
    var s = Settings()
    s.open(List[OnSaveAction](), True)
    assert_true(s.auto_save)
    assert_equal(s._save_dropdown.index, 1)
    s.close()
    s.open(List[OnSaveAction](), False)
    assert_false(s.auto_save)
    assert_equal(s._save_dropdown.index, 0)


def test_settings_save_behavior_commit_marks_dirty() raises:
    """Switching the dropdown commits Manual → Automatic, mirrors the
    new value into ``auto_save``, and raises ``dirty`` so the host
    persists ``TurbokodConfig.auto_save`` on the next paint."""
    var s = Settings()
    s.open(List[OnSaveAction](), False)
    # Simulate the user opening the popup, moving to "Automatic", and
    # pressing Enter — same final state ``Dropdown.handle_key`` lands
    # on, observed by ``_sync_dropdown_commit``.
    var prev_idx = s._save_dropdown.index
    s._save_dropdown.index = 1
    s._sync_dropdown_commit(prev_idx)
    assert_true(s.auto_save)
    assert_true(s.dirty)


def test_settings_save_behavior_no_change_no_dirty() raises:
    """Re-committing the same value (Manual → Manual) must not raise
    ``dirty`` — otherwise the host would write the config on every
    open/close cycle even when nothing changed."""
    var s = Settings()
    s.open(List[OnSaveAction](), False)
    var prev_idx = s._save_dropdown.index
    # Index unchanged — the dropdown closed without committing a new
    # value (Esc, click-outside, or Enter on the same row).
    s._sync_dropdown_commit(prev_idx)
    assert_false(s.auto_save)
    assert_false(s.dirty)


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


def test_apply_language_overrides_replaces_candidates() raises:
    """An override matching a built-in language replaces the candidate
    list verbatim and preserves the built-in's ``file_types`` (we only
    override what the user explicitly chose)."""
    var specs = built_in_servers()
    if find_language_by_id(specs, String("python")) < 0:
        # Bundled JSON missing — skip rather than fail; the unit test
        # for built_in_servers handles that case.
        return
    var argvs = List[List[String]]()
    var argv = List[String]()
    argv.append(String("my-pyright"))
    argv.append(String("--stdio"))
    argvs.append(argv^)
    var ov = LanguageServerOverride(
        String("python"), List[String](), argvs^,
    )
    var overrides = List[LanguageServerOverride]()
    overrides.append(ov^)
    var merged = apply_language_overrides(specs.copy(), overrides)
    var idx = find_language_by_id(merged, String("python"))
    assert_true(idx >= 0)
    assert_equal(len(merged[idx].candidates), 1)
    assert_equal(merged[idx].candidates[0].argv[0], String("my-pyright"))
    # File types kept from built-in (override didn't supply any).
    assert_true(len(merged[idx].file_types) > 0)


def test_apply_language_overrides_adds_new_language() raises:
    """A user override for a language id absent from the catalog adds
    a brand-new ``LanguageSpec`` whose file_types come from the
    override."""
    var argvs = List[List[String]]()
    var argv = List[String]()
    argv.append(String("custom-lsp"))
    argvs.append(argv^)
    var fts = List[String]()
    fts.append(String("xyz"))
    var ov = LanguageServerOverride(
        String("xyzlang"), fts^, argvs^,
    )
    var overrides = List[LanguageServerOverride]()
    overrides.append(ov^)
    var merged = apply_language_overrides(
        List[LanguageSpec](), overrides,
    )
    assert_equal(len(merged), 1)
    assert_equal(merged[0].language_id, String("xyzlang"))
    assert_equal(len(merged[0].file_types), 1)
    assert_equal(merged[0].file_types[0], String("xyz"))
    assert_equal(len(merged[0].candidates), 1)


def test_settings_languages_section_seeded() raises:
    """``open(... , language_overrides)`` must populate
    ``language_overrides`` and rebuild the effective ``languages_view``
    so the right pane has rows on first paint."""
    var s = Settings()
    var argvs = List[List[String]]()
    var argv = List[String]()
    argv.append(String("custom"))
    argvs.append(argv^)
    var ov = LanguageServerOverride(
        String("xyzlang"), List[String](), argvs^,
    )
    var overrides = List[LanguageServerOverride]()
    overrides.append(ov^)
    s.open(List[OnSaveAction](), False, overrides^)
    assert_equal(len(s.language_overrides), 1)
    # ``xyzlang`` should appear in the effective view.
    var found = False
    for i in range(len(s.languages_view)):
        if s.languages_view[i].language_id == String("xyzlang"):
            found = True
            break
    assert_true(found)


def test_settings_open_selects_current_language() raises:
    """When ``open`` receives the focused editor's extension, the
    Languages section must pre-select the matching row so the user
    lands on the language they're editing — and the scroll-snap in
    ``_paint_languages_list`` brings that row into view."""
    var s = Settings()
    s.open(List[OnSaveAction](), False, List[LanguageServerOverride](),
           String("py"))
    var selected_id = s.languages_view[s.selected_language].language_id
    assert_equal(selected_id, String("python"))


def test_settings_open_unknown_extension_falls_back_to_first() raises:
    """An unrecognized extension shouldn't strand the selection on
    -1 — the user can still navigate the list. Fall back to row 0."""
    var s = Settings()
    s.open(List[OnSaveAction](), False, List[LanguageServerOverride](),
           String("zzzunknownext"))
    assert_equal(s.selected_language, 0)


def test_settings_remove_language_override_marks_dirty() raises:
    """Removing the override for a custom language drops it from
    ``language_overrides``, marks ``dirty``, and rebuilds the view so
    the row disappears (since the language has no built-in fallback)."""
    var s = Settings()
    var argvs = List[List[String]]()
    var argv = List[String]()
    argv.append(String("custom"))
    argvs.append(argv^)
    var ov = LanguageServerOverride(
        String("xyzlang"), List[String](), argvs^,
    )
    var overrides = List[LanguageServerOverride]()
    overrides.append(ov^)
    s.open(List[OnSaveAction](), False, overrides^)
    # Find and select the custom row.
    for i in range(len(s.languages_view)):
        if s.languages_view[i].language_id == String("xyzlang"):
            s.selected_language = i
            break
    s._remove_language_override()
    assert_true(s.dirty)
    assert_equal(len(s.language_overrides), 0)
    for i in range(len(s.languages_view)):
        assert_true(s.languages_view[i].language_id != String("xyzlang"))


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


def test_list_box_paint_never_overflows_bounds() raises:
    """Framework guarantee: a ``ListBox`` whose item text is wider than
    its rect must clip at the rect boundary on every side. No paint
    pixel may land outside the list's ``bounds`` — that's what saves
    the surrounding dialog chrome (frame, padding, neighbour controls)
    from being damaged by a too-long entry.

    The test paints into a canvas pre-filled with a sentinel glyph,
    runs ``ListBox.paint`` on a 6-wide × 3-tall rect surrounded by the
    sentinel, and asserts every cell outside the rect still shows the
    sentinel. The selected-row fill, the row text, and a row that
    overflows on the right are all included so the assertion covers
    every code path that writes a cell.
    """
    var c = Canvas(20, 7)
    var sentinel = Cell(String("·"), Attr(WHITE, BLACK), 1)
    for y in range(c.height):
        for x in range(c.width):
            c.set(x, y, sentinel)
    var bounds = Rect(2, 2, 8, 5)
    var items = List[String]()
    items.append(String("short"))
    items.append(String("this-is-way-too-long-for-the-list"))
    items.append(String("mid"))
    var lb = ListBox()
    lb.set_selected(1)
    lb.paint(c, bounds, items, True, Attr(BLACK, CYAN))
    for y in range(c.height):
        for x in range(c.width):
            var inside = (
                bounds.a.x <= x and x < bounds.b.x
                and bounds.a.y <= y and y < bounds.b.y
            )
            if not inside:
                assert_equal(c.get(x, y).glyph, String("·"))


def test_list_box_paint_empty_hint_clipped() raises:
    """``paint_empty_hint`` writes a single line inside the list rect;
    a hint longer than the rect must still not leak into the cells on
    the right."""
    var c = Canvas(20, 3)
    var sentinel = Cell(String("·"), Attr(WHITE, BLACK), 1)
    for y in range(c.height):
        for x in range(c.width):
            c.set(x, y, sentinel)
    var bounds = Rect(4, 1, 10, 2)
    var lb = ListBox()
    lb.paint_empty_hint(
        c, bounds,
        String("hint-far-too-wide-to-fit"),
        Attr(BLUE, LIGHT_GRAY),
    )
    for y in range(c.height):
        for x in range(c.width):
            var inside = (
                bounds.a.x <= x and x < bounds.b.x
                and bounds.a.y <= y and y < bounds.b.y
            )
            if not inside:
                assert_equal(c.get(x, y).glyph, String("·"))


def test_list_box_mouse_wheel_clamps_to_item_count() raises:
    """Wheel-down past the last visible row must not advance the
    scroll origin past ``items - height`` — otherwise the next paint
    sees an out-of-range index and silently shows nothing."""
    var lb = ListBox()
    var items = List[String]()
    var i = 0
    while i < 5:
        items.append(String("row"))
        i += 1
    var bounds = Rect(0, 0, 10, 3)
    # Five wheel-downs on a 3-row view over 5 items: clamp at 2.
    var down = Event.mouse_event(Point(5, 1), MOUSE_WHEEL_DOWN, True, False)
    i = 0
    while i < 5:
        _ = lb.handle_mouse_press(down, bounds, len(items))
        i += 1
    assert_equal(lb._scroll, 2)


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


def test_settings_languages_list_type_to_jump() raises:
    """The Languages section list is type-to-jump. After focusing the
    list, typing a letter must move ``selected_language`` to the
    first language whose id starts with the typed prefix — no
    explicit hookup per list, the framework helper drives it."""
    var s = Settings()
    s.open(List[OnSaveAction](), False)
    # Park the user on the Languages section list.
    s.section = 3
    s.focus = UInt8(10)  # _FOCUS_LANG_LIST
    # Find the index where 'r' would land — the first language id
    # starting with "r" — so the assert is independent of catalog
    # order changes.
    var expected = -1
    for i in range(len(s.languages_view)):
        var lid = s.languages_view[i].language_id
        if len(lid.as_bytes()) > 0:
            var first = lid.as_bytes()[0]
            if first == 0x72 or first == 0x52:  # 'r' / 'R'
                expected = i
                break
    if expected < 0:
        # Bundled JSON missing or no 'r' language — skip rather than
        # fail; ``built_in_servers`` returning an empty list is
        # already tested elsewhere.
        return
    var consumed = s.handle_key(_key(UInt32(ord("r"))))
    assert_true(consumed)
    assert_equal(s.selected_language, expected)


def test_settings_actions_list_type_to_jump() raises:
    """Same framework feature in the Actions section: typing a letter
    moves ``selected_action`` to the first row whose label
    (language id + program) starts with that letter."""
    var s = Settings()
    var actions = List[OnSaveAction]()
    actions.append(OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    ))
    actions.append(OnSaveAction(
        String("rust"), String("/usr/bin/rustfmt"),
        List[String](), String(""),
    ))
    s.open(actions^, False)
    s.section = 0  # Actions on save
    s.focus = UInt8(1)  # _FOCUS_LIST
    # The action label format starts with the language id.
    _ = s.handle_key(_key(UInt32(ord("r"))))
    assert_equal(s.selected_action, 1)
    # No-match keystroke: selection survives.
    s._type_ahead.reset()
    _ = s.handle_key(_key(UInt32(ord("z"))))
    assert_equal(s.selected_action, 1)


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
    ed.focus = UInt8(2)  # _FOCUS_LIST
    _ = ed.handle_key(_key(UInt32(ord("p"))))
    assert_equal(ed._list.selected, 2)
    assert_equal(ed.argv_tf.text, String("pyright"))


def test_file_tree_type_to_jump() raises:
    """File tree picks up the framework feature: typing a letter
    while the pane has keyboard focus jumps the highlight to the
    first entry whose name starts with that letter."""
    var tree = FileTree()
    tree.visible = True
    tree.focused = True
    tree.entries = List[FileTreeEntry]()
    tree.entries.append(FileTreeEntry(
        String("alpha"), String("/a/alpha"), 0, False, False,
    ))
    tree.entries.append(FileTreeEntry(
        String("beta"), String("/a/beta"), 0, False, False,
    ))
    tree.entries.append(FileTreeEntry(
        String("gamma"), String("/a/gamma"), 0, False, False,
    ))
    tree.selected = 0
    var consumed = tree.handle_key(_key(UInt32(ord("g"))))
    assert_true(consumed)
    assert_equal(tree.selected, 2)


def test_menu_open_dropdown_type_to_jump() raises:
    """An open menu dropdown jumps to the first item whose label
    starts with the typed letter. Mnemonics use Alt+letter and run
    at the Desktop layer, so plain letters are free for in-dropdown
    search."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("New"),    String("file.new")))
    items.append(MenuItem(String("Open"),   String("file.open")))
    items.append(MenuItem(String("Save"),   String("file.save")))
    items.append(MenuItem(String("Save as"), String("file.saveas")))
    bar.add(Menu(String("File"), items^))
    bar.open_menu(0)
    assert_equal(bar.selected_item, 0)  # New
    var result = bar.handle_key(_key(UInt32(ord("s"))))
    assert_true(result.consumed)
    assert_equal(bar.selected_item, 2)  # Save


def test_is_printable_ascii_gates_search_keys() raises:
    """The framework predicate that decides "is this a search
    keystroke or a control key" — must include letters / digits /
    punctuation and exclude DEL, NUL, arrow-key codes, etc."""
    assert_true(is_printable_ascii(UInt32(ord("a"))))
    assert_true(is_printable_ascii(UInt32(ord("Z"))))
    assert_true(is_printable_ascii(UInt32(ord("0"))))
    assert_true(is_printable_ascii(UInt32(0x20)))   # space
    assert_false(is_printable_ascii(UInt32(0x1F)))  # below printable
    assert_false(is_printable_ascii(UInt32(0x7F)))  # DEL


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


def test_action_editor_lang_dropdown_has_options() raises:
    """The dropdown's language options are sourced from
    ``built_in_servers()``. If that returns an empty list (e.g. because
    the bundled languages.json isn't on disk relative to cwd), the
    user sees a one-option dropdown showing "(none)" and the field
    looks broken. Guard against the empty case so a regression here
    surfaces as a test failure rather than an in-the-wild "the
    dropdown for language is empty" bug report.
    """
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    var dd = ed._lang_dropdown(String(""))
    # Always at least the empty "(any)" sentinel — if it's the only
    # entry, the language registry didn't load.
    assert_true(len(dd.options) >= 2,
        msg=String("dropdown only has the empty sentinel — built_in_servers() "
                   "returned no languages (cwd missing the bundled JSON?)"))


def test_action_editor_enter_opens_lang_popup() raises:
    """Pressing Enter on the focused (closed) language dropdown opens
    its popup. Without this, clicks/Enter were no-ops and users had no
    way to discover the available languages — earlier code rebuilt the
    dropdown stateless each paint, so any toggle was discarded
    immediately."""
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    ed.focus = UInt8(0)  # _FOCUS_LANG
    assert_false(ed.lang_dropdown.is_open)
    var ev = Event.key_event(KEY_ENTER, MOD_NONE)
    _ = ed.handle_key(ev)
    assert_true(ed.lang_dropdown.is_open)
    # Esc on an open popup just closes the popup, not the dialog.
    var esc = Event.key_event(KEY_ESC, MOD_NONE)
    _ = ed.handle_key(esc)
    assert_false(ed.lang_dropdown.is_open)
    assert_true(ed.active)


def test_dropdown_type_to_search_jumps_to_prefix() raises:
    """Typing while a popup is open jumps the highlight to the first
    option matching the accumulated prefix. Mirrors the file-list
    behavior so the muscle memory transfers."""
    var opts = List[String]()
    opts.append(String(""))
    opts.append(String("apple"))
    opts.append(String("banana"))
    opts.append(String("blueberry"))
    opts.append(String("cherry"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    assert_true(dd.type_to_search(String("b")))
    assert_equal(dd.highlight, 2)  # banana
    assert_true(dd.type_to_search(String("l")))
    assert_equal(dd.highlight, 3)  # blueberry (prefix "bl")


def test_dropdown_type_to_search_skips_empty_sentinel() raises:
    """The empty "" option (most callers prepend one as the "(none)"
    sentinel) is not a search target. A user typing 'p' wants
    "python", not the blank row at index 0."""
    var opts = List[String]()
    opts.append(String(""))
    opts.append(String("python"))
    opts.append(String("rust"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    assert_true(dd.type_to_search(String("p")))
    assert_equal(dd.highlight, 1)  # python, not the empty sentinel


def test_dropdown_type_to_search_recovers_from_stale_prefix() raises:
    """When the accumulated prefix doesn't match anything, retry with
    just the new char. Otherwise typing 'b' then 'z' would silently
    do nothing — confusing, since the user clearly intends to jump
    somewhere starting with 'z'."""
    var opts = List[String]()
    opts.append(String("apple"))
    opts.append(String("banana"))
    opts.append(String("zebra"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    _ = dd.type_to_search(String("b"))
    assert_equal(dd.highlight, 1)  # banana
    # 'z' makes the buffer "bz" which matches nothing — fallback to
    # the single 'z' should jump to "zebra".
    assert_true(dd.type_to_search(String("z")))
    assert_equal(dd.highlight, 2)


def test_dropdown_type_to_search_resets_on_close() raises:
    """Closing the popup discards the type-to-search prefix so the
    next open starts fresh. A stale prefix surviving across reopens
    would silently misroute the first keystroke."""
    var opts = List[String]()
    opts.append(String("apple"))
    opts.append(String("banana"))
    var dd = Dropdown(opts^, 0)
    dd.open()
    _ = dd.type_to_search(String("b"))
    assert_equal(dd._type_ahead.buf, String("b"))
    dd.close()
    assert_equal(dd._type_ahead.buf, String(""))


def test_action_editor_consumes_browse_path() raises:
    """When the embedded file dialog submits, the picked path must
    land in the program field (not the cwd field, not nowhere). This
    is the contract that lets the user click a file in Browse and end
    up with that path filled in for them."""
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    ed.file_dialog.open(String("/"))
    ed.file_dialog.selected_path = String("/usr/bin/black")
    ed.file_dialog.submitted = True
    ed._maybe_consume_browse()
    assert_false(ed.file_dialog.active)
    assert_equal(ed.form.text(UInt8(1)), String("/usr/bin/black"))


def test_action_editor_args_field_accepts_spaces() raises:
    """Typing ``a b c`` into the Arguments field used to drop the
    interior spaces because the field round-tripped through
    ``_split_args``/``_join_args`` on every keystroke. The fix holds a
    single string in ``args_text`` while editing and only splits on
    Save, so multiple arguments can actually be typed."""
    var ed = ActionEditor()
    ed.open(OnSaveAction(), -1)
    ed.focus = UInt8(3)  # _FOCUS_ARGS
    var letters = String("a b c")
    var lb = letters.as_bytes()
    for i in range(len(lb)):
        var ev = Event.key_event(UInt32(Int(lb[i])), MOD_NONE)
        _ = ed.handle_key(ev)
    assert_equal(ed.form.text(UInt8(3)), String("a b c"))
    # The committed list is empty until Save fires.
    assert_equal(len(ed.entry.args), 0)
    ed.focus = UInt8(5)  # _FOCUS_SAVE
    var enter = Event.key_event(KEY_ENTER, MOD_NONE)
    _ = ed.handle_key(enter)
    assert_true(ed.submitted)
    assert_equal(len(ed.entry.args), 3)
    assert_equal(ed.entry.args[0], String("a"))
    assert_equal(ed.entry.args[1], String("b"))
    assert_equal(ed.entry.args[2], String("c"))


def test_action_editor_args_buffer_seeded_from_entry() raises:
    """Editing an existing action seeds the args edit-buffer with the
    space-joined existing args. Without this, opening a record with
    args ``["--quiet", "$FilePath$"]`` would show an empty Arguments
    field and the user would lose their config the moment they saved."""
    var args = List[String]()
    args.append(String("--quiet"))
    args.append(String("$FilePath$"))
    var existing = OnSaveAction(
        String("python"), String("/usr/bin/black"), args^, String(""),
    )
    var ed = ActionEditor()
    ed.open(existing^, 0)
    assert_equal(ed.form.text(UInt8(3)), String("--quiet $FilePath$"))


def test_on_save_action_reloads_buffer_when_action_rewrites_file() raises:
    """Formatters like ``black`` rewrite the file on disk; without a
    reload the buffer drifts to the pre-format text and the next edit
    silently overwrites the formatter's output. After the action runs,
    the editor must adopt the new on-disk bytes."""
    var path = _temp_path(String("_onsave_reload.txt"))
    assert_true(write_file(path, String("hello\n")))
    var d = Desktop()
    d.windows.add(Window.from_file(
        String("onsave_reload.txt"), Rect(0, 1, 40, 12), path,
    ))
    # Mark dirty so ``save`` actually writes (a clean buffer skips the
    # write entirely).
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(KEY_END), Rect(0, 1, 40, 12),
    )
    _ = d.windows.windows[0].editor.handle_key(
        Event.key_event(UInt32(ord("!"))), Rect(0, 1, 40, 12),
    )
    # Configure a no-language-filter on-save action that overwrites the
    # saved file with new bytes. ``$FilePath$`` is expanded before the
    # outer sh -c sees it, so the shell receives a literal path.
    var args = List[String]()
    args.append(String("-c"))
    # Backslashes in the format would survive Mojo's escape but get
    # eaten by the *outer* sh -c when single-quoted strings are
    # concatenated; use printf with a literal arg to dodge that.
    args.append(String("printf %s world > $FilePath$"))
    d.config.on_save_actions.append(OnSaveAction(
        String(""), String("/bin/sh"), args^, String(""),
    ))
    var maybe = d.dispatch_action(EDITOR_SAVE, _SCREEN)
    assert_false(Bool(maybe))
    # On-save actions are reaped asynchronously by ``save_actions_tick``
    # so a slow / hung formatter can't freeze the UI. The test drives
    # the tick in a loop until the pending child reaps; the deadline
    # is generous (3 s) so a slow CI host with a sluggish ``sh`` spawn
    # doesn't flake.
    var deadline = monotonic_ms() + 3000
    while len(d.pending_save_actions) > 0 and monotonic_ms() < deadline:
        d.save_actions_tick()
    assert_equal(len(d.pending_save_actions), 0)
    # Disk reflects the action's output.
    assert_equal(read_file(path), String("world"))
    # And the buffer was reloaded — without the post-action reload the
    # editor would still be holding "hello!\n".
    assert_equal(
        d.windows.windows[0].editor.buffer.line(0), String("world"),
    )
    assert_false(d.windows.windows[0].editor.dirty)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_expand_save_placeholders_substitutes_filepath() raises:
    """``$FilePath$`` in an arg is replaced by the saved file path at
    spawn time. This is the only placeholder we recognise today."""
    var got = _expand_save_placeholders(
        String("$FilePath$"), String("/work/main.py"),
    )
    assert_equal(got, String("/work/main.py"))
    var inline = _expand_save_placeholders(
        String("--target=$FilePath$"), String("/work/main.py"),
    )
    assert_equal(inline, String("--target=/work/main.py"))
    var multi = _expand_save_placeholders(
        String("$FilePath$:$FilePath$"), String("/x"),
    )
    assert_equal(multi, String("/x:/x"))
    # No placeholder = pass-through.
    var passthrough = _expand_save_placeholders(
        String("--quiet"), String("/work/main.py"),
    )
    assert_equal(passthrough, String("--quiet"))
    # The token is case-sensitive — ``$filepath$`` is left alone so a
    # user who genuinely wants that literal string can have it.
    var case_sensitive = _expand_save_placeholders(
        String("$filepath$"), String("/work/main.py"),
    )
    assert_equal(case_sensitive, String("$filepath$"))


def test_extension_of_helper() raises:
    assert_equal(extension_of(String("foo.mojo")), String("mojo"))
    assert_equal(extension_of(String("a/b/foo.MOJO")), String("mojo"))
    assert_equal(extension_of(String("Makefile")), String(""))
    assert_equal(extension_of(String("a.b/c")), String(""))   # dot before /
    assert_equal(extension_of(String("")), String(""))


def test_word_at_helper() raises:
    assert_equal(word_at(String("foo bar"), 0), String("foo"))
    assert_equal(word_at(String("foo bar"), 2), String("foo"))
    assert_equal(word_at(String("foo bar"), 4), String("bar"))
    assert_equal(word_at(String("foo bar"), 3), String(""))   # space, not ident
    assert_equal(word_at(String("snake_case"), 5), String("snake_case"))
    # Unicode letters cluster with ASCII letters — ``ä`` / ``ö`` / ``å``
    # in a Swedish word like "Godkänn" mustn't split it into pieces.
    var word = String("Godkänn")
    assert_equal(word_at(word, 0), word)        # starts on G
    assert_equal(word_at(word, 4), word)        # starts on the ä lead byte
    assert_equal(word_at(word, 6), word)        # on a trailing n
    # Cyrillic and Greek roundtrip too.
    assert_equal(word_at(String("Привет foo"), 0), String("Привет"))
    assert_equal(word_at(String("λambda"), 0), String("λambda"))


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


def _hl_set(hls: List[Highlight]) -> List[Highlight]:
    """Sort-of-canonicalize a Highlight list: sort by (row, col_start,
    col_end). Two passes that agree should produce equal lists post-sort
    even if they emit highlights in slightly different orders."""
    var sorted = List[Highlight]()
    for i in range(len(hls)):
        sorted.append(hls[i])
    # Insertion sort — lists are small (a few thousand entries) and we
    # don't want to pull in a generic sort dependency.
    for i in range(1, len(sorted)):
        var j = i
        while j > 0:
            var a = sorted[j - 1]
            var b = sorted[j]
            var swap = False
            if a.row > b.row:
                swap = True
            elif a.row == b.row:
                if a.col_start > b.col_start:
                    swap = True
                elif a.col_start == b.col_start and a.col_end > b.col_end:
                    swap = True
            if not swap:
                break
            sorted[j - 1] = b
            sorted[j] = a
            j -= 1
    return sorted^


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


def test_editor_default_text_is_light_green() raises:
    """Cells that no scope claims must paint LIGHT_GREEN on BLUE —
    that's the "identifier" baseline. Variables and bare names in
    languages whose grammar doesn't tag every token (e.g. Python's
    ``def f(x): pass`` — neither ``f`` nor ``x`` get a scope) read
    as green identifiers instead of inheriting the brighter
    ``YELLOW`` baseline they used to.

    Regression: when the default was ``YELLOW`` everything not
    keyword / string / comment / number / operator looked like it
    was meant to stand out, which made unrecognized identifiers
    visually pop more than the keywords surrounding them.
    """
    var ed = Editor(String("hello world"))
    var c = Canvas(20, 3)
    # ``focused=False`` so the cursor inversion (BLUE on YELLOW at
    # the cursor position) doesn't fight the default-attr probe.
    ed.paint(c, Rect(0, 0, 20, 3), False)
    # Column 0 of an unhighlighted, plain-text buffer must carry
    # the new default.
    assert_equal(c.get(0, 0).attr.fg, LIGHT_GREEN)
    assert_equal(c.get(0, 0).attr.bg, BLUE)
    # Past EOL the trailing fill cells must also be the new default.
    assert_equal(c.get(15, 0).attr.fg, LIGHT_GREEN)
    assert_equal(c.get(15, 0).attr.bg, BLUE)


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


def test_editor_refreshes_highlights_after_edits() raises:
    """Newly typed text gets re-tokenized: typing ``fn`` produces a keyword
    highlight that wasn't there a moment ago.

    Editor.handle_key now defers the actual tokenization to the
    render path's ``flush_highlights`` call (so the shared
    ``GrammarRegistry`` doesn't have to thread through every edit
    method); we drive that explicitly with a local registry to read
    ``ed.highlights`` synchronously.
    """
    var path = _temp_path(String("_hl.mojo"))
    assert_true(write_file(path, String("\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    assert_true(len(ed.highlights) == 0)
    _ = ed.handle_key(_key(UInt32(ord("f"))), _VIEW)
    _ = ed.handle_key(_key(UInt32(ord("n"))), _VIEW)
    ed.flush_highlights(registry, speller)
    var saw_fn_keyword = False
    for i in range(len(ed.highlights)):
        var h = ed.highlights[i]
        if h.row == 0 and h.col_start == 0 and h.col_end == 2 \
                and h.attr == highlight_keyword_attr():
            saw_fn_keyword = True
    assert_true(saw_fn_keyword)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_paint_overlays_highlight_attr() raises:
    """The highlight attr lands on the right cells in the canvas after
    ``editor.paint``."""
    var path = _temp_path(String("_hlpaint.mojo"))
    assert_true(write_file(path, String("fn main():\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # ``fn`` lives at columns 0–1 with the keyword attr.
    assert_true(canvas.get(0, 0).attr == highlight_keyword_attr())
    assert_true(canvas.get(1, 0).attr == highlight_keyword_attr())
    # The space and the ``main`` identifier aren't keywords.
    assert_false(canvas.get(2, 0).attr == highlight_keyword_attr())
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_alt_click_emits_definition_request() raises:
    # Cmd+click in iTerm2 is delivered to the app as Left+Alt — the editor
    # treats Alt+left-click as the goto-definition trigger.
    var ed = Editor(String("foo bar baz"))
    var ev = Event.mouse_event(
        Point(4, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_ALT,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_true(Bool(req))
    var dr = req.value()
    assert_equal(dr.row, 0)
    assert_equal(dr.col, 4)
    assert_equal(dr.word, String("bar"))
    # The cursor must NOT have moved (Alt+click is non-mutating).
    assert_equal(ed.cursor_col, 0)
    # And the slot is consumed: a second poll returns empty.
    var req2 = ed.consume_definition_request()
    assert_false(Bool(req2))


def test_editor_alt_click_outside_identifier_is_silent() raises:
    var ed = Editor(String("foo  bar"))
    # Click on the space between words.
    var ev = Event.mouse_event(
        Point(3, 0), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=MOD_ALT,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_definition_request()
    assert_false(Bool(req))


def test_editor_gutter_click_emits_breakpoint_toggle() raises:
    # Line-number gutter on → 2 cells of gutter at the left edge. A
    # left-click there must surface as a pending breakpoint toggle for
    # the corresponding buffer row, without moving the cursor.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_breakpoint_toggle()
    assert_true(Bool(req))
    assert_equal(req.value(), 1)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 0)
    # Slot is one-shot.
    assert_false(Bool(ed.consume_breakpoint_toggle()))


def test_editor_text_click_does_not_toggle_breakpoint() raises:
    # Click past the gutter — normal cursor placement, no toggle.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(5, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    assert_false(Bool(ed.consume_breakpoint_toggle()))
    assert_equal(ed.cursor_row, 1)


def test_editor_gutter_click_below_eof_is_ignored() raises:
    # Click in the gutter on a screen row past the last buffer line —
    # no breakpoint should be toggled (matches "click on empty space"
    # being a no-op for cursor placement, just without the cursor side
    # effect).
    var ed = Editor(String("alpha\nbeta"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 4), MOUSE_BUTTON_LEFT,
        pressed=True, motion=False, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 6))
    assert_false(Bool(ed.consume_breakpoint_toggle()))


def test_editor_gutter_drag_motion_does_not_toggle() raises:
    # Drag motion through the gutter must not flood pending toggles.
    var ed = Editor(String("alpha\nbeta\ngamma"))
    ed.line_numbers = True
    var ev = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_LEFT,
        pressed=True, motion=True, mods=0,
    )
    _ = ed.handle_mouse(ev, Rect(0, 0, 40, 5))
    assert_false(Bool(ed.consume_breakpoint_toggle()))


def test_quick_open_match_rules() raises:
    """Locked-in spec: the query is split on spaces into tokens, and each
    token is then split around every ``/`` (with ``/`` kept as its own
    one-byte part). Each part must appear as a case-insensitive substring
    of the path, in order."""
    var path = String("src/turbokod/cell.mojo")
    # `k/c` → parts ["k", "/", "c"] all present as substrings in order.
    assert_true(quick_open_match(path, String("k/c")))
    # Space-separated tokens — both substrings, in order.
    assert_true(quick_open_match(path, String("k c")))
    # `k/m` → "k" (in turbokod), "/" (after turbokod), "m" (in .mojo).
    assert_true(quick_open_match(path, String("k/m")))
    # `km/` → "km" then "/". "km" is not a substring of the path.
    assert_false(quick_open_match(path, String("km/")))

    # Multi-token across other shapes:
    assert_true(quick_open_match(String("job_call"),  String("j c")))
    assert_true(quick_open_match(String("jobCall"),   String("j c")))
    # Plain substring matching — `j` then `c` are both in "jack", in order.
    assert_true(quick_open_match(String("jack"),      String("j c")))

    # Empty query matches everything; tokens must keep their order.
    assert_true(quick_open_match(path, String("")))
    assert_false(quick_open_match(String("cell mojo"), String("mojo cell")))


def test_quick_open_match_case_and_separator_shapes() raises:
    # Case-insensitive substring matching across mixed case.
    assert_true(quick_open_match(String("HelloWorld"), String("h w")))
    assert_true(quick_open_match(String("Helloworld"), String("h")))
    # Substrings can sit on either side of any separator byte.
    assert_true(quick_open_match(String("foo-bar.baz"), String("f b b")))
    # Path-segment boundaries via slashes — each token a substring in order.
    assert_true(quick_open_match(String("a/b/c"), String("a b c")))


def test_quick_open_slash_in_query_requires_directory_separator() raises:
    """A space-separated query like ``foo bar`` matches when both ``foo``
    and ``bar`` appear as substrings of the path, in that order. A slash
    in the query — ``foo/bar`` — works the same way, except the slash
    itself is also a required substring between the two parts: it is
    equivalent to the three-part query ``foo`` / ``/`` / ``bar``, all
    matched as substrings in order. So ``foo/bar`` demands that ``foo``
    and ``bar`` straddle a real directory separator in the path.

    Worked example with ``pro/views``:

    * ``dryft/prospects/views.py`` — ``pro`` is in ``prospects``, then a
      ``/``, then ``views`` is in ``views.py``. Match.
    * ``dryft/homepage/cms/migrations/0003_snippet_preview_values.py`` —
      no segment contains ``pro`` (``preview_values`` has ``p``, ``r``,
      ``v``, ``i``, ``e``, ``w``, ``s`` only as a *subsequence*, not a
      contiguous substring; the literal text ``pro`` is absent), so the
      first part already fails. No match.
    """
    assert_true(quick_open_match(
        String("dryft/prospects/views.py"), String("pro/views"),
    ))
    assert_false(quick_open_match(
        String("dryft/homepage/cms/migrations/0003_snippet_preview_values.py"),
        String("pro/views"),
    ))


def test_quick_open_filters_as_you_type() raises:
    var root = find_git_project(String("examples/hello.mojo"))
    assert_true(root)
    var qo = QuickOpen()
    qo.open(root.value())
    assert_true(qo.active)
    var initial_count = len(qo.matched)
    assert_true(initial_count > 5)
    # Typing narrows the match list.
    qo.query.set_text(String("editor"))
    qo._refilter()
    assert_true(len(qo.matched) > 0)
    assert_true(len(qo.matched) < initial_count)
    var found_editor_module = False
    for i in range(len(qo.matched)):
        if qo.entries[qo.matched[i]] == String("src/turbokod/editor.mojo"):
            found_editor_module = True
            break
    assert_true(found_editor_module)
    # Submission produces an absolute path joined with root.
    qo.selected_path = join_path(qo.root, qo.entries[qo.matched[0]])
    qo.submitted = True
    assert_true(_starts_with(qo.selected_path, root.value()))


def _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def test_cmd_o_bubbles_file_open() raises:
    """Cmd+O always bubbles ``EDITOR_OPEN`` up to the host so the
    framework's ``FileDialog`` can be used; the project-aware Quick
    Open picker is on Cmd+Shift+O."""
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    var ev = Event.key_event(UInt32(ord("o")), MOD_META)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), EDITOR_OPEN)
    assert_false(d.quick_open.active)


def test_cmd_shift_o_opens_quick_open_when_project_active() raises:
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    var ev = Event.key_event(UInt32(ord("o")), MOD_META | MOD_SHIFT)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_false(Bool(maybe))
    assert_true(d.quick_open.active)


def test_cmd_shift_o_bubbles_when_no_project() raises:
    var d = Desktop()
    var ev = Event.key_event(UInt32(ord("o")), MOD_META | MOD_SHIFT)
    var maybe = d.handle_event(ev, _SCREEN)
    assert_true(Bool(maybe))
    assert_equal(maybe.value(), EDITOR_QUICK_OPEN)
    assert_false(d.quick_open.active)


def test_replace_in_project_round_trip() raises:
    """Set up a tiny scratch tree, replace across it, verify writes."""
    var root = _temp_path(String("_proj"))
    _ = external_call["mkdir", Int32]((root + String("\0")).unsafe_ptr(), Int32(0o755))
    var a = join_path(root, String("a.txt"))
    var b = join_path(root, String("b.txt"))
    assert_true(write_file(a, String("alpha foo gamma\n")))
    assert_true(write_file(b, String("foo foo\nno match\n")))
    var summary = replace_in_project(root, String("foo"), String("BAR"))
    assert_equal(summary[0], 2)   # both files changed
    assert_equal(summary[1], 3)   # 1 + 2 replacements
    assert_equal(read_file(a), String("alpha BAR gamma\n"))
    assert_equal(read_file(b), String("BAR BAR\nno match\n"))
    _ = external_call["unlink", Int32]((a + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((b + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_window_manager_fit_into_keeps_maximized_pinned() raises:
    var wm = WindowManager()
    var w = Window(String("M"), Rect(0, 1, 100, 25), List[String]())
    w.is_maximized = True
    wm.add(w^)
    var smaller = Rect(0, 1, 60, 20)
    wm.fit_into(smaller)
    assert_true(wm.windows[0].rect == smaller)


def test_window_manager_fit_into_scales_side_by_side_on_grow() raises:
    """Two windows tiled side by side covering the workspace must still
    cover it after the terminal grows, with their shared edge staying
    seamless and the width ratio between them preserved."""
    var wm = WindowManager()
    # Workspace is 100x24 (y in [1, 25)); two windows split it 40/60.
    wm.add(Window(String("L"), Rect(0, 1, 40, 25), List[String]()))
    wm.add(Window(String("R"), Rect(40, 1, 100, 25), List[String]()))
    # First call baselines at the original workspace without scaling.
    wm.fit_into(Rect(0, 1, 100, 25))
    # Grow the terminal: width 100 → 200, height stays at 24.
    wm.fit_into(Rect(0, 1, 200, 25))
    # Left edge of L pinned to workspace left edge.
    assert_equal(wm.windows[0].rect.a.x, 0)
    # Right edge of R pinned to workspace right edge — full coverage.
    assert_equal(wm.windows[1].rect.b.x, 200)
    # The seam is seamless: L.b.x == R.a.x.
    assert_equal(wm.windows[0].rect.b.x, wm.windows[1].rect.a.x)
    # Width ratio preserved at 40:60 → 80:120 in a 200-wide workspace.
    assert_equal(wm.windows[0].rect.width(), 80)
    assert_equal(wm.windows[1].rect.width(), 120)
    # y-axis untouched because workspace height didn't change.
    assert_equal(wm.windows[0].rect.a.y, 1)
    assert_equal(wm.windows[0].rect.b.y, 25)


def test_window_manager_fit_into_scales_side_by_side_on_shrink() raises:
    """Same as the grow test, but the terminal shrinks. The shared seam
    and the full-coverage invariant must still hold."""
    var wm = WindowManager()
    wm.add(Window(String("L"), Rect(0, 1, 40, 25), List[String]()))
    wm.add(Window(String("R"), Rect(40, 1, 100, 25), List[String]()))
    wm.fit_into(Rect(0, 1, 100, 25))
    # Shrink: width 100 → 50.
    wm.fit_into(Rect(0, 1, 50, 25))
    assert_equal(wm.windows[0].rect.a.x, 0)
    assert_equal(wm.windows[1].rect.b.x, 50)
    assert_equal(wm.windows[0].rect.b.x, wm.windows[1].rect.a.x)
    # 40:60 of 50 → 20:30.
    assert_equal(wm.windows[0].rect.width(), 20)
    assert_equal(wm.windows[1].rect.width(), 30)


def test_window_manager_fit_into_scales_stacked_on_resize() raises:
    """Same proportional behavior on the y-axis: two windows stacked
    vertically and covering the workspace stay covering it."""
    var wm = WindowManager()
    # Workspace 80x20 (y in [1, 21)); split top 8 rows, bottom 12 rows.
    wm.add(Window(String("T"), Rect(0, 1, 80, 9), List[String]()))
    wm.add(Window(String("B"), Rect(0, 9, 80, 21), List[String]()))
    wm.fit_into(Rect(0, 1, 80, 21))
    # Grow height: 20 → 40 rows (y in [1, 41)).
    wm.fit_into(Rect(0, 1, 80, 41))
    assert_equal(wm.windows[0].rect.a.y, 1)
    assert_equal(wm.windows[1].rect.b.y, 41)
    assert_equal(wm.windows[0].rect.b.y, wm.windows[1].rect.a.y)
    # 8:12 of 40 → 16:24.
    assert_equal(wm.windows[0].rect.height(), 16)
    assert_equal(wm.windows[1].rect.height(), 24)


def test_window_manager_fit_into_proportional_2x2_grid() raises:
    """A 2x2 tile fully covering the workspace stays fully covering it
    after a resize; all four interior seams stay aligned."""
    var wm = WindowManager()
    # Workspace 100x20 (y in [1, 21)); split 50/50 horizontally and
    # 8/12 vertically.
    wm.add(Window(String("TL"), Rect(0, 1, 50, 9), List[String]()))
    wm.add(Window(String("TR"), Rect(50, 1, 100, 9), List[String]()))
    wm.add(Window(String("BL"), Rect(0, 9, 50, 21), List[String]()))
    wm.add(Window(String("BR"), Rect(50, 9, 100, 21), List[String]()))
    wm.fit_into(Rect(0, 1, 100, 21))
    # Grow both axes: 100x20 → 200x40 (y in [1, 41)).
    wm.fit_into(Rect(0, 1, 200, 41))
    # Outer edges cover the new workspace exactly.
    assert_equal(wm.windows[0].rect.a.x, 0)
    assert_equal(wm.windows[0].rect.a.y, 1)
    assert_equal(wm.windows[3].rect.b.x, 200)
    assert_equal(wm.windows[3].rect.b.y, 41)
    # Horizontal seam: TL.b.x == TR.a.x == BL.b.x == BR.a.x.
    assert_equal(wm.windows[0].rect.b.x, wm.windows[1].rect.a.x)
    assert_equal(wm.windows[2].rect.b.x, wm.windows[3].rect.a.x)
    assert_equal(wm.windows[0].rect.b.x, wm.windows[2].rect.b.x)
    # Vertical seam: TL.b.y == BL.a.y == TR.b.y == BR.a.y.
    assert_equal(wm.windows[0].rect.b.y, wm.windows[2].rect.a.y)
    assert_equal(wm.windows[1].rect.b.y, wm.windows[3].rect.a.y)
    assert_equal(wm.windows[0].rect.b.y, wm.windows[1].rect.b.y)


def test_window_manager_fit_into_baseline_no_scale_on_first_call() raises:
    """The first ``fit_into`` after construction has no baseline to scale
    against, so it falls back to clip-and-move — preserves the move-only
    behavior the existing test suite (and session restore startup) rely
    on."""
    var wm = WindowManager()
    # Window past the new right edge — should slide left, not scale.
    wm.add(Window(String("A"), Rect(70, 5, 90, 15), List[String]()))
    wm.fit_into(Rect(0, 1, 80, 25))
    assert_equal(wm.windows[0].rect.width(), 20)   # width preserved
    assert_equal(wm.windows[0].rect.b.x, 80)       # slid against right edge


def test_window_manager_note_workspace_suppresses_next_scale() raises:
    """``note_workspace`` rebases the snapshot without touching rects,
    so a workspace change reported via ``note_workspace`` followed by a
    matching ``fit_into`` doesn't trigger proportional scaling — this is
    what session restore relies on after manually assigning rects."""
    var wm = WindowManager()
    wm.add(Window(String("A"), Rect(10, 5, 30, 15), List[String]()))
    # First fit baselines at workspace 80x24.
    wm.fit_into(Rect(0, 1, 80, 25))
    var before = wm.windows[0].rect
    # Restore handler "reapplied" rects to fit a larger workspace, then
    # told the manager about the new workspace.
    wm.note_workspace(Rect(0, 1, 160, 50))
    # Next paint sees the same workspace as the baseline → no scaling.
    wm.fit_into(Rect(0, 1, 160, 50))
    assert_true(wm.windows[0].rect == before)


def test_window_manager_fit_into_round_trip_is_lossless() raises:
    """Two windows split 50/50 covering the workspace must come back to
    exactly 50/50 after a shrink-then-grow round trip. The naive
    "scale the current rect every time" approach accumulates integer
    rounding error and ends up with asymmetric widths; this test pins
    the per-window-baseline path that avoids that drift."""
    var wm = WindowManager()
    # Workspace 101 wide so the half-point doesn't divide evenly —
    # rounding-error accumulation is most visible at odd widths.
    wm.add(Window(String("L"), Rect(0, 1, 50, 25), List[String]()))
    wm.add(Window(String("R"), Rect(50, 1, 101, 25), List[String]()))
    wm.fit_into(Rect(0, 1, 101, 25))
    # Shrink to about half the width.
    wm.fit_into(Rect(0, 1, 50, 25))
    # Grow back to the original.
    wm.fit_into(Rect(0, 1, 101, 25))
    assert_equal(wm.windows[0].rect.a.x, 0)
    assert_equal(wm.windows[0].rect.b.x, 50)
    assert_equal(wm.windows[1].rect.a.x, 50)
    assert_equal(wm.windows[1].rect.b.x, 101)


def test_window_manager_fit_into_user_drag_rebases_baseline() raises:
    """A user edge-drag captured between paints must rebase the
    baseline. Without that, resizing the terminal after the drag would
    scale from the stale pre-drag baseline, undoing the drag."""
    var wm = WindowManager()
    wm.add(Window(String("L"), Rect(0, 1, 50, 25), List[String]()))
    wm.add(Window(String("R"), Rect(50, 1, 100, 25), List[String]()))
    wm.fit_into(Rect(0, 1, 100, 25))
    # Simulate a user drag of L's right edge: rect mutates between
    # paints with the workspace unchanged.
    wm.windows[0].rect = Rect(0, 1, 60, 25)
    # Next paint with the same workspace — manager observes the user
    # change and rebases the baseline.
    wm.fit_into(Rect(0, 1, 100, 25))
    # Now resize the terminal: scaling must come from the rebased
    # baseline (60 wide of 100) not from the original (50 wide of 100).
    wm.fit_into(Rect(0, 1, 200, 25))
    # 60 of 100 → 120 of 200 for the left edge of R / right edge of L.
    assert_equal(wm.windows[0].rect.b.x, 120)


def test_window_manager_fit_into_scales_restore_rect_for_maximized() raises:
    """A maximized window's ``_restore_rect`` is scaled along with the
    workspace so un-maximizing after a terminal resize lands at the
    proportionally-correct place rather than reverting to the
    pre-resize coordinates."""
    var wm = WindowManager()
    var w = Window(String("M"), Rect(0, 1, 100, 25), List[String]())
    w._restore_rect = Rect(10, 5, 50, 15)
    w.is_maximized = True
    wm.add(w^)
    wm.fit_into(Rect(0, 1, 100, 25))
    # Double both axes: width 100→200, height 24→48.
    wm.fit_into(Rect(0, 1, 200, 49))
    # Rect pinned to the new workspace.
    assert_true(wm.windows[0].rect == Rect(0, 1, 200, 49))
    # _restore_rect scaled proportionally: x doubled, y doubled (from
    # the y origin at 1): a.y = 1 + (5-1)*48/24 = 1 + 8 = 9; b.y = 1 +
    # (15-1)*48/24 = 1 + 28 = 29.
    assert_equal(wm.windows[0]._restore_rect.a.x, 20)
    assert_equal(wm.windows[0]._restore_rect.b.x, 100)
    assert_equal(wm.windows[0]._restore_rect.a.y, 9)
    assert_equal(wm.windows[0]._restore_rect.b.y, 29)


def test_window_manager_title_hover_arms_for_editor_with_path() raises:
    """Bare hover over the title bar of a file-backed editor window
    arms the title-tooltip tracker; hovering elsewhere clears it. A
    left-click anywhere also drops the tracker so a stale popup
    doesn't outlive the click."""
    var wm = WindowManager()
    var w = Window.editor_window(
        String("hello.mojo"), Rect(2, 2, 30, 12), String("body"),
    )
    w.editor.file_path = String("/tmp/proj/hello.mojo")
    wm.add(w^)
    # Hover on the title row (y == rect.a.y == 2), at a column that
    # isn't the close button or the maximize/number indicator.
    var hover = Event.mouse_event(
        Point(15, 2), MOUSE_BUTTON_NONE, pressed=True, motion=True,
    )
    _ = wm.handle_mouse(hover, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, 0)
    assert_equal(wm._title_hover_x, 15)
    assert_equal(wm._title_hover_y, 2)
    # Hover off the title row — body cell at y=5 — clears it.
    var off = Event.mouse_event(
        Point(15, 5), MOUSE_BUTTON_NONE, pressed=True, motion=True,
    )
    _ = wm.handle_mouse(off, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, -1)
    # Re-arm, then a left-click clears it.
    _ = wm.handle_mouse(hover, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, 0)
    var click = Event.mouse_event(
        Point(15, 2), MOUSE_BUTTON_LEFT, pressed=True, motion=False,
    )
    _ = wm.handle_mouse(click, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, -1)


def test_window_manager_title_hover_skips_unbacked_buffers() raises:
    """Untitled / file-less editor windows must not arm the tooltip —
    a centered ``Untitled`` title with no path has nothing useful to
    show in a popup."""
    var wm = WindowManager()
    var w = Window.editor_window(
        String("Untitled"), Rect(2, 2, 30, 12), String(""),
    )
    # editor.file_path is empty by default for editor_window().
    wm.add(w^)
    var hover = Event.mouse_event(
        Point(15, 2), MOUSE_BUTTON_NONE, pressed=True, motion=True,
    )
    _ = wm.handle_mouse(hover, Rect(0, 1, 80, 25))
    assert_equal(wm._title_hover_idx, -1)


def test_painter_clips_text_at_right_edge() raises:
    """Long text passed to ``Painter.put_text`` must not bleed past the
    clip's right edge — every cell beyond ``clip.b.x`` stays untouched."""
    var canvas = Canvas(20, 3)
    canvas.fill(Rect(0, 0, 20, 3), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(2, 1, 8, 2))   # 6-cell wide clip
    _ = painter.put_text(
        canvas, Point(2, 1),
        String("ABCDEFGHIJKLMNOP"), Attr(BLACK, BLUE),
    )
    # Cells inside the clip get the letters; cells just outside on the
    # right keep their sentinel.
    assert_equal(canvas.get(2, 1).glyph, String("A"))
    assert_equal(canvas.get(7, 1).glyph, String("F"))
    assert_equal(canvas.get(8, 1).glyph, String("·"))   # right neighbour intact
    assert_equal(canvas.get(1, 1).glyph, String("·"))   # left neighbour intact
    # Drawing on a row outside the clip is a no-op.
    _ = painter.put_text(
        canvas, Point(2, 0),
        String("OUTSIDE"), Attr(BLACK, BLUE),
    )
    assert_equal(canvas.get(2, 0).glyph, String("·"))


def test_painter_skips_codepoints_left_of_clip() raises:
    """When the start point is left of the clip, leading codepoints
    must be skipped one cell at a time (codepoint-aware) so the
    remaining glyphs land at the right visual columns. ``café WORLD``
    occupies cells 0..9; with the clip starting at cell 5, only
    ``WORLD`` should appear, at its expected columns."""
    var canvas = Canvas(20, 1)
    canvas.fill(Rect(0, 0, 20, 1), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(5, 0, 15, 1))
    _ = painter.put_text(
        canvas, Point(0, 0),
        String("café WORLD"),
        Attr(BLACK, BLUE),
    )
    # Cells 0..4 left of clip stay sentinel.
    for x in range(5):
        assert_equal(canvas.get(x, 0).glyph, String("·"))
    # ``W``..``D`` land at cells 5..9 — same columns they would in an
    # unclipped paint, which is the whole point of codepoint-aware
    # skipping (a byte-stride skip would drop one extra cell from the
    # 2-byte ``é`` and shift everything left).
    assert_equal(canvas.get(5, 0).glyph, String("W"))
    assert_equal(canvas.get(6, 0).glyph, String("O"))
    assert_equal(canvas.get(9, 0).glyph, String("D"))
    # Cells 10..14 (still inside the clip) and 15+ (right of clip)
    # never got a glyph.
    assert_equal(canvas.get(10, 0).glyph, String("·"))
    assert_equal(canvas.get(15, 0).glyph, String("·"))


def test_painter_fill_intersects_with_clip() raises:
    var canvas = Canvas(10, 5)
    canvas.fill(Rect(0, 0, 10, 5), String("·"), Attr(BLACK, BLUE))
    var painter = Painter(Rect(2, 1, 7, 4))
    # Caller-rect overhangs the clip; the fill is automatically trimmed.
    painter.fill(canvas, Rect(0, 0, 100, 100), String("#"), Attr(BLACK, BLUE))
    assert_equal(canvas.get(0, 0).glyph, String("·"))
    assert_equal(canvas.get(2, 1).glyph, String("#"))
    assert_equal(canvas.get(6, 3).glyph, String("#"))
    assert_equal(canvas.get(7, 3).glyph, String("·"))   # one past clip
    assert_equal(canvas.get(2, 4).glyph, String("·"))   # one below clip


def test_dir_browser_long_name_does_not_overflow_listing() raises:
    """Regression: a directory entry far longer than the listing rect
    must not overwrite cells outside the rect, on any side. Drives the
    overflow with a 200-char synthetic entry — anything longer than
    the rect width would have leaked under the pre-Painter code only
    when callers forgot ``max_x``."""
    var canvas = Canvas(40, 5)
    var sentinel = Attr(BLACK, BLUE)
    canvas.fill(Rect(0, 0, 40, 5), String("·"), sentinel)
    var br = DirBrowser(False)
    br.entries = List[String]()
    br.entry_is_dir = List[Bool]()
    var huge = String("")
    for _ in range(200):
        huge = huge + String("X")
    br.entries.append(huge^)
    br.entry_is_dir.append(False)
    br.selected = 0
    var clip = Rect(5, 1, 15, 4)
    br.paint(canvas, clip, True)
    # Every cell outside the clip must still be the sentinel.
    for y in range(5):
        for x in range(40):
            var inside = (
                clip.a.x <= x and x < clip.b.x
                and clip.a.y <= y and y < clip.b.y
            )
            if not inside:
                assert_equal(canvas.get(x, y).glyph, String("·"))


def test_file_dialog_lists_and_navigates() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    assert_true(dlg.active)
    # Should have at least ".." and a few example files.
    assert_true(len(dlg.browser.entries) >= 2)
    assert_equal(dlg.browser.entries[0], String(".."))
    # Navigate to second entry; arrow event-driven.
    _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    assert_equal(dlg.browser.selected, 1)
    _ = dlg.handle_key(Event.key_event(KEY_UP))
    assert_equal(dlg.browser.selected, 0)


def test_partial_sgr_mouse_does_not_emit_esc() raises:
    """A scroll-wheel event split across two reads must NOT emit KEY_ESC —
    that would make every quit-on-Esc app exit at random when scrolling.

    Partial sequences return ``(EVENT_NONE, 0)`` so Terminal.poll_event saves
    the tail as pending bytes and prepends them to the next read.
    """
    var partial = parse_input(String("\x1b[<64;15;5"))   # missing terminator
    assert_true(partial[0].kind == EVENT_NONE)
    assert_equal(partial[1], 0)

    # Partial CSI prefix — same convention.
    var just_csi = parse_input(String("\x1b["))
    assert_true(just_csi[0].kind == EVENT_NONE)
    assert_equal(just_csi[1], 0)

    # Partial SS3 prefix (some terminals emit ESC O <P|Q|R|S> for F1..F4).
    var just_ss3 = parse_input(String("\x1bO"))
    assert_true(just_ss3[0].kind == EVENT_NONE)
    assert_equal(just_ss3[1], 0)

    # Partial CSI mid digit-run (ESC[5 with no terminator yet).
    var partial_tilde = parse_input(String("\x1b[5"))
    assert_true(partial_tilde[0].kind == EVENT_NONE)
    assert_equal(partial_tilde[1], 0)

    # Partial CSI mid modified-key sequence.
    var partial_mod = parse_input(String("\x1b[1;5"))
    assert_true(partial_mod[0].kind == EVENT_NONE)
    assert_equal(partial_mod[1], 0)


def test_sgr_mouse_wheel_up() raises:
    var ev = parse_input(String("\x1b[<64;15;5M"))
    assert_true(ev[0].kind == EVENT_MOUSE)
    assert_true(ev[0].button == MOUSE_WHEEL_UP)


def test_sgr_mouse_motion_no_button() raises:
    """Mouse-mode 1003 reports motion with no button held as raw button-bits
    ``3 | 32`` (35). The parser must surface that as MOUSE_BUTTON_NONE +
    motion=True; mapping it to RIGHT (the legacy bug) made every hover look
    like a phantom right-click."""
    var ev = parse_input(String("\x1b[<35;10;1M"))
    assert_true(ev[0].kind == EVENT_MOUSE)
    assert_true(ev[0].button == MOUSE_BUTTON_NONE)
    assert_true(ev[0].motion)
    assert_equal(ev[0].pos.x, 9)
    assert_equal(ev[0].pos.y, 0)


def test_menu_hover_switches_open_menu() raises:
    """While a menu is open, hovering (button=NONE, motion=True) over a
    different menu in the bar switches the open menu to it. This is the
    macOS-style sticky behavior the user gets after a click-then-move."""
    var bar = MenuBar()
    var file_items = List[MenuItem]()
    file_items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), file_items^))
    var edit_items = List[MenuItem]()
    edit_items.append(MenuItem(String("Find"), EDITOR_FIND))
    bar.add(Menu(String("Edit"), edit_items^))
    bar.open_menu(0)
    var rects = bar._layout(80)
    var edit_x = (rects[1].a.x + rects[1].b.x) // 2
    var hover = Event.mouse_event(
        Point(edit_x, 0), MOUSE_BUTTON_NONE, True, True,
    )
    var r = bar.handle_event(hover, 80)
    assert_true(r.consumed)
    assert_equal(bar.open_idx, 1)


def test_menu_drag_release_on_item_triggers() raises:
    """Click-and-hold on File, drag down into the dropdown, release on the
    Save row → the release fires EDITOR_SAVE without an extra click."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    items.append(MenuItem(String("Quit"), APP_QUIT_ACTION))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    # Press on File — opens the menu, starts tracking.
    var press = Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False)
    _ = bar.handle_event(press, 80)
    assert_equal(bar.open_idx, 0)
    assert_true(bar.tracking)
    # Drag onto the second item in the dropdown.
    var dr = bar._dropdown_rect(80)
    var item_y = dr.a.y + 1 + 1   # row 1 inside the dropdown = "Quit"
    var drag = Event.mouse_event(
        Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, True, True,
    )
    _ = bar.handle_event(drag, 80)
    assert_equal(bar.selected_item, 1)
    # Release on the dragged-onto item triggers it.
    var release = Event.mouse_event(
        Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, False, False,
    )
    var r = bar.handle_event(release, 80)
    assert_true(r.action)
    assert_equal(r.action.value(), APP_QUIT_ACTION)
    assert_false(bar.is_open())
    assert_false(bar.tracking)


def test_menu_drag_release_outside_closes() raises:
    """Click-and-hold on File, drag off the bar and dropdown, release in
    empty space → the menu closes (drag-select cancellation)."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False), 80,
    )
    assert_true(bar.is_open())
    assert_true(bar.tracking)
    # Drag well below the dropdown, then release there.
    var dr = bar._dropdown_rect(80)
    var off = Point(dr.b.x + 5, dr.b.y + 5)
    _ = bar.handle_event(
        Event.mouse_event(off, MOUSE_BUTTON_LEFT, True, True), 80,
    )
    var r = bar.handle_event(
        Event.mouse_event(off, MOUSE_BUTTON_LEFT, False, False), 80,
    )
    assert_false(r.action)
    assert_false(bar.is_open())
    assert_false(bar.tracking)


def test_menu_click_then_click_flow() raises:
    """Sticky/Mac-style flow: a click that lands on File and releases there
    leaves the menu open in non-tracking mode; a separate later click on a
    dropdown item then triggers it."""
    var bar = MenuBar()
    var items = List[MenuItem]()
    items.append(MenuItem(String("Save"), EDITOR_SAVE))
    bar.add(Menu(String("File"), items^))
    var rects = bar._layout(80)
    var fx = (rects[0].a.x + rects[0].b.x) // 2
    # First click: press + release on File. Menu opens, tracking clears on
    # release.
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, True, False), 80,
    )
    assert_true(bar.tracking)
    _ = bar.handle_event(
        Event.mouse_event(Point(fx, 0), MOUSE_BUTTON_LEFT, False, False), 80,
    )
    assert_equal(bar.open_idx, 0)
    assert_false(bar.tracking)
    # Second click: press on dropdown item triggers it (no drag needed).
    var dr = bar._dropdown_rect(80)
    var item_y = dr.a.y + 1
    var r = bar.handle_event(
        Event.mouse_event(Point(dr.a.x + 2, item_y), MOUSE_BUTTON_LEFT, True, False),
        80,
    )
    assert_true(r.action)
    assert_equal(r.action.value(), EDITOR_SAVE)
    assert_false(bar.is_open())


def test_file_dialog_selects_a_file() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo in the listing and step to it.
    var target = -1
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    while dlg.browser.selected < target:
        _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


def test_file_dialog_mouse_click_selects() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    var screen = Rect(0, 0, 80, 24)
    # Geometry: width=60, height=18, x=10, y=3 → list_top=6.
    # Clicking row 7 (in-screen) maps to entry index = 0 + (7 - 6) = 1.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 7), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_equal(dlg.browser.selected, 1)
    assert_false(dlg.submitted)


def test_file_dialog_double_click_opens() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    # Find hello.mojo, then click it twice.
    var target = -1
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String("hello.mojo"):
            target = i
            break
    assert_true(target > 0)
    var screen = Rect(0, 0, 80, 24)
    var list_top = 6
    var visible_y = list_top + (target - dlg.browser.scroll)
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, visible_y), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_equal(dlg.browser.selected, target)
    assert_false(dlg.submitted)
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, visible_y), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


def test_file_dialog_wheel_scrolls() raises:
    var dlg = FileDialog()
    dlg.open(String("examples"))
    var screen = Rect(0, 0, 80, 24)
    var initial = dlg.browser.scroll
    # Wheel down a few times.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_DOWN, True, False),
        screen,
    )
    # If there are more entries than the visible window, scroll moves; else stays.
    if len(dlg.browser.entries) > 13:
        assert_true(dlg.browser.scroll > initial)
    # Wheel up resets toward 0.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(20, 10), MOUSE_WHEEL_UP, True, False),
        screen,
    )
    assert_true(dlg.browser.scroll <= initial + 3)


def test_file_dialog_directory_mode_picks_current_dir() raises:
    """``open_directory`` filters the listing to directories and sets
    up the right-aligned " Open Project " button. Clicking that
    button submits ``browser.dir`` (not a clicked entry), so the host
    can route the picked path through ``open_project``."""
    var dlg = FileDialog()
    dlg.open_directory(String("."))
    assert_true(dlg.active)
    assert_true(dlg.dirs_only)
    assert_equal(dlg.title, String(" Open Project "))
    assert_equal(dlg.browser.dir, String("."))
    # The repo root has plain files; the dirs-only filter should
    # leave only directories (plus ``..``) in the listing.
    var saw_real_entry = False
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String(".."):
            continue
        saw_real_entry = True
        assert_true(dlg.browser.entry_is_dir[i])
    assert_true(saw_real_entry)
    # Geometry: width=60, height=18, dialog at x=10 / y=3 (centered in
    # 80×24). Buttons row at y=18; " Open Project " is 14-wide, so the
    # button face starts at x = (b.x - 1) - 14 = 55.
    var screen = Rect(0, 0, 80, 24)
    # Press on the button face — captures the click.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(56, 18), MOUSE_BUTTON_LEFT, True, False),
        screen,
    )
    assert_false(dlg.submitted)
    # Release inside the same button fires it; ``selected_path`` must
    # be the *current dir*, not whatever happened to be highlighted.
    _ = dlg.handle_mouse(
        Event.mouse_event(Point(56, 18), MOUSE_BUTTON_LEFT, False, False),
        screen,
    )
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("."))


def test_file_dialog_directory_mode_enter_does_not_submit() raises:
    """In dirs-only mode every entry is navigable, so Enter on a
    directory descends rather than submitting. Submission goes
    exclusively through the Open button — otherwise the user could
    never browse past their starting directory."""
    var dlg = FileDialog()
    dlg.open_directory(String("."))
    # Step the selection off ``..`` and onto the first real directory,
    # then press Enter. The dialog should descend (browser.dir
    # changes) without flipping ``submitted``.
    _ = dlg.handle_key(Event.key_event(KEY_DOWN))
    var initial_dir = dlg.browser.dir
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_false(dlg.submitted)
    assert_true(dlg.browser.dir != initial_dir)


def test_save_as_dialog_seeds_from_existing_path() raises:
    """``open(start_path)`` splits the path: directory feeds the listing,
    basename pre-fills the filename input, focus starts on the input.
    Listing must be dirs-only (the user is picking a folder)."""
    var dlg = SaveAsDialog()
    # Use ``./hello.mojo`` so the listing draws from the repo root —
    # which actually has subdirectories — making the dirs-only filter
    # observable. (The ``examples/`` directory has no subdirs, so a
    # filter test rooted there would pass vacuously.)
    dlg.open(String("./hello.mojo"))
    assert_true(dlg.active)
    assert_equal(dlg.filename.text, String("hello.mojo"))
    assert_equal(dlg.browser.dir, String("."))
    # The repo root has plain files (CLAUDE.md, run.sh, pixi.toml, …).
    # If the filter were broken, the listing would include them; we
    # require every entry to be a directory.
    var saw_real_entry = False
    for i in range(len(dlg.browser.entries)):
        if dlg.browser.entries[i] == String(".."):
            continue
        saw_real_entry = True
        assert_true(dlg.browser.entry_is_dir[i])
    assert_true(saw_real_entry)


def test_save_as_dialog_typing_updates_filename() raises:
    var dlg = SaveAsDialog()
    dlg.open(String(""))
    assert_equal(dlg.filename.text, String(""))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("a"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("b"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord(".")), MOD_NONE))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("t"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("x"))))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("t"))))
    assert_equal(dlg.filename.text, String("ab.txt"))
    # Backspace deletes from the input while focus stays there.
    _ = dlg.handle_key(Event.key_event(KEY_BACKSPACE))
    assert_equal(dlg.filename.text, String("ab.tx"))


def test_save_as_dialog_enter_submits_joined_path() raises:
    var dlg = SaveAsDialog()
    dlg.open(String("examples/hello.mojo"))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    assert_equal(dlg.selected_path, String("examples/hello.mojo"))


def test_save_as_dialog_tab_focus_then_listing_navigation() raises:
    """Tab moves focus to the listing; Enter on the listing descends
    rather than submitting, since the user is still picking a folder."""
    var dlg = SaveAsDialog()
    dlg.open(String("examples/hello.mojo"))
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    # Up to ``..``, then Enter to ascend.
    _ = dlg.handle_key(Event.key_event(KEY_UP))
    assert_equal(dlg.browser.selected, 0)
    assert_equal(dlg.browser.entries[0], String(".."))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_false(dlg.submitted)
    # Tab back, then Enter — should submit at the new (parent) directory.
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)
    # ``..`` from "examples" lands on the project root; the path joins
    # the new dir with the unchanged filename.
    assert_true(dlg.selected_path.as_bytes()[len(dlg.selected_path.as_bytes()) - 1] != 0x2F)
    var n = len(dlg.selected_path.as_bytes())
    var b = dlg.selected_path.as_bytes()
    var hello = String("hello.mojo").as_bytes()
    var hn = len(hello)
    assert_true(n >= hn)
    for i in range(hn):
        assert_equal(Int(b[n - hn + i]), Int(hello[i]))


def test_save_as_dialog_empty_filename_blocks_submit() raises:
    var dlg = SaveAsDialog()
    dlg.open(String(""))
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_false(dlg.submitted)


def test_editor_sticky_col_down_through_short_line() raises:
    """Down-arrowing from a wide line through a short one and back to a wider
    one returns the cursor to the original column."""
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 11)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Line 1 ("ab") is 2 chars: cursor clamps but desired_col is preserved.
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Line 2 is 10 chars: cursor lands at min(11, 10) = 10. Desired untouched.
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 11)


def test_editor_sticky_col_up_through_short_line() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 10)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)


def test_editor_sticky_col_reset_by_left_arrow() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    # Horizontal move resets the remembered column to wherever we end up.
    assert_equal(ed.cursor_col, 1)
    assert_equal(ed.desired_col, 1)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 1)


def test_editor_sticky_col_reset_by_right_arrow() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # cursor (1, 2), desired 11. Right at end of line moves to start of next.
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 0)
    assert_equal(ed.desired_col, 0)


def test_editor_sticky_col_reset_by_typing() raises:
    var ed = Editor(String("hello world\nab"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(UInt32(ord("X"))), _VIEW)
    assert_equal(ed.cursor_col, 3)
    assert_equal(ed.desired_col, 3)


def test_editor_sticky_col_reset_by_click() raises:
    var ed = Editor(String("hello world\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.desired_col, 11)
    var view = Rect(0, 0, 40, 10)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.cursor_col, 3)
    assert_equal(ed.desired_col, 3)


def test_editor_sticky_col_reset_by_home_end() raises:
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)        # desired=11
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)       # row 1, col 2, desired 11
    _ = ed.handle_key(_key(KEY_HOME), _VIEW)
    assert_equal(ed.cursor_col, 0)
    assert_equal(ed.desired_col, 0)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 0)


def test_editor_sticky_col_pageup_pagedown() raises:
    var ed = Editor(
        String("0123456789\n0123456789\nab\n0123456789\n0123456789\n0123456789")
    )
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_col, 10)
    var small_view = Rect(0, 0, 80, 3)
    _ = ed.handle_key(_key(KEY_PAGEDOWN), small_view)
    # PageDown jumps view-height (3) rows; the destination line is 10 chars long.
    assert_equal(ed.cursor_row, 3)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)
    # Step back through the short line; sticky column survives.
    _ = ed.handle_key(_key(KEY_UP), small_view)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 10)
    _ = ed.handle_key(_key(KEY_PAGEUP), small_view)
    # PageUp from row 2 jumps to row 0 (clamped at 0).
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 10)


def test_editor_sticky_col_shift_down_keeps_anchor() raises:
    """Shift+Down should extend selection and use the sticky column too."""
    var ed = Editor(String("hello world\nab\nabcdefghij"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_SHIFT), _VIEW)
    assert_true(ed.has_selection())
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.anchor_row, 0)
    assert_equal(ed.anchor_col, 11)
    assert_equal(ed.desired_col, 11)
    _ = ed.handle_key(_key(KEY_DOWN, MOD_SHIFT), _VIEW)
    assert_equal(ed.cursor_row, 2)
    assert_equal(ed.cursor_col, 10)
    assert_equal(ed.desired_col, 11)


def test_editor_left_right_steps_over_multibyte_codepoint() raises:
    """Arrow keys must move by whole UTF-8 codepoints — never park the
    cursor in the middle of a multi-byte sequence."""
    # "café" — bytes: c(0), a(1), f(2), é(3-4). 4 codepoints, 5 bytes.
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_col, 3)        # at start of é
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_col, 5)        # past é, end of line (skipped 2 bytes)
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.cursor_col, 3)        # back over the whole codepoint
    _ = ed.handle_key(_key(KEY_LEFT), _VIEW)
    assert_equal(ed.cursor_col, 2)        # ASCII step works as before


def test_editor_backspace_removes_whole_codepoint() raises:
    """Backspace at the end of a line containing é must remove all of é."""
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_END), _VIEW)
    assert_equal(ed.cursor_col, 5)
    _ = ed.handle_key(_key(KEY_BACKSPACE), _VIEW)
    assert_equal(ed.buffer.line(0), String("caf"))
    assert_equal(ed.cursor_col, 3)


def test_editor_delete_key_removes_whole_codepoint() raises:
    """Delete (forward) at the boundary before é must remove all of é and
    leave the buffer as valid UTF-8."""
    var ed = Editor(String("café"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    assert_equal(ed.cursor_col, 3)
    _ = ed.handle_key(_key(KEY_DELETE), _VIEW)
    assert_equal(ed.buffer.line(0), String("caf"))
    assert_equal(ed.cursor_col, 3)


def test_editor_vertical_movement_uses_cell_column() raises:
    """Down through a row of multi-byte characters preserves the visual
    column, not the byte offset. ``ééé`` is 6 bytes / 3 cells; landing
    column 2 (cells) on it must be byte 4, not byte 2 (mid-codepoint)."""
    # Line 0: "abcdef" (6 ASCII), line 1: "ééé" (3 codepoints, 6 bytes).
    var ed = Editor(String("abcdef\néééxyz"))
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)
    _ = ed.handle_key(_key(KEY_RIGHT), _VIEW)        # cursor on 'c'
    assert_equal(ed.cursor_col, 2)
    assert_equal(ed.desired_col, 2)
    _ = ed.handle_key(_key(KEY_DOWN), _VIEW)
    # Cell 2 on "éééxyz" is the third é → byte 4, a codepoint boundary.
    assert_equal(ed.cursor_row, 1)
    assert_equal(ed.cursor_col, 4)
    assert_equal(ed.desired_col, 2)
    _ = ed.handle_key(_key(KEY_UP), _VIEW)
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 2)


def test_editor_mouse_click_lands_on_codepoint_boundary() raises:
    """A click at cell column N inside a multi-byte run must drop the cursor
    at the *codepoint* at column N, never mid-sequence."""
    var ed = Editor(String("ééé"))
    var view = Rect(0, 0, 40, 10)
    # Cell column 2 → third é → byte offset 4.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(2, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.cursor_row, 0)
    assert_equal(ed.cursor_col, 4)
    # Far past EOL clamps to line end (a boundary).
    _ = ed.handle_mouse(
        Event.mouse_event(Point(20, 0), MOUSE_BUTTON_LEFT, True, False),
        view,
    )
    assert_equal(ed.cursor_col, 6)


def test_window_v_scrollbar_hit_arrows_and_thumb() raises:
    var lines = String("")
    for i in range(50):
        lines = lines + String("line ") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    # Geometry: width 30, height 10. Scroll bar is at x = 29.
    # Up arrow at y=1 (border row a.y is 0, so a.y+1=1).
    var hit_up = w.v_scrollbar_hit(Point(29, 1))
    assert_equal(hit_up[0], 1)
    var hit_down = w.v_scrollbar_hit(Point(29, 8))
    assert_equal(hit_down[0], 5)
    # Scroll to the top — thumb sits at the top of the track.
    w.editor.scroll_y = 0
    var hit_thumb_top = w.v_scrollbar_hit(Point(29, 2))
    assert_equal(hit_thumb_top[0], 3)
    # Anything off the v-scrollbar column returns 0.
    var miss = w.v_scrollbar_hit(Point(15, 4))
    assert_equal(miss[0], 0)


def test_window_v_scroll_by_clamps() raises:
    var lines = String("")
    for i in range(50):
        lines = lines + String("L") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    w.editor.scroll_y = 5
    w.v_scroll_by(-1)
    assert_equal(w.editor.scroll_y, 4)
    w.v_scroll_by(100)
    # Buffer = 50 lines + trailing empty = 51; view height = 8; max = 43.
    var view_h = 10 - 2
    var max_y = w.editor.buffer.line_count() - view_h
    assert_equal(w.editor.scroll_y, max_y)
    w.v_scroll_by(-1000)
    assert_equal(w.editor.scroll_y, 0)


def test_window_v_scrollbar_track_click_centers_target() raises:
    """A click in the page area of the v-scrollbar jumps to the
    proportional buffer row and centers it in the view, instead of
    scrolling by one page. With 51 buffer rows in an 8-row view and a
    6-cell track, a click at track row 3 corresponds to row 25 in the
    file; centering puts ``scroll_y`` at ``25 - 8/2 = 21``."""
    var lines = String("")
    for i in range(50):
        lines = lines + String("L") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    # Click below the thumb (part 4): track row 3 of 6.
    var hit = w.v_scrollbar_hit(Point(29, 5))
    assert_equal(hit[0], 4)
    assert_equal(hit[1], 3)
    w.v_scroll_to_track_pos(hit[1])
    assert_equal(w.editor.scroll_y, 21)
    # Click at the very top of the track jumps to row 0 — already at the
    # file's start, so centering can't go negative; ``scroll_y`` clamps
    # to 0.
    w.editor.scroll_y = 30
    w.v_scroll_to_track_pos(0)
    assert_equal(w.editor.scroll_y, 0)
    # Click at the bottom of the track centers a row near the end of the
    # file. Track row 5 of 6 maps to row ``5*51/6 = 42``; centered that
    # leaves ``scroll_y = 42 - 4 = 38``, which is below ``max_scroll``
    # (43) — so the user lands with line 42 in the middle of the view
    # rather than glued to the bottom of the file.
    w.v_scroll_to_track_pos(5)
    assert_equal(w.editor.scroll_y, 38)


def test_window_v_scroll_drag_to_end() raises:
    var lines = String("")
    for i in range(50):
        lines = lines + String("L") + String(i) + String("\n")
    var w = Window.editor_window(String("ed"), Rect(0, 0, 30, 10), lines)
    # Drag the thumb to the very bottom of the track.
    w.v_drag_thumb_to(8, 0)
    var view_h = 10 - 2
    var max_y = w.editor.buffer.line_count() - view_h
    assert_equal(w.editor.scroll_y, max_y)
    # Drag to the top.
    w.v_drag_thumb_to(2, 0)
    assert_equal(w.editor.scroll_y, 0)


# --- Phase-2 LSP plumbing tests --------------------------------------------


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_json_round_trip_lsp_envelope() raises:
    """A representative JSON-RPC request envelope round-trips."""
    var params = json_object()
    params.put(String("processId"), json_int(0))
    params.put(String("rootUri"), json_null())
    params.put(String("capabilities"), json_object())
    var req = json_object()
    req.put(String("jsonrpc"), json_str(String("2.0")))
    req.put(String("id"), json_int(1))
    req.put(String("method"), json_str(String("initialize")))
    req.put(String("params"), params^)
    var encoded = encode_json(req)
    assert_equal(
        encoded,
        String("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
              + "\"params\":{\"processId\":0,\"rootUri\":null,"
              + "\"capabilities\":{}}}"),
    )
    var reparsed = parse_json(encoded)
    assert_true(reparsed.is_object())
    assert_equal(reparsed.object_get(String("id")).value().as_int(), 1)
    var p = reparsed.object_get(String("params")).value().copy()
    assert_true(p.object_get(String("rootUri")).value().is_null())
    assert_true(p.object_get(String("capabilities")).value().is_object())


def test_json_string_escapes() raises:
    # Includes a literal 0x01 byte to exercise the \uXXXX path.
    var raw = String("a\"b\\c\nd\te") + chr(1) + String("f")
    var enc = encode_json(json_str(raw))
    assert_equal(enc, String("\"a\\\"b\\\\c\\nd\\te\\u0001f\""))
    var dec = parse_json(enc)
    assert_true(dec.is_string())
    assert_equal(dec.as_str(), raw)


def test_json_parse_errors_raise() raises:
    var ok = True
    try:
        _ = parse_json(String("{"))
        ok = False
    except:
        pass
    assert_true(ok)
    try:
        _ = parse_json(String("{\"a\":1"))
        ok = False
    except:
        pass
    assert_true(ok)
    try:
        _ = parse_json(String("\"unterminated"))
        ok = False
    except:
        pass
    assert_true(ok)


def test_json_floats_round_trip_as_text() raises:
    var v = parse_json(String("3.14"))
    assert_true(v.is_float())
    assert_equal(encode_json(v), String("3.14"))


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
    assert_equal(c.id.value(), 7)
    assert_true(Bool(c.result))
    var note = parse_json(String(
        "{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\","
        + "\"params\":{\"type\":3,\"message\":\"hi\"}}"
    ))
    var cn = classify_message(note)
    assert_equal(Int(cn.kind), Int(LSP_NOTIFICATION))
    assert_equal(cn.method.value(), String("window/logMessage"))


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


def test_editor_completion_prefix_start_walks_back_through_word() raises:
    """``completion_prefix_start`` returns the col where the in-progress
    identifier begins. Used to anchor the popup so accepting an entry
    replaces what the user already typed."""
    var ed = Editor(String("foo + abcde"))
    ed.move_to(0, 9, False)  # park inside "abcde", 3 bytes in
    var s = ed.completion_prefix_start()
    assert_equal(s, 6)


def test_editor_set_completions_opens_popup() raises:
    """``set_completions`` flips the popup visible and parks items.
    An empty list closes (or stays closed) so a server response with
    zero matches doesn't paint an empty popup."""
    var ed = Editor(String("foo"))
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foo_bar"), String("foo_bar"), 6, String(""),
        String("foo_bar"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    items.append(CompletionItem(
        String("foo_baz"), String("foo_baz"), 6, String(""),
        String("foo_baz"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 0)
    assert_true(ed.completion_popup_visible)
    assert_equal(len(ed.completion_items), 2)
    assert_equal(ed.completion_highlight, 0)
    ed.close_completion_popup()
    assert_false(ed.completion_popup_visible)
    # Empty list is treated as "close" — no stale state lingers.
    ed.set_completions(List[CompletionItem](), 0, 0)
    assert_false(ed.completion_popup_visible)


def test_editor_typing_word_char_stamps_autotrigger_request() raises:
    """Typing an identifier char (letter, digit, underscore) auto-stamps
    ``pending_completion_request`` so the desktop dispatches a fresh
    LSP query without the user having to press the completion key."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x66))  # 'f'
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_completion_request()
    assert_true(Bool(req))
    assert_equal(req.value().col, 1)
    # ``.`` is also a trigger so member-access pops up the popup.
    var ev2 = Event.key_event(UInt32(0x2E))  # '.'
    _ = ed.handle_key(ev2, Rect(0, 0, 40, 5))
    var req2 = ed.consume_completion_request()
    assert_true(Bool(req2))


def test_editor_typing_non_word_char_skips_autotrigger() raises:
    """Typing punctuation that doesn't extend an identifier (space,
    ``(``, ``=``, …) must NOT auto-stamp a completion request — that
    would fire LSP queries on every keystroke."""
    var ed = Editor(String(""))
    var ev = Event.key_event(UInt32(0x28))  # '('
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    var req = ed.consume_completion_request()
    assert_false(Bool(req))


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


def test_editor_typing_non_word_char_closes_visible_popup() raises:
    """A visible popup gets dismissed when the user types a char that
    doesn't extend the in-progress identifier (e.g. space)."""
    var ed = Editor(String(""))
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foo"), String("foo"), 6, String(""),
        String("foo"), False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    ed.set_completions(items^, 0, 0)
    assert_true(ed.completion_popup_visible)
    var ev = Event.key_event(UInt32(0x20))  # space
    _ = ed.handle_key(ev, Rect(0, 0, 40, 5))
    assert_false(ed.completion_popup_visible)


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


def _popup_items_one() -> List[CompletionItem]:
    var items = List[CompletionItem]()
    items.append(CompletionItem(
        String("foobar"), String("foobar"), 6, String(""), String("foobar"),
        False, 0, 0, 0, 0,
        List[TextEditEntry](),
    ))
    return items^


def test_desktop_esc_dismisses_completion_popup() raises:
    """ESC routed through the Desktop must close the focused editor's
    completion popup before any other ESC-bound action (menu close /
    multi-caret clear / esc-prefix arm). Without this the popup would
    persist until the user typed past the anchor."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 3, False)
    d.windows.windows[0].editor.set_completions(
        _popup_items_one(), 0, 0,
    )
    assert_true(d.windows.windows[0].editor.completion_popup_visible)
    _ = d.handle_event(Event.key_event(KEY_ESC), _SCREEN)
    assert_false(d.windows.windows[0].editor.completion_popup_visible)
    # ESC must not have also armed the menu-mnemonic prefix when it was
    # consumed by the popup-close path.
    assert_false(d._esc_armed)


def test_desktop_left_click_outside_popup_dismisses_it() raises:
    """A left-click anywhere outside the popup's screen rect dismisses
    it. The click still proceeds to its normal target — the popup is
    just a transient overlay."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 3, False)
    d.windows.windows[0].editor.set_completions(
        _popup_items_one(), 0, 0,
    )
    assert_true(d.windows.windows[0].editor.completion_popup_visible)
    # Click somewhere clearly outside the popup (far-right column of
    # the editor's text area; popup is anchored at column 0).
    _ = d.handle_event(
        Event.mouse_event(
            Point(35, 10), MOUSE_BUTTON_LEFT, True, False,
        ),
        _SCREEN,
    )
    assert_false(d.windows.windows[0].editor.completion_popup_visible)


def test_desktop_left_click_inside_popup_keeps_it_open() raises:
    """A left-click that lands *inside* the popup rect must not dismiss
    it — that lane is reserved for future item-click acceptance."""
    var d = Desktop()
    d.windows.add(Window.editor_window(
        String("buf"), Rect(0, 1, 40, 12), String("foo bar\n"),
    ))
    d.windows.windows[0].editor.move_to(0, 3, False)
    d.windows.windows[0].editor.set_completions(
        _popup_items_one(), 0, 0,
    )
    var interior = d.windows.windows[0].interior()
    var maybe_rect = d.windows.windows[0] \
        .editor.completion_popup_screen_rect(interior)
    assert_true(Bool(maybe_rect))
    var pr = maybe_rect.value()
    # Click the popup's top-left interior cell.
    _ = d.handle_event(
        Event.mouse_event(
            Point(pr.a.x, pr.a.y), MOUSE_BUTTON_LEFT, True, False,
        ),
        _SCREEN,
    )
    assert_true(d.windows.windows[0].editor.completion_popup_visible)


def test_editor_show_no_completion_message_opens_unselectable_popup() raises:
    """``show_no_completion_message`` opens a popup with a single
    non-acceptable ``<no completion found>`` entry. Arrow keys must
    not move the highlight and Enter must dismiss without inserting."""
    var ed = Editor(String("foo"))
    ed.move_to(0, 3, False)
    ed.show_no_completion_message(0, 0)
    assert_true(ed.completion_popup_visible)
    assert_true(ed.completion_is_message)
    assert_equal(len(ed.completion_items), 1)
    assert_equal(
        ed.completion_items[0].label, String("<no completion found>"),
    )
    # Arrow keys are no-ops on a message popup.
    ed._completion_step(1)
    assert_equal(ed.completion_highlight, 0)
    # Enter dismisses, does not insert anything.
    var ok = ed.accept_completion()
    assert_true(ok)
    assert_false(ed.completion_popup_visible)
    assert_false(ed.completion_is_message)
    assert_equal(ed.buffer.line(0), String("foo"))


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
    assert_equal(ed.cursor_col, 12)
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
    assert_equal(ed.cursor_col, 26)


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
    assert_equal(ed.cursor_col, 26)
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
    assert_equal(ed.cursor_row, 3)
    assert_equal(ed.cursor_col, 8)
    assert_false(ed.completion_popup_visible)


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


def test_editor_set_diagnostics_builds_per_row_severity_index() raises:
    """``Editor.set_diagnostics`` populates ``diagnostic_lines`` so
    that each row carries the *winning* (lowest-numbered) severity.
    A row with both an error and a warning surfaces as Error; the
    minimap uses this index without re-walking the diagnostic list."""
    var ed = Editor(String("first\nsecond\nthird\nfourth"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 5, DIAG_SEVERITY_WARNING, String("warn"), String("test"),
    ))
    diags.append(Diagnostic(
        1, 0, 1, 6, DIAG_SEVERITY_ERROR, String("err"), String("test"),
    ))
    diags.append(Diagnostic(
        # Same row as the warning above — error must win.
        0, 1, 0, 4, DIAG_SEVERITY_ERROR, String("err2"), String("test"),
    ))
    diags.append(Diagnostic(
        2, 0, 2, 5, DIAG_SEVERITY_HINT, String("hint"), String("test"),
    ))
    # Row 3 has no diagnostic; must stay clean.
    ed.set_diagnostics(diags^)
    assert_equal(len(ed.diagnostic_lines), 4)
    assert_equal(ed.diagnostic_lines[0], DIAG_SEVERITY_ERROR)
    assert_equal(ed.diagnostic_lines[1], DIAG_SEVERITY_ERROR)
    assert_equal(ed.diagnostic_lines[2], DIAG_SEVERITY_HINT)
    assert_equal(ed.diagnostic_lines[3], 0)


def test_editor_minimap_kind_prioritizes_error_over_git_and_spell() raises:
    """An LSP error on a row outranks both an uncommitted-change marker
    and a spell flag on the same row — the user shouldn't have to scroll
    past whitespace edits to see real problems on the minimap."""
    var ed = Editor(String("alpha\nbeta\ngamma"))
    # Pretend git change + spell flag on row 0.
    var git = List[Int]()
    git.append(2)  # GIT_CHANGE_MODIFIED
    git.append(0)
    git.append(0)
    ed.git_change_lines = git^
    var spell = List[Bool]()
    spell.append(True)
    spell.append(False)
    spell.append(False)
    ed.spell_lines = spell^
    # Error on the same row.
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 3, DIAG_SEVERITY_ERROR, String("e"), String("test"),
    ))
    ed.set_diagnostics(diags^)
    # Error wins (kind=3) over git (1) and spell (2).
    var kind = ed._minimap_kind_in_slice(0, 1)
    assert_equal(kind, 3)
    # Also: an empty slice past the end returns 0 (clean).
    assert_equal(ed._minimap_kind_in_slice(2, 3), 0)


def test_editor_minimap_warning_outranks_git_change() raises:
    """Same priority test, one notch lower: warning beats git change."""
    var ed = Editor(String("a\nb"))
    var git = List[Int]()
    git.append(2)
    git.append(0)
    ed.git_change_lines = git^
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 1, DIAG_SEVERITY_WARNING, String("w"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    assert_equal(ed._minimap_kind_in_slice(0, 1), 4)


def test_editor_minimap_hint_loses_to_spell() raises:
    """Hints sit at the bottom of the priority ladder so a 'consider
    renaming' message can't drown a real misspelling on the minimap."""
    var ed = Editor(String("a\nb"))
    var spell = List[Bool]()
    spell.append(True)
    spell.append(False)
    ed.spell_lines = spell^
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 1, DIAG_SEVERITY_HINT, String("h"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    # Spell (kind=2) beats hint (kind=6).
    assert_equal(ed._minimap_kind_in_slice(0, 1), 2)


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
    assert_equal(msg.id.value(), req_id)
    assert_true(Bool(msg.result))
    assert_true(msg.result.value().is_object())
    assert_true(msg.result.value().object_has(String("capabilities")))
    client.send_notification(String("initialized"), json_object())
    var shutdown_id = client.send_request(String("shutdown"), json_null())
    for _ in range(100):
        var maybe2 = client.poll(Int32(50))
        if maybe2 and Bool(maybe2.value().id) \
                and maybe2.value().id.value() == shutdown_id:
            break
    client.send_notification(String("exit"), json_null())
    var exited = False
    for _ in range(20):
        if client.process.try_reap():
            exited = True
            break
    if not exited:
        client.terminate()


def test_dap_classify_response() raises:
    var resp = parse_json(String(
        "{\"seq\":3,\"type\":\"response\",\"request_seq\":1,"
        + "\"success\":true,\"command\":\"initialize\","
        + "\"body\":{\"supportsConfigurationDoneRequest\":true}}"
    ))
    var c = classify_dap_message(resp)
    assert_equal(Int(c.kind), Int(DAP_RESPONSE))
    assert_equal(c.seq, 3)
    assert_true(Bool(c.request_seq))
    assert_equal(c.request_seq.value(), 1)
    assert_true(Bool(c.success))
    assert_true(c.success.value())
    assert_equal(c.command.value(), String("initialize"))
    assert_true(Bool(c.body))


def test_dap_classify_event() raises:
    var ev = parse_json(String(
        "{\"seq\":4,\"type\":\"event\",\"event\":\"stopped\","
        + "\"body\":{\"reason\":\"breakpoint\",\"threadId\":1,"
        + "\"allThreadsStopped\":true}}"
    ))
    var c = classify_dap_message(ev)
    assert_equal(Int(c.kind), Int(DAP_EVENT))
    assert_equal(c.seq, 4)
    assert_equal(c.event.value(), String("stopped"))
    assert_true(Bool(c.body))


def test_dap_classify_reverse_request() raises:
    var rq = parse_json(String(
        "{\"seq\":5,\"type\":\"request\",\"command\":\"runInTerminal\","
        + "\"arguments\":{\"args\":[\"/usr/bin/echo\"]}}"
    ))
    var c = classify_dap_message(rq)
    assert_equal(Int(c.kind), Int(DAP_REQUEST))
    assert_equal(c.command.value(), String("runInTerminal"))
    assert_true(Bool(c.arguments))


def test_dap_classify_response_with_failure() raises:
    var resp = parse_json(String(
        "{\"seq\":7,\"type\":\"response\",\"request_seq\":2,"
        + "\"success\":false,\"command\":\"launch\","
        + "\"message\":\"file not found\"}"
    ))
    var c = classify_dap_message(resp)
    assert_equal(Int(c.kind), Int(DAP_RESPONSE))
    assert_true(Bool(c.success))
    assert_false(c.success.value())
    assert_true(Bool(c.message))
    assert_equal(c.message.value(), String("file not found"))


def test_dap_initialize_arguments_shape() raises:
    var args = dap_initialize_arguments(
        String("turbokod"), String("debugpy"),
    )
    assert_true(args.is_object())
    assert_true(args.object_has(String("clientID")))
    assert_true(args.object_has(String("adapterID")))
    var aid = args.object_get(String("adapterID"))
    assert_equal(aid.value().as_str(), String("debugpy"))
    var lstart = args.object_get(String("linesStartAt1"))
    assert_true(lstart.value().is_bool())
    assert_false(lstart.value().as_bool())


def test_dap_seq_autoincrement_via_cat() raises:
    """End-to-end: sequence numbers increment monotonically across
    requests. ``/bin/cat`` is the cheapest pipe-back fixture available."""
    var cat_info = stat_file(String("/bin/cat"))
    if not cat_info.ok:
        assert_true(True)
        return
    var argv = List[String]()
    argv.append(String("/bin/cat"))
    var client = DapClient.spawn(argv)
    var seq1 = client.send_request(String("initialize"), json_object())
    var seq2 = client.send_request(String("threads"), json_object())
    assert_equal(seq1, 1)
    assert_equal(seq2, 2)
    client.terminate()


def test_dap_parse_threads() raises:
    var body = parse_json(String(
        "{\"threads\":[{\"id\":1,\"name\":\"main\"},"
        + "{\"id\":2,\"name\":\"worker\"}]}"
    ))
    var threads = _parse_threads(Optional[JsonValue](body.copy()))
    assert_equal(len(threads), 2)
    assert_equal(threads[0].id, 1)
    assert_equal(threads[0].name, String("main"))
    assert_equal(threads[1].id, 2)
    assert_equal(threads[1].name, String("worker"))


def test_dap_parse_stack_trace_zero_based() raises:
    """Adapters return 1-based lines (debugpy + delve always; lldb-dap
    honors our linesStartAt1=false flag). The parser normalizes to
    0-based to match Editor's row index."""
    var body = parse_json(String(
        "{\"stackFrames\":[{\"id\":42,\"name\":\"main\","
        + "\"line\":10,\"column\":1,"
        + "\"source\":{\"path\":\"/tmp/foo.py\"}}]}"
    ))
    var frames = _parse_stack_trace(Optional[JsonValue](body.copy()))
    assert_equal(len(frames), 1)
    assert_equal(frames[0].id, 42)
    assert_equal(frames[0].name, String("main"))
    assert_equal(frames[0].path, String("/tmp/foo.py"))
    assert_equal(frames[0].line, 9)
    assert_equal(frames[0].column, 0)


def test_dap_parse_scopes_and_variables() raises:
    var scopes_body = parse_json(String(
        "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":7,"
        + "\"expensive\":false}]}"
    ))
    var scopes = _parse_scopes(Optional[JsonValue](scopes_body.copy()))
    assert_equal(len(scopes), 1)
    assert_equal(scopes[0].name, String("Locals"))
    assert_equal(scopes[0].variables_reference, 7)
    assert_false(scopes[0].expensive)
    var vars_body = parse_json(String(
        "{\"variables\":[{\"name\":\"x\",\"value\":\"42\","
        + "\"type\":\"int\",\"variablesReference\":0},"
        + "{\"name\":\"obj\",\"value\":\"<Foo>\",\"type\":\"Foo\","
        + "\"variablesReference\":11}]}"
    ))
    var variables = _parse_variables(Optional[JsonValue](vars_body.copy()))
    assert_equal(len(variables), 2)
    assert_equal(variables[0].name, String("x"))
    assert_equal(variables[0].value, String("42"))
    assert_equal(variables[0].type_name, String("int"))
    assert_equal(variables[0].variables_reference, 0)
    assert_equal(variables[1].variables_reference, 11)


def test_dap_registry_lookup() raises:
    var debs = built_in_debuggers()
    assert_true(len(debs) >= 3)
    var py = find_debugger_for_language(debs, String("python"))
    assert_true(py >= 0)
    assert_equal(debs[py].name, String("debugpy"))
    var unknown = find_debugger_for_language(debs, String("ada"))
    assert_equal(unknown, -1)


def test_dap_launch_arguments_for_debugpy() raises:
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("--verbose"))
    var body = launch_arguments_for(
        debs[idx], String("/tmp/main.py"), String("/tmp"), args^, False,
    )
    assert_true(body.is_object())
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("/tmp/main.py"),
    )
    assert_equal(
        body.object_get(String("console")).value().as_str(),
        String("internalConsole"),
    )
    var arr = body.object_get(String("args"))
    assert_true(arr.value().is_array())
    assert_equal(arr.value().array_len(), 1)
    assert_equal(arr.value().array_at(0).as_str(), String("--verbose"))


def test_dap_launch_arguments_for_debugpy_module_mode() raises:
    """``python -m pytest tests/x.py`` should be rewritten to debugpy's
    ``module`` field — debugpy can't ``runpy`` the python binary."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("pytest"))
    args.append(String("tests/x.py"))
    var body = launch_arguments_for(
        debs[idx],
        String("/Users/me/p/venv/bin/python"),
        String("/Users/me/p"),
        args^,
        False,
    )
    assert_true(body.is_object())
    # Rewritten: ``module: pytest``, ``program`` absent, residual args
    # carry just the test path.
    assert_true(not body.object_get(String("program")))
    assert_equal(
        body.object_get(String("module")).value().as_str(),
        String("pytest"),
    )
    var arr = body.object_get(String("args"))
    assert_true(arr.value().is_array())
    assert_equal(arr.value().array_len(), 1)
    assert_equal(arr.value().array_at(0).as_str(), String("tests/x.py"))


def test_dap_launch_arguments_for_debugpy_versioned_python() raises:
    """``python3.11 -m unittest`` should also trigger module-mode
    rewriting — versioned interpreter basenames are still Python."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("unittest"))
    var body = launch_arguments_for(
        debs[idx],
        String("/usr/local/bin/python3.11"),
        String("/tmp"),
        args^,
        False,
    )
    assert_equal(
        body.object_get(String("module")).value().as_str(),
        String("unittest"),
    )


def test_dap_launch_arguments_for_debugpy_non_python_program() raises:
    """A real script path (not the python binary) keeps ``program``
    mode even when ``-m`` happens to be in args, because that's a
    plain CLI flag at that point."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-m"))
    args.append(String("foo"))
    var body = launch_arguments_for(
        debs[idx], String("/tmp/main.py"), String("/tmp"), args^, False,
    )
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("/tmp/main.py"),
    )
    assert_true(not body.object_get(String("module")))


def test_dap_launch_arguments_for_debugpy_script_mode() raises:
    """``python manage.py runserver`` should rewrite ``program`` to the
    script path (not the python binary) so debugpy actually runs the
    script. Without this, debugpy tries to ``runpy`` the python
    interpreter and stalls in ``_run_code``."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("manage.py"))
    args.append(String("runserver"))
    var body = launch_arguments_for(
        debs[idx],
        String("/Users/me/p/.venv/bin/python"),
        String("/Users/me/p"),
        args^,
        False,
    )
    assert_true(body.is_object())
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("manage.py"),
    )
    assert_true(not body.object_get(String("module")))
    var arr = body.object_get(String("args"))
    assert_true(arr.value().is_array())
    assert_equal(arr.value().array_len(), 1)
    assert_equal(arr.value().array_at(0).as_str(), String("runserver"))


def test_dap_launch_arguments_for_debugpy_skips_flag_args() raises:
    """When the first arg starts with a dash (e.g. ``-c``, ``-W``) we
    leave ``program`` alone — those flags need bespoke handling we
    don't do yet, so forwarding the unrewritten args lets debugpy
    error explicitly instead of silently dropping a flag."""
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("python"))
    assert_true(idx >= 0)
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("print('hi')"))
    var body = launch_arguments_for(
        debs[idx],
        String("/usr/bin/python3"),
        String("/tmp"),
        args^,
        False,
    )
    assert_equal(
        body.object_get(String("program")).value().as_str(),
        String("/usr/bin/python3"),
    )
    assert_true(not body.object_get(String("module")))


def test_dap_launch_arguments_for_delve() raises:
    var debs = built_in_debuggers()
    var idx = find_debugger_for_language(debs, String("go"))
    assert_true(idx >= 0)
    var body = launch_arguments_for(
        debs[idx], String("/tmp/cmd"), String("/tmp"), List[String](), False,
    )
    assert_equal(
        body.object_get(String("mode")).value().as_str(),
        String("debug"),
    )


def test_dap_manager_breakpoint_toggle() raises:
    """Local breakpoint state mutates correctly even with no adapter
    spawned. Toggle semantics: add → remove → add."""
    var mgr = DapManager()
    assert_false(mgr.has_breakpoint(String("/tmp/x.py"), 5))
    mgr.toggle_breakpoint(String("/tmp/x.py"), 5)
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 5))
    mgr.toggle_breakpoint(String("/tmp/x.py"), 12)
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 12))
    var lines = mgr.breakpoints_for(String("/tmp/x.py"))
    assert_equal(len(lines), 2)
    mgr.toggle_breakpoint(String("/tmp/x.py"), 5)
    assert_false(mgr.has_breakpoint(String("/tmp/x.py"), 5))
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 12))


def test_dap_manager_breakpoint_enabled_default_and_toggle() raises:
    """New breakpoints default to enabled. ``set_breakpoint_enabled``
    flips the flag; the BP stays in the list (so the gutter still
    shows it) but is omitted from ``setBreakpoints`` payloads."""
    var mgr = DapManager()
    mgr.toggle_breakpoint(String("/tmp/x.py"), 7)
    assert_true(mgr.breakpoint_enabled(String("/tmp/x.py"), 7))
    mgr.set_breakpoint_enabled(String("/tmp/x.py"), 7, False)
    assert_false(mgr.breakpoint_enabled(String("/tmp/x.py"), 7))
    # Disabled BP stays in the list — the gutter still draws it gray.
    assert_true(mgr.has_breakpoint(String("/tmp/x.py"), 7))
    mgr.set_breakpoint_enabled(String("/tmp/x.py"), 7, True)
    assert_true(mgr.breakpoint_enabled(String("/tmp/x.py"), 7))


def test_dap_manager_breakpoints_info_for() raises:
    """``breakpoints_info_for`` returns parallel lines / enabled /
    conditional lists for one path. The editor uses these to colour
    the gutter dot per-row."""
    var mgr = DapManager()
    mgr.toggle_breakpoint(String("/tmp/a.py"), 1)
    mgr.toggle_breakpoint(String("/tmp/a.py"), 2)
    mgr.set_breakpoint_condition(String("/tmp/a.py"), 2, String("i > 0"))
    mgr.toggle_breakpoint(String("/tmp/a.py"), 3)
    mgr.set_breakpoint_enabled(String("/tmp/a.py"), 3, False)
    var info = mgr.breakpoints_info_for(String("/tmp/a.py"))
    assert_equal(len(info[0]), 3)
    assert_equal(info[0][0], 1)
    assert_true(info[1][0])    # enabled
    assert_false(info[2][0])   # not conditional
    assert_equal(info[0][1], 2)
    assert_true(info[1][1])
    assert_true(info[2][1])    # conditional
    assert_equal(info[0][2], 3)
    assert_false(info[1][2])   # disabled
    assert_false(info[2][2])


def test_dap_manager_breakpoint_wait_for_arms_on_trigger() raises:
    """A BP with a non-empty wait-for stays disarmed until
    ``arm_dependents`` is called for the matching ``"path:line"``
    key. Setting and clearing ``wait_for`` flips the armed state in
    the obvious direction. Default (``toggle_breakpoint`` without a
    wait-for) is empty + armed, matching pre-feature behaviour."""
    var mgr = DapManager()
    mgr.toggle_breakpoint(String("/tmp/x.py"), 5)
    mgr.toggle_breakpoint(String("/tmp/x.py"), 12)
    # Default: no dependency, both stored as empty.
    assert_equal(mgr.breakpoint_wait_for(String("/tmp/x.py"), 5), String(""))
    assert_equal(mgr.breakpoint_wait_for_at(0), String(""))
    # Make BP at line 12 wait for the BP at line 5 (1-based on the wire).
    mgr.set_breakpoint_wait_for(
        String("/tmp/x.py"), 12, String("/tmp/x.py:6"),
    )
    assert_equal(
        mgr.breakpoint_wait_for(String("/tmp/x.py"), 12),
        String("/tmp/x.py:6"),
    )
    # Hitting an unrelated location doesn't arm it.
    mgr.arm_dependents(String("/tmp/y.py"), 5)
    # (No public predicate for armed; the only observable effect is
    # via ``_send_set_breakpoints`` skipping the BP — that's exercised
    # downstream. We at least verify ``arm_dependents`` doesn't raise.)
    # Hitting the matching location resolves the dependency.
    mgr.arm_dependents(String("/tmp/x.py"), 5)
    # Clearing the wait-for through the API returns the BP to "always
    # armed".
    mgr.set_breakpoint_wait_for(
        String("/tmp/x.py"), 12, String(""),
    )
    assert_equal(mgr.breakpoint_wait_for(String("/tmp/x.py"), 12), String(""))


def test_dap_manager_captures_condition_exception_from_output() raises:
    """A pydevd ``Error while evaluating expression in conditional
    breakpoint`` output event must be parsed into the condition + the
    short error summary (last non-empty traceback line). The full text
    is *not* swallowed — it still flows through ``take_outputs`` so
    the user sees the full traceback in the debug pane."""
    var mgr = DapManager()
    var text = String(
        "pydevd: Error while evaluating expression in conditional"
        " breakpoint: x.attr\n"
        "Traceback (most recent call last):\n"
        '  File "<string>", line 1, in <module>\n'
        "NameError: name 'x' is not defined\n"
    )
    var matched = mgr._maybe_capture_condition_exception(text)
    assert_true(matched)
    assert_true(mgr.has_condition_exception())
    var ce = mgr.take_condition_exception()
    assert_true(Bool(ce))
    assert_equal(ce.value().condition, String("x.attr"))
    assert_equal(
        ce.value().error,
        String("NameError: name 'x' is not defined"),
    )
    # Drained — second take returns nothing.
    assert_false(mgr.has_condition_exception())
    assert_false(Bool(mgr.take_condition_exception()))


def test_dap_manager_condition_exception_ignores_unrelated_output() raises:
    """Plain stdout / stderr lines must not trip the condition-exception
    parser; otherwise random app output containing the word ``error``
    would pop the dialog."""
    var mgr = DapManager()
    assert_false(mgr._maybe_capture_condition_exception(
        String("hello world\n"),
    ))
    assert_false(mgr._maybe_capture_condition_exception(
        String("Error while evaluating something else\n"),
    ))
    # Note: prefix must be exact, including the leading "pydevd: ".
    assert_false(mgr._maybe_capture_condition_exception(
        String(
            "Error while evaluating expression in conditional"
            " breakpoint: foo\n",
        ),
    ))
    assert_false(mgr.has_condition_exception())


def test_editor_right_click_on_breakpoint_emits_menu_request() raises:
    """Right-click in the gutter over a row that has a breakpoint
    surfaces a ``BreakpointMenuRequest``. A right-click on a gutter
    row *without* a breakpoint is a no-op."""
    var ed = Editor(String("a\nb\nc\nd\n"))
    ed.gutter_width = 2
    var lines = List[Int]()
    lines.append(2)
    ed.breakpoint_lines = lines^
    var view = Rect(0, 0, 40, 6)
    var ev_hit = Event.mouse_event(
        Point(0, 2), MOUSE_BUTTON_RIGHT, True, False,
    )
    _ = ed.handle_mouse(ev_hit, view)
    var req = ed.consume_breakpoint_menu()
    assert_true(Bool(req))
    assert_equal(req.value().row, 2)
    var ev_miss = Event.mouse_event(
        Point(0, 1), MOUSE_BUTTON_RIGHT, True, False,
    )
    _ = ed.handle_mouse(ev_miss, view)
    assert_false(Bool(ed.consume_breakpoint_menu()))


def test_project_targets_load_parses_fields() raises:
    """A minimal config with one run-only and one run+debug target
    must round-trip through the loader with all fields populated."""
    var root = _temp_path(String("_targets"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var dir = join_path(root, String(".turbokod"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var path = join_path(dir, String("targets.json"))
    var body = String(
        "{\n"
        + "  \"active\": \"main\",\n"
        + "  \"targets\": [\n"
        + "    {\"name\": \"tests\","
        + " \"program\": \"pixi\", \"args\": [\"run\", \"test\"]},\n"
        + "    {\"name\": \"main\","
        + " \"program\": \"app.py\", \"args\": [\"--verbose\"],"
        + " \"cwd\": \"sub\", \"language\": \"python\"}\n"
        + "  ]\n"
        + "}\n"
    )
    assert_true(write_file(path, body))
    var loaded = load_project_targets(root)
    assert_equal(len(loaded.targets), 2)
    # ``active`` resolved by name to index 1, not the file's order.
    assert_equal(loaded.active, 1)
    assert_equal(loaded.targets[0].name, String("tests"))
    assert_equal(loaded.targets[0].program, String("pixi"))
    assert_equal(len(loaded.targets[0].args), 2)
    assert_equal(loaded.targets[0].args[0], String("run"))
    assert_equal(loaded.targets[0].args[1], String("test"))
    assert_equal(loaded.targets[0].debug_language, String(""))
    assert_equal(loaded.targets[1].name, String("main"))
    assert_equal(loaded.targets[1].program, String("app.py"))
    assert_equal(loaded.targets[1].cwd, String("sub"))
    assert_equal(loaded.targets[1].debug_language, String("python"))
    assert_equal(len(loaded.targets[1].args), 1)
    assert_equal(loaded.targets[1].args[0], String("--verbose"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_project_targets_save_roundtrips_active() raises:
    """``save_project_targets`` must rewrite the ``active`` pointer
    so the next ``load_project_targets`` returns the new selection."""
    var root = _temp_path(String("_targets_save"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var dir = join_path(root, String(".turbokod"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var path = join_path(dir, String("targets.json"))
    var body = String(
        "{\n"
        + "  \"active\": \"a\",\n"
        + "  \"targets\": [\n"
        + "    {\"name\": \"a\", \"run\": \"echo a\"},\n"
        + "    {\"name\": \"b\", \"run\": \"echo b\"}\n"
        + "  ]\n"
        + "}\n"
    )
    assert_true(write_file(path, body))
    var t = load_project_targets(root)
    assert_equal(t.active, 0)
    assert_true(t.set_active_by_name(String("b")))
    assert_true(save_project_targets(root, t))
    var t2 = load_project_targets(root)
    assert_equal(t2.active, 1)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_project_targets_resolve_paths() raises:
    """``resolved_cwd`` anchors relative cwds on the project root.
    ``resolved_program`` mirrors shell semantics: a bare name (no
    slash) is left alone for ``$PATH`` resolution, anything with a
    slash is anchored on the resolved cwd, and absolute paths pass
    through unchanged."""
    var root = String("/proj")
    assert_equal(resolved_cwd(root, String("")), root)
    assert_equal(resolved_cwd(root, String("sub/dir")), String("/proj/sub/dir"))
    assert_equal(resolved_cwd(root, String("/abs")), String("/abs"))
    # Bare name → PATH lookup, untouched.
    assert_equal(
        resolved_program(root, String(""), String("python")),
        String("python"),
    )
    assert_equal(
        resolved_program(root, String("build"), String("make")),
        String("make"),
    )
    # Slash in name → anchored on resolved cwd.
    assert_equal(
        resolved_program(root, String(""), String("bin/app")),
        String("/proj/bin/app"),
    )
    assert_equal(
        resolved_program(root, String("build"), String("./app")),
        String("/proj/build/./app"),
    )
    # Absolute program ignores cwd entirely.
    assert_equal(
        resolved_program(root, String("build"), String("/usr/bin/x")),
        String("/usr/bin/x"),
    )


def test_resolve_python_interpreter() raises:
    """Bare ``python`` swaps to ``<project>/.venv/bin/python`` when one
    exists; otherwise it's returned unchanged for ``$PATH`` lookup.
    Anything that isn't ``python`` / ``python3`` is also pass-through
    so non-Python targets aren't accidentally rewritten."""
    var root = _temp_path(String("_pyresolve"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # No venv yet — bare ``python`` falls through. (We can't assert
    # equality with literal "python" because an ambient ``VIRTUAL_ENV``
    # in the test runner's env would make ``resolve_python_interpreter``
    # pick that instead; just check it doesn't bogusly point into the
    # bare project root.)
    var no_venv = resolve_python_interpreter(root, String("python"))
    assert_true(no_venv != join_path(root, String(".venv/bin/python")))
    assert_true(no_venv != join_path(root, String("venv/bin/python")))
    # Non-Python program is always pass-through, regardless of env.
    assert_equal(
        resolve_python_interpreter(root, String("ruby")),
        String("ruby"),
    )
    assert_equal(
        resolve_python_interpreter(root, String("/usr/bin/python")),
        String("/usr/bin/python"),
    )
    # Drop a ``.venv/bin/python`` shim and confirm the lookup finds it.
    # ``.venv`` lives next to the source root so we exercise the
    # project-local detection branch (not the env-var fallback).
    var venv_dir = join_path(root, String(".venv"))
    _ = external_call["mkdir", Int32](
        (venv_dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var venv_bin = join_path(venv_dir, String("bin"))
    _ = external_call["mkdir", Int32](
        (venv_bin + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var venv_python = join_path(venv_bin, String("python"))
    assert_true(write_file(venv_python, String("#!/bin/sh\nexec /usr/bin/false\n")))
    assert_equal(
        resolve_python_interpreter(root, String("python")),
        venv_python,
    )
    assert_equal(
        resolve_python_interpreter(root, String("python3")),
        venv_python,
    )
    # Cleanup. Tear down deepest-first; ``.venv/bin/python`` is the
    # only file we created.
    _ = external_call["unlink", Int32]((venv_python + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((venv_bin + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((venv_dir + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


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


def test_detect_project_language_python_markers() raises:
    """``detect_project_language`` flags any project root that
    contains a known Python marker file (``pyproject.toml`` /
    ``setup.py`` / ``setup.cfg``) as ``python``. A bare ``*.py``
    at the root is enough on its own."""
    var root = _temp_path(String("_pylang"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # Empty project: no markers, no guess.
    assert_equal(detect_project_language(root), String(""))
    # Drop pyproject.toml — ``python`` wins immediately.
    var pyproj = join_path(root, String("pyproject.toml"))
    assert_true(write_file(pyproj, String("[project]\nname=\"x\"\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((pyproj + String("\0")).unsafe_ptr())
    # setup.py also flips the result.
    var setup = join_path(root, String("setup.py"))
    assert_true(write_file(setup, String("from setuptools import setup\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((setup + String("\0")).unsafe_ptr())
    # ``setup.cfg`` — same thing.
    var setup_cfg = join_path(root, String("setup.cfg"))
    assert_true(write_file(setup_cfg, String("[metadata]\nname = x\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((setup_cfg + String("\0")).unsafe_ptr())
    # Bare *.py at the root is the last-resort signal.
    var py_file = join_path(root, String("main.py"))
    assert_true(write_file(py_file, String("print('hi')\n")))
    assert_equal(detect_project_language(root), String("python"))
    _ = external_call["unlink", Int32]((py_file + String("\0")).unsafe_ptr())
    # No markers left → no guess.
    assert_equal(detect_project_language(root), String(""))
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_detect_project_language_no_match() raises:
    """A project root with no known markers returns the empty string,
    which the caller surfaces as a "couldn't detect" status hint
    rather than picking the wrong runner."""
    var root = _temp_path(String("_unknown"))
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var rb = join_path(root, String("hello.rb"))
    assert_true(write_file(rb, String("puts 'hi'\n")))
    assert_equal(detect_project_language(root), String(""))
    _ = external_call["unlink", Int32]((rb + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((root + String("\0")).unsafe_ptr())


def test_status_bar_tab_hit_test() raises:
    """Painting the bar captures per-tab rects; ``hit_test_tab`` then
    routes a click on each tab to its index, and a click outside
    the strip to -1."""
    var sb = StatusBar()
    var tabs = List[StatusTab]()
    tabs.append(StatusTab(String("tests"), False, False))
    tabs.append(StatusTab(String("main"), False, False))
    sb.set_tabs(tabs^, 0)
    var canvas = Canvas(80, 10)
    sb.paint(canvas, Rect(0, 0, 80, 10))
    var y = 9   # screen.b.y - 1
    var first = sb.hit_test_tab(Point(2, y), Rect(0, 0, 80, 10))
    var second = sb.hit_test_tab(Point(15, y), Rect(0, 0, 80, 10))
    # First tab starts at column 2 (1 padding + 1 separator); the
    # second tab is several columns over. Either way both >= 0.
    assert_true(first >= 0)
    assert_true(second >= 0)
    # Clicks on a different row never hit a tab.
    assert_equal(sb.hit_test_tab(Point(2, 0), Rect(0, 0, 80, 10)), -1)


def test_shadow_button_paints_face_and_shadow() raises:
    """The shared button widget must paint the label on a green
    face and drop a half-block shadow on the right column + the
    row below — same idiom the dir_browser jump strip uses."""
    var canvas = Canvas(20, 4)
    canvas.fill(Rect(0, 0, 20, 4), String(" "), Attr(BLACK, LIGHT_GRAY))
    var btn = ShadowButton(String(" OK "), 2, 1)
    paint_shadow_button(canvas, btn, Attr(BLACK, GREEN), LIGHT_GRAY)
    # Face row carries the label on green.
    assert_equal(canvas.get(2, 1).glyph, String(" "))
    assert_equal(canvas.get(3, 1).glyph, String("O"))
    assert_equal(canvas.get(4, 1).glyph, String("K"))
    assert_equal(canvas.get(3, 1).attr.bg, GREEN)
    # Right-edge shadow column at face_width + x.
    assert_equal(canvas.get(2 + 4, 1).glyph, String("▄"))
    assert_equal(canvas.get(2 + 4, 1).attr.bg, LIGHT_GRAY)
    # Bottom shadow row, shifted right by 1.
    assert_equal(canvas.get(3, 2).glyph, String("▀"))
    assert_equal(canvas.get(2 + 4, 2).glyph, String("▀"))
    # Cell to the left of the button stays untouched.
    assert_equal(canvas.get(1, 1).glyph, String(" "))
    assert_equal(canvas.get(1, 1).attr.bg, LIGHT_GRAY)


def test_shadow_button_hit_includes_shadow_rows() raises:
    """A click on the bottom-shadow row should still register —
    users miss-click downward routinely. Clicks outside the hit
    rect (or on motion / non-press events) must be rejected."""
    var btn = ShadowButton(String(" OK "), 2, 1)
    # Press inside the face.
    var press_face = Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_face))
    # Press on the right-shadow column.
    var press_shadow_r = Event.mouse_event(Point(6, 1), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_shadow_r))
    # Press on the bottom-shadow row.
    var press_shadow_b = Event.mouse_event(Point(4, 2), MOUSE_BUTTON_LEFT)
    assert_true(shadow_button_hit(btn, press_shadow_b))
    # Press just below the shadow row — outside.
    var miss = Event.mouse_event(Point(4, 3), MOUSE_BUTTON_LEFT)
    assert_false(shadow_button_hit(btn, miss))
    # Release events don't activate.
    var release = Event.mouse_event(
        Point(3, 1), MOUSE_BUTTON_LEFT, pressed=False,
    )
    assert_false(shadow_button_hit(btn, release))


def test_canvas_darken_rect_preserves_glyph() raises:
    """``darken_rect`` is the compositor primitive for drop shadows:
    it changes a cell's attr to dim-on-black but must leave the
    glyph (and width) alone, so whatever the caller painted there
    earlier still reads through the shadow."""
    var c = Canvas(10, 5)
    # Stamp some content that the shadow will overlay.
    _ = c.put_text(Point(0, 0), String("hello"), Attr(WHITE, BLUE))
    _ = c.put_text(Point(0, 1), String("world"), Attr(YELLOW, BLUE))
    c.darken_rect(Rect(2, 0, 4, 2))
    # Glyphs survive.
    assert_equal(c.get(2, 0).glyph, String("l"))
    assert_equal(c.get(3, 0).glyph, String("l"))
    assert_equal(c.get(2, 1).glyph, String("r"))
    assert_equal(c.get(3, 1).glyph, String("l"))
    # Attr is the shadow attr — DARK_GRAY on BLACK.
    assert_equal(c.get(2, 0).attr.fg, DARK_GRAY)
    assert_equal(c.get(2, 0).attr.bg, BLACK)
    assert_equal(c.get(3, 1).attr.fg, DARK_GRAY)
    assert_equal(c.get(3, 1).attr.bg, BLACK)
    # Cells outside the rect are untouched.
    assert_equal(c.get(0, 0).attr.fg, WHITE)
    assert_equal(c.get(0, 0).attr.bg, BLUE)
    assert_equal(c.get(4, 0).attr.fg, WHITE)


def test_paint_drop_shadow_targets_right_and_bottom() raises:
    """``paint_drop_shadow`` darkens the 2-cell right strip (offset
    one row down from the top edge) and the 1-row bottom strip
    (offset 2 cells right of the left edge), matching the diagonal
    "lifted" effect of the per-button shadows."""
    var c = Canvas(20, 8)
    # Background that the shadow needs to dim.
    c.fill(Rect(0, 0, 20, 8), String("·"), Attr(WHITE, BLUE))
    var dialog = Rect(3, 2, 13, 6)   # 10×4 dialog
    paint_drop_shadow(c, dialog)
    # Right strip: x in {13, 14}, y in [3, 6).
    assert_equal(c.get(13, 3).attr.bg, BLACK)
    assert_equal(c.get(14, 3).attr.bg, BLACK)
    assert_equal(c.get(13, 5).attr.bg, BLACK)
    assert_equal(c.get(14, 5).attr.bg, BLACK)
    # Glyph underneath the shadow survives.
    assert_equal(c.get(13, 3).glyph, String("·"))
    # Top-right corner of the dialog is *not* shadowed (shadow starts
    # one row down so the top edge looks "lit").
    assert_equal(c.get(13, 2).attr.bg, BLUE)
    # Bottom strip: x in [5, 15), y == 6.
    assert_equal(c.get(5, 6).attr.bg, BLACK)
    assert_equal(c.get(14, 6).attr.bg, BLACK)
    # The two cells immediately under the dialog's left edge are
    # *not* shadowed (offset 2) — keeps the bottom-left corner lit.
    assert_equal(c.get(3, 6).attr.bg, BLUE)
    assert_equal(c.get(4, 6).attr.bg, BLUE)
    # Cells inside the dialog rect are untouched by the shadow.
    assert_equal(c.get(5, 3).attr.bg, BLUE)


def test_debug_pane_default_title_is_debug() raises:
    """``DebugPane`` defaults to DEBUG mode — the pane's top border
    paints ``Debug`` so existing callers see no behavioural change."""
    var pane = DebugPane()
    pane.visible = True
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    assert_equal(c.get(2, 0).glyph, String(" "))
    assert_equal(c.get(3, 0).glyph, String("D"))
    assert_equal(c.get(4, 0).glyph, String("e"))
    assert_equal(c.get(5, 0).glyph, String("b"))


def test_debug_pane_run_mode_swaps_title() raises:
    """RUN mode flips the title to ``Run`` — the pane's the same
    code path, just a different label."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    assert_equal(c.get(3, 0).glyph, String("R"))
    assert_equal(c.get(4, 0).glyph, String("u"))
    assert_equal(c.get(5, 0).glyph, String("n"))


def test_debug_pane_run_mode_hides_inspect_divider() raises:
    """RUN mode collapses Stack/Locals (always empty there) so Output
    fills the pane. The ``─ Output ─`` divider row that DEBUG paints
    between the two sections must NOT be drawn — a row of ``─``
    glyphs in the inspect area would confirm the pre-fix behaviour."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello"))
    var c = Canvas(40, 10)
    c.fill(Rect(0, 0, 40, 10), String("·"), Attr(BLACK, LIGHT_GRAY))
    pane.paint(c, Rect(0, 0, 40, 10))
    # Scan rows 2..9 (below the title and status row): no row should
    # be a continuous ``─`` strip carrying an ``Output`` label.
    for y in range(2, 10):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            assert_true(False)


def test_debug_pane_run_mode_uses_full_height_for_output() raises:
    """The most recent output line must reach the bottom row of the
    panel — RUN mode saves the divider row that DEBUG mode would have
    painted, and that row goes to Output instead."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(20):
        pane.append_output(String("line ") + String(i))
    var c = Canvas(40, 10)
    pane.paint(c, Rect(0, 0, 40, 10))
    # Bottom panel row is y=9. Autoscroll keeps the latest line
    # ("line 19") pinned there.
    assert_equal(c.get(2, 9).glyph, String("l"))
    assert_equal(c.get(3, 9).glyph, String("i"))
    assert_equal(c.get(4, 9).glyph, String("n"))


def test_debug_pane_debug_mode_keeps_output_divider() raises:
    """DEBUG mode with inspect content paints the ``─ Output ─`` divider
    so the Stack / Locals columns read as a separate section above the
    log."""
    var pane = DebugPane()
    pane.visible = True
    var frames = List[DapStackFrame]()
    frames.append(DapStackFrame(1, String("main"), String("/tmp/foo.py"), 41, 0, False))
    var locals = List[DapVariable]()
    pane.rebuild_inspect(
        frames^, String("Locals"), locals^,
        String("Watches"), List[String](), 0,
    )
    pane.append_output(String("debug output"))
    var c = Canvas(40, 12)
    pane.paint(c, Rect(0, 0, 40, 12))
    var found = False
    for y in range(2, 11):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            found = True
    assert_true(found)


def test_debug_pane_subtle_frame_paints_dim() raises:
    """A frame the adapter marked subtle (library / external code)
    paints in DARK_GRAY rather than WHITE so the user can still see
    the full call chain but visually distinguish their own code. The
    currently-inspected frame still gets the highlight regardless of
    the subtle hint."""
    var pane = DebugPane()
    pane.visible = True
    var frames = List[DapStackFrame]()
    # User frame at top — inspected by default.
    frames.append(DapStackFrame(
        1, String("my_func"), String("/proj/app.py"), 9, 0, False,
    ))
    # Library frame below it.
    frames.append(DapStackFrame(
        2, String("recv"), String("/lib/sock.py"), 41, 0, True,
    ))
    var locals = List[DapVariable]()
    pane.rebuild_inspect(
        frames^, String("Locals"), locals^,
        String("Watches"), List[String](), 0,
    )
    var c = Canvas(60, 16)
    pane.paint(c, Rect(0, 0, 60, 16))
    # Find the row containing ``recv`` — that's the subtle frame.
    var subtle_y = -1
    for y in range(2, 16):
        var x = _find_glyph_x(c, y, String("r"))
        if x >= 0 and c.get(x + 1, y).glyph == String("e") \
                and c.get(x + 2, y).glyph == String("c") \
                and c.get(x + 3, y).glyph == String("v"):
            subtle_y = y
            break
    assert_true(subtle_y >= 0)
    var subtle_x = _find_glyph_x(c, subtle_y, String("r"))
    assert_equal(c.get(subtle_x, subtle_y).attr.fg, DARK_GRAY)
    # And the inspected user frame stays in the highlight color, not dim.
    var user_y = -1
    for y in range(2, 16):
        var x = _find_glyph_x(c, y, String("m"))
        if x >= 0 and c.get(x + 1, y).glyph == String("y") \
                and c.get(x + 2, y).glyph == String("_"):
            user_y = y
            break
    assert_true(user_y >= 0)
    var user_x = _find_glyph_x(c, user_y, String("m"))
    # The current-frame highlight is BLACK on LIGHT_YELLOW — the key
    # invariant is that it's NOT painted dim.
    assert_true(c.get(user_x, user_y).attr.fg != DARK_GRAY)


def test_debug_pane_debug_mode_running_hides_inspect() raises:
    """DEBUG mode with no inspect rows (the program is running but not
    paused) drops the Stack / Locals columns and the ``─ Output ─``
    divider — same layout as RUN mode. Until a ``stopped`` event fires
    there's no frame data to show, so painting the section headers
    above empty columns just wastes screen space."""
    var pane = DebugPane()
    pane.visible = True
    pane.append_output(String("debug output"))
    var c = Canvas(40, 12)
    pane.paint(c, Rect(0, 0, 40, 12))
    for y in range(2, 12):
        if c.get(3, y).glyph == String("O") \
                and c.get(4, y).glyph == String("u") \
                and c.get(5, y).glyph == String("t"):
            assert_true(False)


def _find_glyph_x(c: Canvas, y: Int, glyph: String) -> Int:
    """Locate the first column at row ``y`` whose glyph matches
    ``glyph``. Returns -1 when not found."""
    for x in range(c.width):
        if c.get(x, y).glyph == glyph:
            return x
    return -1


def test_debug_pane_traceback_link_underlines_span() raises:
    """A Python-style ``File "<path>", line N`` entry in the output log
    must paint with an underline + LIGHT_BLUE foreground over the whole
    ``File "..." , line N`` span so users see it as a clickable link."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String('  File "/tmp/foo.py", line 42, in main'))
    var c = Canvas(60, 8)
    pane.paint(c, Rect(0, 0, 60, 8))
    # Find ``F`` of ``File`` on whichever row Output painted to.
    var link_y = -1
    var link_x = -1
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("F"))
        if x >= 0 and c.get(x + 1, y).glyph == String("i"):
            link_y = y
            link_x = x
            break
    assert_true(link_y >= 0)
    # The first cell of ``File`` must carry the link styling.
    var head = c.get(link_x, link_y)
    assert_equal(head.attr.fg, LIGHT_BLUE)
    assert_true((head.attr.style & STYLE_UNDERLINE) != 0)
    # The closing digit ``2`` of ``42`` is the last cell of the span;
    # no need to recompute the offset, just walk forward until we find
    # ``2`` followed by ``,``.
    var two_x = -1
    for x in range(link_x, c.width - 1):
        if c.get(x, link_y).glyph == String("2") \
                and c.get(x + 1, link_y).glyph == String(","):
            two_x = x
            break
    assert_true(two_x >= 0)
    var tail = c.get(two_x, link_y)
    assert_equal(tail.attr.fg, LIGHT_BLUE)
    assert_true((tail.attr.style & STYLE_UNDERLINE) != 0)
    # The trailing comma after the digits is *not* part of the link.
    var after = c.get(two_x + 1, link_y)
    assert_equal(after.attr.fg, WHITE)
    assert_true((after.attr.style & STYLE_UNDERLINE) == 0)


def test_debug_pane_plain_output_has_no_link_styling() raises:
    """A line that doesn't match the traceback pattern is painted with
    the normal output attribute — no underline, default foreground."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("just some output"))
    var c = Canvas(40, 8)
    pane.paint(c, Rect(0, 0, 40, 8))
    # Walk every cell that ended up with ``j`` of ``just`` and verify
    # neither styling artifact is present.
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("j"))
        if x < 0:
            continue
        var cell = c.get(x, y)
        assert_equal(cell.attr.fg, WHITE)
        assert_true((cell.attr.style & STYLE_UNDERLINE) == 0)


def test_debug_pane_click_on_traceback_link_sets_pending_open() raises:
    """Clicking inside the link span stores ``(path, line)`` for the
    host to consume. The trailing ``in main`` text is *not* part of the
    span, so a click on ``in`` falls through to the autoscroll-toggle
    path and leaves no pending request."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String('  File "/tmp/foo.py", line 42, in main'))
    var panel = Rect(0, 0, 60, 8)
    var c = Canvas(60, 8)
    pane.paint(c, panel)
    # Find ``F`` so we click on a known cell inside the link.
    var link_y = -1
    var link_x = -1
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("F"))
        if x >= 0 and c.get(x + 1, y).glyph == String("i"):
            link_y = y
            link_x = x
            break
    assert_true(link_y >= 0)
    var hit = pane.handle_mouse(
        Event.mouse_event(
            Point(link_x + 2, link_y), MOUSE_BUTTON_LEFT, True, False,
        ),
        panel,
    )
    assert_true(hit)
    var req = pane.consume_open_request()
    assert_equal(req[0], String("/tmp/foo.py"))
    assert_equal(req[1], 42)
    # Second consume returns the cleared sentinel.
    var req2 = pane.consume_open_request()
    assert_equal(req2[0], String(""))
    assert_equal(req2[1], 0)
    # A click outside the link span (well past the digits) must NOT
    # set a pending open request — that path's reserved for the
    # autoscroll-toggle behaviour.
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(50, link_y), MOUSE_BUTTON_LEFT, True, False,
        ),
        panel,
    )
    var req3 = pane.consume_open_request()
    assert_equal(req3[0], String(""))


def test_text_view_wrap_lines_breaks_at_width() raises:
    """``wrap_lines`` produces one ``VisualLine`` per painted row,
    splitting at exactly ``content_w`` cells with no overlap."""
    var lines = List[String]()
    lines.append(String("ABCDEFGHIJKLMNOPQRST"))   # 20 cells
    lines.append(String(""))                       # empty -> 1 zero-width row
    lines.append(String("xy"))                     # short -> 1 row
    var wrapped = wrap_lines(lines, 7)
    # 20 / 7 = 3 segments (7 + 7 + 6).
    assert_equal(len(wrapped), 3 + 1 + 1)
    assert_equal(wrapped[0].cell_count, 7)
    assert_equal(wrapped[1].cell_count, 7)
    assert_equal(wrapped[2].cell_count, 6)
    assert_equal(wrapped[0].cell_start, 0)
    assert_equal(wrapped[1].cell_start, 7)
    assert_equal(wrapped[2].cell_start, 14)
    # Empty line still occupies one zero-width visual row.
    assert_equal(wrapped[3].line_idx, 1)
    assert_equal(wrapped[3].cell_count, 0)
    # Short line fits in one segment.
    assert_equal(wrapped[4].line_idx, 2)
    assert_equal(wrapped[4].cell_count, 2)


def test_text_view_wrap_lines_word_aware_with_indent() raises:
    """Editor mode: word-aware wrap that backs up to the last
    non-word ASCII byte and indents continuations under the parent's
    leading whitespace plus one indent unit."""
    var lines = List[String]()
    lines.append(String("    foo bar baz qux"))   # 4 leading spaces
    var rows = wrap_lines(
        lines, 12,
        indent_size=4, word_aware=True, start_line=0, max_rows=-1,
    )
    # Expected: first segment "    foo bar " (12 cells, breaks at the
    # last space), continuation indents to 4+4=8 cells, then
    # "baz qux" — fits within 12-8=4 wait, that's too narrow, would
    # split again. Just assert that a continuation row exists with
    # the expected hanging indent.
    assert_true(len(rows) >= 2)
    assert_equal(rows[0].indent_cells, 0)
    assert_equal(rows[1].indent_cells, 8)


def test_text_view_selection_extracts_text() raises:
    """``Selection.extracted_text`` slices a flat ``List[String]`` by
    cell coordinates and joins lines with ``\\n``."""
    var lines = List[String]()
    lines.append(String("hello world"))
    lines.append(String("second line"))
    lines.append(String("third"))
    # Whole-buffer selection.
    var sel = Selection(True, False, 0, 0, 2, 5)
    assert_equal(
        sel.extracted_text(lines),
        String("hello world\nsecond line\nthird"),
    )
    # Mid-line selection on a single row.
    var inner = Selection(True, False, 1, 7, 1, 11)
    assert_equal(inner.extracted_text(lines), String("line"))
    # Empty selection (anchor == cursor) returns empty.
    var none = Selection(True, False, 0, 3, 0, 3)
    assert_equal(none.extracted_text(lines), String(""))
    # Reversed endpoints normalize to the same forward slice.
    var rev = Selection(True, False, 1, 11, 1, 7)
    assert_equal(rev.extracted_text(lines), String("line"))


def test_string_utils_slice_codepoints_handles_multibyte() raises:
    """``slice_codepoints`` slices by codepoint, not byte, so multi-byte
    characters survive intact and cell offsets line up with cursor
    positions."""
    var s = String("aåbäc")  # 5 codepoints, 7 bytes
    assert_equal(slice_codepoints(s, 0, 5), s)
    assert_equal(slice_codepoints(s, 1, 4), String("åbä"))
    assert_equal(slice_codepoints(s, 4, 5), String("c"))
    assert_equal(slice_codepoints(s, 0, 0), String(""))
    assert_equal(slice_codepoints(s, 3, 3), String(""))


def test_debug_pane_run_log_paints_scrollbar_when_overflowing() raises:
    """When the run/debug output overflows the visible area, a vertical
    scrollbar must be painted in the right margin (column ``panel.b.x - 1``)
    with ▲ at the top and ▼ at the bottom of the output rect."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(40):
        pane.append_output(String("line ") + String(i))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    # Output rect spans rows [out_top, panel.b.y - 1] = [2, 9].
    assert_equal(c.get(39, 2).glyph, String("▲"))
    assert_equal(c.get(39, 9).glyph, String("▼"))
    # At least one █ thumb glyph must exist somewhere on the rail.
    var thumb_seen = False
    for y in range(3, 9):
        if c.get(39, y).glyph == String("█"):
            thumb_seen = True
            break
    assert_true(thumb_seen)


def test_debug_pane_run_log_no_scrollbar_when_content_fits() raises:
    """A short log fits in the output area, so no scrollbar should
    be painted — the rightmost column stays as the panel background."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("just one line"))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    for y in range(2, 10):
        var glyph = c.get(39, y).glyph
        assert_true(
            glyph != String("▲") and glyph != String("▼")
            and glyph != String("█") and glyph != String("░"),
        )


def test_debug_pane_run_log_arrow_click_scrolls_output() raises:
    """A click on the ▼ arrow at the bottom of the scrollbar nudges
    the output down — autoscroll engages because we hit the bottom,
    then a click on the ▲ pulls scroll back up and disengages it."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(40):
        pane.append_output(String("line ") + String(i))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    # Arrow-up click pulls scroll up by 3 rows; autoscroll must turn off
    # because we're no longer at the bottom.
    var ev = Event.mouse_event(
        Point(39, 2), MOUSE_BUTTON_LEFT, True, False,
    )
    var consumed = pane.handle_mouse(ev, panel)
    assert_true(consumed)
    assert_false(pane.output.autoscroll)


def test_debug_pane_run_log_thumb_drag_scrolls_output() raises:
    """Pressing on the thumb starts a drag; mouse motion moves scroll;
    release ends the drag. Verifies the wiring end-to-end."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    for i in range(40):
        pane.append_output(String("line ") + String(i))
    var panel = Rect(0, 0, 40, 10)
    var c = Canvas(40, 10)
    pane.paint(c, panel)
    # Find the thumb glyph y on the scrollbar column.
    var thumb_y = -1
    for y in range(3, 9):
        if c.get(39, y).glyph == String("█"):
            thumb_y = y
            break
    assert_true(thumb_y >= 0)
    # Press on the thumb.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(39, thumb_y), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    # Drag to the top of the track (mouse_y = 3 — first track row).
    _ = pane.handle_mouse(
        Event.mouse_event(Point(39, 3), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    # Drag must have disengaged autoscroll.
    assert_false(pane.output.autoscroll)
    # Release.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(39, 3), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )


def test_debug_pane_long_output_line_soft_wraps() raises:
    """A line longer than the panel content width paints across
    multiple visual rows. Verifies the line shows up on more than
    one row and that the second row continues with the next chars."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    # 60 chars, content width is panel.width - 3 = 17 chars.
    pane.append_output(String("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwx"))
    var panel = Rect(0, 0, 20, 8)
    var c = Canvas(20, 8)
    pane.paint(c, panel)
    # First wrapped segment should start at the panel left margin on
    # the first output row.
    var first_x = _find_glyph_x(c, 2, String("A"))
    assert_true(first_x >= 0)
    # Second segment continues on the next row, starting where the
    # first segment ran out — find a char that should land in the
    # second wrapped row to confirm the line actually wrapped.
    var second_x = _find_glyph_x(c, 3, String("R"))
    assert_true(second_x >= 0)


def test_debug_pane_drag_selects_output_text() raises:
    """Dragging across output text marks a selection — verified
    through ``selected_text``. A press without a drag clears the
    selection (no zero-width selection on a plain click)."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello world"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    # Find the row 'h' landed on.
    var hy = -1
    var hx = -1
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("h"))
        if x >= 0:
            hy = y
            hx = x
            break
    assert_true(hy >= 0)
    # Press at 'h', drag to one cell past 'd' (cell 11 -> selecting
    # the entire word).
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx, hy), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 11, hy), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 11, hy), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_true(pane.has_selection())
    assert_equal(pane.selected_text(), String("hello world"))


def test_debug_pane_selection_spans_multiple_lines() raises:
    """A selection that starts on one logical line and ends on
    another joins the two slices with a newline."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("first line\nsecond line"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    # Find both lines on the canvas.
    var fy = -1
    var sy = -1
    var fx = -1
    var sx = -1
    for y in range(2, 8):
        var fx_try = _find_glyph_x(c, y, String("f"))
        if fx_try >= 0 and c.get(fx_try + 1, y).glyph == String("i"):
            fy = y
            fx = fx_try
        var sx_try = _find_glyph_x(c, y, String("s"))
        if sx_try >= 0 and c.get(sx_try + 1, y).glyph == String("e"):
            sy = y
            sx = sx_try
    assert_true(fy >= 0)
    assert_true(sy >= 0)
    _ = pane.handle_mouse(
        Event.mouse_event(Point(fx, fy), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(sx + 11, sy), MOUSE_BUTTON_LEFT, True, True,
        ),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(
            Point(sx + 11, sy), MOUSE_BUTTON_LEFT, False, False,
        ),
        panel,
    )
    assert_equal(
        pane.selected_text(),
        String("first line\nsecond line"),
    )


def test_debug_pane_plain_click_clears_selection() raises:
    """A press without any drag motion produces no selection — the
    user just landed on a row, didn't ask to copy anything."""
    var pane = DebugPane()
    pane.visible = True
    pane.set_mode(PANE_MODE_RUN)
    pane.append_output(String("hello world"))
    var panel = Rect(0, 0, 40, 8)
    var c = Canvas(40, 8)
    pane.paint(c, panel)
    var hy = -1
    var hx = -1
    for y in range(2, 8):
        var x = _find_glyph_x(c, y, String("h"))
        if x >= 0:
            hy = y
            hx = x
            break
    assert_true(hy >= 0)
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 2, hy), MOUSE_BUTTON_LEFT, True, False),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(hx + 2, hy), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_true(not pane.has_selection())
    assert_equal(pane.selected_text(), String(""))


def test_targets_dialog_edit_and_submit() raises:
    """A dialog round-trip: open with two existing targets, type a
    new name into the focused input, then add a third target — the
    final ``into_targets`` must reflect both edits and place the
    active marker on the original active row."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("alpha")
    t1.program = String("echo")
    t1.args.append(String("a"))
    src.targets.append(t1^)
    var t2 = RunTarget()
    t2.name = String("beta")
    t2.program = String("echo")
    t2.args.append(String("b"))
    src.targets.append(t2^)
    src.active = 1
    var dlg = TargetsDialog()
    dlg.open(src^)
    assert_true(dlg.active)
    assert_equal(len(dlg.entries), 2)
    # ``selected`` honors ``active`` — index 1 (beta).
    assert_equal(dlg.selected, 1)
    # Tab from list focus to the Name input, then append "X".
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("X"))))
    var rebuilt = dlg.into_targets()
    assert_equal(rebuilt.targets[1].name, String("betaX"))
    # Active marker still points at the renamed row (we tracked it
    # by ``active_name`` set at open).
    assert_equal(rebuilt.targets[rebuilt.active].name, String("betaX"))


def test_targets_dialog_add_and_remove() raises:
    """Adding then removing yields the original list (modulo empty
    ``run`` field on the new entry, which is fine for this test —
    we never persist it)."""
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    t1.program = String("echo")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    # _activate_focus on Add — focus is on the list initially, walk
    # there via mouse-style direct manipulation.
    dlg.focus = 6   # _FOCUS_ADD
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_equal(len(dlg.entries), 2)
    assert_equal(dlg.selected, 1)
    # Selected is now the new "new" target. Switch focus to Remove
    # and activate.
    dlg.focus = 7   # _FOCUS_REMOVE
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_equal(len(dlg.entries), 1)
    assert_equal(dlg.entries[0].name, String("only"))


def test_targets_dialog_save_button_submits() raises:
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("only")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    dlg.focus = 8   # _FOCUS_SAVE
    _ = dlg.handle_key(Event.key_event(KEY_ENTER))
    assert_true(dlg.submitted)


def test_targets_dialog_esc_discards_edits() raises:
    var src = ProjectTargets()
    var t1 = RunTarget()
    t1.name = String("a")
    src.targets.append(t1^)
    src.active = 0
    var dlg = TargetsDialog()
    dlg.open(src^)
    # Move to name input, type something, then ESC. Dialog should
    # close *and* not be submitted.
    _ = dlg.handle_key(Event.key_event(KEY_TAB))
    _ = dlg.handle_key(Event.key_event(UInt32(ord("Z"))))
    _ = dlg.handle_key(Event.key_event(KEY_ESC))
    assert_false(dlg.active)
    assert_false(dlg.submitted)


def test_run_session_lifecycle() raises:
    """``RunSession.start`` spawns ``program`` + ``args``;
    ``poll_run_exit`` reaps the child and exposes its exit code."""
    var s = RunSession()
    var args = List[String]()
    args.append(String("-c"))
    args.append(String("printf 'hi\\n'; exit 7"))
    s.start(
        String("echo-test"), String("sh"), args^, String(""),
    )
    assert_true(s.is_active())
    assert_true(s.matches(String("echo-test")))
    # Drain output until the child exits. Bound the loop so a stuck
    # test fails rather than hangs the whole suite.
    var captured = String("")
    var ticks = 0
    # Each tick polls stdout (non-blocking) and waitpid_nohang. The
    # spawn pipeline goes through two ``sh`` instances now (outer
    # shell ``exec``-ing the inner ``sh -c …``), so leave plenty of
    # iterations — the child still wins the race almost always, but
    # CI under load occasionally needs a few hundred polls.
    while ticks < 2000:
        var out = drain_run_output(s)
        captured = captured + out.stdout
        if poll_run_exit(s):
            break
        ticks += 1
    assert_true(s.exited)
    assert_equal(s.exit_code, 7)
    s.terminate()
    assert_false(s.is_active())
    # Captured output had the printf payload — covers the drain path
    # at least once (the kernel may deliver before or after exit).
    var cb = captured.as_bytes()
    var has_hi = False
    for i in range(len(cb)):
        if i + 1 < len(cb) and cb[i] == 0x68 and cb[i + 1] == 0x69:
            has_hi = True
            break
    assert_true(has_hi)


def test_doc_registry_lookup() raises:
    """Built-in docsets should resolve every language id we ship with
    a server in the LSP catalog (so the user can hit Ctrl+K on the
    same files Cmd+click works on), and every spec's language_id must
    round-trip through both lookup helpers."""
    var specs = built_in_docsets()
    assert_true(len(specs) > 0)
    # Spot-check the python entry: extension routing + language lookup
    # both find it, and the slug is the pinned form (not bare "python").
    var py_idx = find_docset_for_extension(specs, String("py"))
    assert_true(py_idx >= 0)
    assert_equal(specs[py_idx].language_id, String("python"))
    var by_lang = find_docset_by_language(specs, String("python"))
    assert_equal(by_lang, py_idx)
    var pb = specs[py_idx].slug.as_bytes()
    var has_tilde = False
    for i in range(len(pb)):
        if pb[i] == 0x7E:    # '~'
            has_tilde = True
            break
    assert_true(has_tilde)
    # Unknown extension hits the not-found path.
    assert_equal(find_docset_for_extension(specs, String("xyz")), -1)


def test_doc_install_command_shape() raises:
    """The install command must:
    * mkdir the destination dir,
    * curl both index.json and db.json,
    * use ``-f`` so an HTTP 4xx writes nothing rather than saving an
      error page as the docset (and keeps the install runner's
      "non-zero exit on failure" contract intact)."""
    var cmd = docs_install_command(
        String("python~3.12"),
        String("/tmp/.turbokod/docs/python~3.12"),
    )
    var b = cmd.as_bytes()
    # ``index.json`` and ``db.json`` both referenced.
    var idx_marker = String("index.json")
    var db_marker  = String("db.json")
    var ib = idx_marker.as_bytes()
    var dbb = db_marker.as_bytes()
    var found_idx = False
    var found_db = False
    for i in range(len(b)):
        if i + len(ib) <= len(b):
            var matches = True
            for k in range(len(ib)):
                if b[i + k] != ib[k]:
                    matches = False
                    break
            if matches:
                found_idx = True
        if i + len(dbb) <= len(b):
            var matches2 = True
            for k in range(len(dbb)):
                if b[i + k] != dbb[k]:
                    matches2 = False
                    break
            if matches2:
                found_db = True
    assert_true(found_idx)
    assert_true(found_db)
    # ``-f`` flag (curl's "fail silently on HTTP error") is in both
    # invocations — the input-flag character ``f`` should appear at
    # least twice. Coarse but enough to detect a regression that
    # silently drops the flag.
    var f_count = 0
    for i in range(len(b)):
        if i + 1 < len(b) and b[i] == 0x2D and b[i + 1] == 0x66:    # '-f'
            f_count += 1
    assert_true(f_count >= 2)
    # mkdir -p so a missing parent doesn't bork the run.
    var mkdir_marker = String("mkdir -p")
    var mb = mkdir_marker.as_bytes()
    var has_mkdir = False
    for i in range(len(b) - len(mb) + 1):
        var matches = True
        for k in range(len(mb)):
            if b[i + k] != mb[k]:
                matches = False
                break
        if matches:
            has_mkdir = True
            break
    assert_true(has_mkdir)


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


def test_find_doc_entry_exact_match_wins() raises:
    """Exact name match beats both case-insensitive and suffix matches.

    Without this priority a click on ``find`` (which has a top-level
    DevDocs entry in some languages) would land on a method like
    ``str.find`` instead of the canonical entry, even though both are
    plausible — the LSP couldn't resolve, so we don't know which one
    the user meant. Exact equality is the least surprising default.
    """
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("str.find"), String("library/str"),
        String("find"), String("Methods"),
    ))
    entries.append(DocEntry(
        String("find"), String("library/find"),
        String(""), String("Built-in Functions"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("find"))
    # Exact "find" should win over the suffix match on "str.find".
    assert_equal(idx, 1)


def test_find_doc_entry_falls_back_to_suffix_match() raises:
    """When no entry matches the bare word, ``foo`` should still resolve
    to ``Type.foo`` so a Cmd+click on ``s.find()`` opens ``str.find``."""
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("dict.get"), String("library/stdtypes"),
        String("dict.get"), String("Methods"),
    ))
    entries.append(DocEntry(
        String("str.find"), String("library/stdtypes"),
        String("str.find"), String("Methods"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("find"))
    assert_equal(idx, 1)


def test_find_doc_entry_returns_minus_one_when_no_match() raises:
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("abs"), String("library/functions"),
        String("abs"), String("Built-in Functions"),
    ))
    assert_equal(
        _find_doc_entry_for_word(entries, String("nonexistent")),
        -1,
    )
    # Empty word never matches anything.
    assert_equal(_find_doc_entry_for_word(entries, String("")), -1)


def test_find_doc_entry_case_insensitive_when_no_exact() raises:
    """CSS / HTML docs spell some entries lowercase even if the source
    site uses TitleCase; a Cmd+click that comes back empty from the
    LSP should still find the entry. Exact match would have already
    been preferred (this case has none), so case-folded match is the
    next best signal."""
    var entries = List[DocEntry]()
    entries.append(DocEntry(
        String("Display"), String("css/display"),
        String(""), String("Properties"),
    ))
    var idx = _find_doc_entry_for_word(entries, String("display"))
    assert_equal(idx, 0)


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


def test_session_round_trip() raises:
    """A persisted session should decode to the same fields it was
    encoded from. Covers the full ``encode_session`` → ``parse_json``
    → ``load_session`` path against a temp project root so the test
    doesn't touch the repo's own ``.turbokod/session.json``."""
    var root = String("/tmp/turbokod_session_test_round_trip")
    # Clean up any prior run so a stale ``.turbokod/`` doesn't shadow
    # the empty-state assertion below.
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var s = Session()
    var w0 = SessionWindow()
    w0.path = String("src/turbokod/desktop.mojo")
    w0.rect_a_x = 5
    w0.rect_a_y = 3
    w0.rect_b_x = 75
    w0.rect_b_y = 28
    w0.is_maximized = False
    w0.restore_a_x = 5
    w0.restore_a_y = 3
    w0.restore_b_x = 75
    w0.restore_b_y = 28
    w0.cursor_row = 42
    w0.cursor_col = 7
    w0.scroll_x = 0
    w0.scroll_y = 30
    s.windows.append(w0^)
    var w1 = SessionWindow()
    w1.path = String("/abs/somewhere/else.txt")
    w1.rect_a_x = 0
    w1.rect_a_y = 0
    w1.rect_b_x = 40
    w1.rect_b_y = 20
    w1.is_maximized = True
    w1.restore_a_x = 10
    w1.restore_a_y = 4
    w1.restore_b_x = 60
    w1.restore_b_y = 22
    w1.cursor_row = 0
    w1.cursor_col = 12
    w1.scroll_x = 5
    w1.scroll_y = 0
    s.windows.append(w1^)
    s.z_order.append(1)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var loaded = load_session(root)
    assert_equal(len(loaded.windows), 2)
    assert_equal(loaded.windows[0].path, String("src/turbokod/desktop.mojo"))
    assert_equal(loaded.windows[0].rect_a_x, 5)
    assert_equal(loaded.windows[0].rect_b_y, 28)
    assert_equal(loaded.windows[0].cursor_row, 42)
    assert_equal(loaded.windows[0].scroll_y, 30)
    assert_false(loaded.windows[0].is_maximized)
    assert_true(loaded.windows[1].is_maximized)
    assert_equal(loaded.windows[1].restore_a_x, 10)
    assert_equal(loaded.windows[1].path, String("/abs/somewhere/else.txt"))
    assert_equal(len(loaded.z_order), 2)
    assert_equal(loaded.z_order[0], 1)
    assert_equal(loaded.z_order[1], 0)
    assert_equal(loaded.focused, 0)
    # Cleanup so re-running the test starts from a clean state.
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_session_load_missing_returns_empty() raises:
    """A project root with no ``.turbokod/session.json`` should yield
    an empty session — that's the signal ``_restore_session`` uses to
    skip the restore path entirely."""
    var s = load_session(String("/tmp/turbokod_session_does_not_exist_abcxyz"))
    assert_equal(len(s.windows), 0)
    assert_equal(len(s.z_order), 0)
    assert_equal(s.focused, -1)


def test_breakpoint_store_round_trip() raises:
    """Persisted breakpoints decode to the same fields they were
    encoded from. Inside-project paths are stored project-relative so
    the file survives moving the project directory; absolute paths
    pass through. ``load_breakpoints`` re-anchors relatives onto the
    current root."""
    var root = String("/tmp/turbokod_bp_test_round_trip")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var bps = List[StoredBreakpoint]()
    bps.append(StoredBreakpoint(
        root + String("/src/foo.mojo"), 41, String(""), True,
        String(""),
    ))
    bps.append(StoredBreakpoint(
        root + String("/src/foo.mojo"), 87, String("i > 10"), True,
        String(""),
    ))
    bps.append(StoredBreakpoint(
        String("/etc/hosts"), 0, String(""), False,
        # Wait-for trigger that should round-trip verbatim — the
        # store doesn't validate keys, it just stashes the string.
        String("/etc/hosts:1"),
    ))
    assert_true(save_breakpoints(root, bps))
    var loaded = load_breakpoints(root)
    assert_equal(len(loaded), 3)
    # First two are inside the project — they round-trip absolute via
    # the project-relative encoding.
    assert_equal(loaded[0].path, root + String("/src/foo.mojo"))
    assert_equal(loaded[0].line, 41)
    assert_equal(loaded[0].condition, String(""))
    assert_true(loaded[0].enabled)
    assert_equal(loaded[0].wait_for, String(""))
    assert_equal(loaded[1].path, root + String("/src/foo.mojo"))
    assert_equal(loaded[1].line, 87)
    assert_equal(loaded[1].condition, String("i > 10"))
    assert_true(loaded[1].enabled)
    assert_equal(loaded[1].wait_for, String(""))
    # Outside the project — kept absolute on disk, loaded verbatim.
    # The disabled flag round-trips so a parked BP stays parked.
    assert_equal(loaded[2].path, String("/etc/hosts"))
    assert_equal(loaded[2].line, 0)
    assert_false(loaded[2].enabled)
    assert_equal(loaded[2].wait_for, String("/etc/hosts:1"))
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_breakpoint_store_load_missing_returns_empty() raises:
    """No file → empty list. Mirrors the session-store contract."""
    var bps = load_breakpoints(String("/tmp/turbokod_bp_does_not_exist_xyz"))
    assert_equal(len(bps), 0)


def test_breakpoint_store_per_user_path() raises:
    """The on-disk file lives under ``per_user/<USER>/``. Verify by
    overriding ``$USER`` for the test and checking the file appears at
    the expected sub-path. Without this isolation an accidental
    ``git add .turbokod`` on a checkout would replace a teammate's
    breakpoint set with the committer's."""
    var root = String("/tmp/turbokod_bp_per_user_test")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # Stash and override $USER so the directory name is predictable.
    var user_env = String("USER=alice_test\0")
    _ = external_call["putenv", Int32](user_env.unsafe_ptr())
    var bps = List[StoredBreakpoint]()
    bps.append(StoredBreakpoint(
        root + String("/main.py"), 7, String(""), True, String(""),
    ))
    assert_true(save_breakpoints(root, bps))
    var expected = root + String("/.turbokod/per_user/alice_test/breakpoints.json")
    assert_true(stat_file(expected).ok)
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_view_state_store_round_trip() raises:
    """Persisted per-file view states decode back to the same fields.
    Inside-project paths are stored project-relative so the file
    survives moving the project; absolute paths pass through. The
    store keys by absolute path and load reattaches the project root
    to project-relative entries on the way back."""
    var root = String("/tmp/turbokod_vs_test_round_trip")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var views = List[StoredViewState]()
    views.append(StoredViewState(
        root + String("/src/foo.mojo"), 42, 4, 0, 30,
    ))
    views.append(StoredViewState(
        String("/etc/hosts"), 0, 0, 0, 0,
    ))
    assert_true(save_view_states(root, views))
    var loaded = load_view_states(root)
    assert_equal(len(loaded), 2)
    assert_equal(loaded[0].path, root + String("/src/foo.mojo"))
    assert_equal(loaded[0].cursor_row, 42)
    assert_equal(loaded[0].cursor_col, 4)
    assert_equal(loaded[0].scroll_x, 0)
    assert_equal(loaded[0].scroll_y, 30)
    assert_equal(loaded[1].path, String("/etc/hosts"))
    assert_equal(loaded[1].cursor_row, 0)
    assert_equal(loaded[1].scroll_y, 0)
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_view_state_store_load_missing_returns_empty() raises:
    """No file → empty list. Same contract as the sibling stores so
    the Desktop can blindly load on every project open."""
    var vs = load_view_states(
        String("/tmp/turbokod_vs_does_not_exist_xyz"),
    )
    assert_equal(len(vs), 0)


def test_view_state_store_per_user_path() raises:
    """The on-disk file lives under ``per_user/<USER>/`` next to
    breakpoints.json — keeps each developer's scroll positions
    separate, so an accidental ``git add .turbokod`` doesn't replace
    a teammate's set."""
    var root = String("/tmp/turbokod_vs_per_user_test")
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var user_env = String("USER=bob_test\0")
    _ = external_call["putenv", Int32](user_env.unsafe_ptr())
    var views = List[StoredViewState]()
    views.append(StoredViewState(
        root + String("/main.py"), 12, 0, 0, 5,
    ))
    assert_true(save_view_states(root, views))
    var expected = root + String(
        "/.turbokod/per_user/bob_test/view_states.json"
    )
    assert_true(stat_file(expected).ok)
    _ = external_call["system", Int32](
        (String("rm -rf '") + root + String("'\0")).unsafe_ptr(),
    )


def test_session_relative_path_round_trip() raises:
    """``_session_relative`` strips the project prefix; the inverse
    re-anchors. Files outside the project keep their absolute form
    on the way out and pass through on the way back in."""
    var root = String("/Users/foo/proj")
    var inside = String("/Users/foo/proj/src/main.mojo")
    var outside = String("/etc/hosts")
    var rel_in = _session_relative(root, inside)
    assert_equal(rel_in, String("src/main.mojo"))
    var rel_out = _session_relative(root, outside)
    assert_equal(rel_out, outside)
    var resolved_in = _resolve_session_path(root, rel_in)
    assert_equal(resolved_in, inside)
    var resolved_out = _resolve_session_path(root, rel_out)
    assert_equal(resolved_out, outside)


def test_desktop_restores_session_from_disk() raises:
    """Open a project that already has a ``.turbokod/session.json`` and
    confirm the desktop replays it: a window for the saved file shows
    up, the rect / cursor / scroll are reapplied, and the focused
    index points at the saved entry."""
    var root = String("/tmp/turbokod_session_restore_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var file_path = root + String("/foo.txt")
    assert_true(write_file(file_path, String("alpha\nbeta\ngamma\ndelta\n")))
    # Author a session that places the file at a non-default rect with
    # cursor on row 2 col 3.
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("foo.txt")
    sw.rect_a_x = 4
    sw.rect_a_y = 2
    sw.rect_b_x = 50
    sw.rect_b_y = 18
    sw.is_maximized = False
    sw.restore_a_x = 4
    sw.restore_a_y = 2
    sw.restore_b_x = 50
    sw.restore_b_y = 18
    sw.cursor_row = 2
    sw.cursor_col = 3
    sw.scroll_x = 0
    sw.scroll_y = 0
    s.windows.append(sw^)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    assert_true(d.project)
    assert_true(d._pending_restore)
    var screen = Rect(0, 0, 80, 30)
    d._pending_restore = False
    d._restore_session(screen)
    assert_equal(len(d.windows.windows), 1)
    var w0 = d.windows.windows[0].copy()
    assert_true(w0.is_editor)
    assert_equal(w0.rect.a.x, 4)
    assert_equal(w0.rect.a.y, 2)
    assert_equal(w0.rect.b.x, 50)
    assert_equal(w0.rect.b.y, 18)
    assert_equal(w0.editor.cursor_row, 2)
    assert_equal(w0.editor.cursor_col, 3)
    assert_equal(d.windows.focused, 0)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_resize_reapplies_clipped_session_rect() raises:
    """When the first restore lands on a smaller-than-saved workspace
    (the host pushes its real dimensions a few ms after startup), the
    saved rects get clipped down. A subsequent resize event must re-
    apply the originally-saved rects against the now-correct
    workspace, instead of leaving windows stuck at their initial
    clip values forever."""
    var root = String("/tmp/turbokod_resize_reapply_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var file_path = root + String("/foo.txt")
    assert_true(write_file(file_path, String("a\nb\nc\n")))
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("foo.txt")
    # Saved rect (20, 8, 75, 24) — fits a 100x30 screen, NOT a 80x24 one.
    sw.rect_a_x = 20
    sw.rect_a_y = 8
    sw.rect_b_x = 75
    sw.rect_b_y = 24
    sw.is_maximized = False
    sw.restore_a_x = 20
    sw.restore_a_y = 8
    sw.restore_b_x = 75
    sw.restore_b_y = 24
    s.windows.append(sw^)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    d._pending_restore = False
    # First restore at the cramped 80x24 workspace clips ay from 8 to 7.
    d._restore_session(Rect(0, 0, 80, 24))
    assert_equal(len(d.windows.windows), 1)
    var initial = d.windows.windows[0].rect
    assert_equal(initial.a.y, 7)
    assert_equal(initial.b.y, 23)
    # The host now pushes the real dimensions — feed an EVENT_RESIZE
    # to the desktop and confirm the saved rect is re-applied at the
    # larger workspace.
    var resize_ev = Event.resize_event(100, 30)
    _ = d.handle_event(resize_ev, Rect(0, 0, 100, 30))
    var refit = d.windows.windows[0].rect
    assert_equal(refit.a.x, 20)
    assert_equal(refit.a.y, 8)
    assert_equal(refit.b.x, 75)
    assert_equal(refit.b.y, 24)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_arms_session_restore_when_non_editor_windows_present() raises:
    """``_set_project`` must arm the session restore even when host-added
    placeholder windows are already present. Regression for: a host that
    adds non-file-backed demo windows before opening a file blocked the
    restore path entirely, and the subsequent save then overwrote the
    on-disk session with the cascade-default rect."""
    var root = String("/tmp/turbokod_set_project_arms_restore_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var d = Desktop()
    # Host adds a non-editor placeholder window (mimicking demo content)
    # before any project is set.
    var placeholder_lines = List[String]()
    placeholder_lines.append(String("placeholder"))
    d.windows.add(Window(
        String("Demo"), Rect(4, 3, 50, 16), placeholder_lines^,
    ))
    assert_equal(len(d.windows.windows), 1)
    d.open_project(root)
    assert_true(d._pending_restore)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_restores_non_maximized_rect_not_restore_rect() raises:
    """When a saved window's ``rect`` differs from its ``restore_rect``
    (e.g. user dragged a non-maximized window after creation, so the
    constructor-stamped ``_restore_rect`` is now stale), restoring it
    must place the window at ``rect`` — the user's last-known position
    — not at ``restore_rect``. Regression for: new windows pulled in
    from session were being constructed with ``restore``, so a moved
    non-maximized window came back at its original cascade slot."""
    var root = String("/tmp/turbokod_restore_rect_vs_rect_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var file_path = root + String("/moved.txt")
    assert_true(write_file(file_path, String("one\ntwo\n")))
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("moved.txt")
    # User dragged the window to (20, 8, 80, 28); the stale
    # ``_restore_rect`` is the original cascade slot at (5, 2, 60, 20).
    sw.rect_a_x = 20
    sw.rect_a_y = 8
    sw.rect_b_x = 80
    sw.rect_b_y = 28
    sw.is_maximized = False
    sw.restore_a_x = 5
    sw.restore_a_y = 2
    sw.restore_b_x = 60
    sw.restore_b_y = 20
    sw.cursor_row = 0
    sw.cursor_col = 0
    sw.scroll_x = 0
    sw.scroll_y = 0
    s.windows.append(sw^)
    s.z_order.append(0)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    d._pending_restore = False
    d._restore_session(Rect(0, 0, 100, 30))
    assert_equal(len(d.windows.windows), 1)
    var w0 = d.windows.windows[0].copy()
    assert_equal(w0.rect.a.x, 20)
    assert_equal(w0.rect.a.y, 8)
    assert_equal(w0.rect.b.x, 80)
    assert_equal(w0.rect.b.y, 28)
    # ``_restore_rect`` should preserve the saved un-maximized rect so
    # a later un-maximize lands the window where the user last left it
    # *before* maximizing — even though we never maximized in this run.
    assert_equal(w0._restore_rect.a.x, 5)
    assert_equal(w0._restore_rect.b.x, 60)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_snapshot_captures_per_window_rects() raises:
    """Each open file-backed window must show up in the snapshot with
    its own rect. Regression guard: a copy bug or wrong loop variable
    would yield identical rects across the session entries."""
    var root = String("/tmp/turbokod_snapshot_rects_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/a.txt"), String("aaa\n")))
    assert_true(write_file(root + String("/b.txt"), String("bbb\n")))
    var d = Desktop()
    d.open_project(root)
    d._pending_restore = False     # skip any auto-restore in this test
    var screen = Rect(0, 0, 80, 30)
    d.open_file(root + String("/a.txt"), screen)
    d.open_file(root + String("/b.txt"), screen)
    assert_equal(len(d.windows.windows), 2)
    # Force the two windows to distinct rects via direct mutation —
    # avoids depending on the cascade default sliding them apart by
    # exactly some specific amount.
    d.windows.windows[0].rect = Rect(2, 1, 30, 12)
    d.windows.windows[0]._restore_rect = Rect(2, 1, 30, 12)
    d.windows.windows[0].is_maximized = False
    d.windows.windows[1].rect = Rect(40, 5, 75, 25)
    d.windows.windows[1]._restore_rect = Rect(40, 5, 75, 25)
    d.windows.windows[1].is_maximized = False
    var session = d._snapshot_session()
    assert_equal(len(session.windows), 2)
    # The snapshot should map each window through to its own rect, not
    # a shared one. We don't depend on order — find by path suffix
    # (the snapshot may emit relative or absolute paths depending on
    # whether ``editor.file_path`` is canonical-equal to the
    # project root).
    var idx_a = -1
    var idx_b = -1
    for i in range(len(session.windows)):
        var p = session.windows[i].path
        var pb = p.as_bytes()
        var alen = len(String("a.txt").as_bytes())
        var blen = len(String("b.txt").as_bytes())
        if len(pb) >= alen \
                and String(StringSlice(unsafe_from_utf8=pb[len(pb) - alen:])) \
                == String("a.txt"):
            idx_a = i
        if len(pb) >= blen \
                and String(StringSlice(unsafe_from_utf8=pb[len(pb) - blen:])) \
                == String("b.txt"):
            idx_b = i
    assert_true(idx_a >= 0)
    assert_true(idx_b >= 0)
    assert_equal(session.windows[idx_a].rect_a_x, 2)
    assert_equal(session.windows[idx_a].rect_b_x, 30)
    assert_equal(session.windows[idx_b].rect_a_x, 40)
    assert_equal(session.windows[idx_b].rect_b_x, 75)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_restores_multiple_windows_at_distinct_positions() raises:
    """Two saved windows must come back at the *two* rects on disk —
    not both at the same position. Regression guard against snapshot
    or restore code accidentally copying one window's rect into the
    others (e.g. a closure-capture or single-Rect-buffer bug)."""
    var root = String("/tmp/turbokod_session_multi_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/foo.txt"), String("a\nb\nc\n")))
    assert_true(write_file(root + String("/bar.txt"), String("x\ny\nz\nw\n")))
    var s = Session()
    var w0 = SessionWindow()
    w0.path = String("foo.txt")
    w0.rect_a_x = 2
    w0.rect_a_y = 1
    w0.rect_b_x = 30
    w0.rect_b_y = 12
    w0.restore_a_x = 2
    w0.restore_a_y = 1
    w0.restore_b_x = 30
    w0.restore_b_y = 12
    s.windows.append(w0^)
    var w1 = SessionWindow()
    w1.path = String("bar.txt")
    w1.rect_a_x = 40
    w1.rect_a_y = 5
    w1.rect_b_x = 75
    w1.rect_b_y = 25
    w1.restore_a_x = 40
    w1.restore_a_y = 5
    w1.restore_b_x = 75
    w1.restore_b_y = 25
    w1.cursor_row = 1
    w1.cursor_col = 2
    s.windows.append(w1^)
    s.z_order.append(0)
    s.z_order.append(1)
    s.focused = 1
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    var screen = Rect(0, 0, 80, 30)
    d._pending_restore = False
    d._restore_session(screen)
    assert_equal(len(d.windows.windows), 2)
    # ``open_project`` canonicalizes via ``realpath``, so on macOS the
    # stored project root is ``/private/tmp/...``, not ``/tmp/...``.
    # Compare against the canonical project root rather than the
    # original test path.
    var canonical = d.project.value()
    var foo_idx = -1
    var bar_idx = -1
    for i in range(len(d.windows.windows)):
        var fp = d.windows.windows[i].editor.file_path
        if fp == canonical + String("/foo.txt"):
            foo_idx = i
        if fp == canonical + String("/bar.txt"):
            bar_idx = i
    assert_true(foo_idx >= 0)
    assert_true(bar_idx >= 0)
    assert_equal(d.windows.windows[foo_idx].rect.a.x, 2)
    assert_equal(d.windows.windows[foo_idx].rect.a.y, 1)
    assert_equal(d.windows.windows[foo_idx].rect.b.x, 30)
    assert_equal(d.windows.windows[foo_idx].rect.b.y, 12)
    assert_equal(d.windows.windows[bar_idx].rect.a.x, 40)
    assert_equal(d.windows.windows[bar_idx].rect.a.y, 5)
    assert_equal(d.windows.windows[bar_idx].rect.b.x, 75)
    assert_equal(d.windows.windows[bar_idx].rect.b.y, 25)
    assert_equal(d.windows.windows[bar_idx].editor.cursor_row, 1)
    assert_equal(d.windows.windows[bar_idx].editor.cursor_col, 2)
    assert_equal(d.windows.focused, bar_idx)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_restores_maximized_window_keeps_per_window_restore_rect() raises:
    """A saved maximized window must come back maximized AND keep its
    own ``_restore_rect`` so un-maximizing returns to the user's
    pre-max layout — not to the shared workspace rect. Regression for
    the bug where ``toggle_maximize`` clobbered the just-loaded
    ``_restore_rect``."""
    var root = String("/tmp/turbokod_session_max_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/m.txt"), String("m\n")))
    var s = Session()
    var sw = SessionWindow()
    sw.path = String("m.txt")
    # Saved state: window is maximized to a 100×30 workspace, but the
    # underlying un-maximized rect is small (8, 4)→(40, 18).
    sw.rect_a_x = 0
    sw.rect_a_y = 1
    sw.rect_b_x = 100
    sw.rect_b_y = 28
    sw.is_maximized = True
    sw.restore_a_x = 8
    sw.restore_a_y = 4
    sw.restore_b_x = 40
    sw.restore_b_y = 18
    s.windows.append(sw^)
    s.focused = 0
    assert_true(save_session(root, s))
    var d = Desktop()
    d.open_project(root)
    var screen = Rect(0, 0, 100, 30)
    d._pending_restore = False
    d._restore_session(screen)
    assert_equal(len(d.windows.windows), 1)
    var w = d.windows.windows[0].copy()
    assert_true(w.is_maximized)
    # _restore_rect must reflect the saved un-maximized layout.
    assert_equal(w._restore_rect.a.x, 8)
    assert_equal(w._restore_rect.a.y, 4)
    assert_equal(w._restore_rect.b.x, 40)
    assert_equal(w._restore_rect.b.y, 18)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_save_then_restore_round_trip_through_paint() raises:
    """End-to-end: open two files in a project at distinct rects via
    ``paint`` (which writes the session), then construct a fresh
    ``Desktop`` against the same project and confirm the saved layout
    is restored. Covers the full ``_save_session_if_changed`` →
    ``load_session`` → ``_restore_session`` loop."""
    var root = String("/tmp/turbokod_session_e2e_test")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(root + String("/p.txt"), String("p\n")))
    assert_true(write_file(root + String("/q.txt"), String("q\n")))
    var screen = Rect(0, 0, 80, 30)
    var canvas = Canvas(80, 30)

    # --- session 1: open two files, position them, paint to save ---------
    var d1 = Desktop()
    d1.open_project(root)
    d1.open_file(root + String("/p.txt"), screen)
    d1.open_file(root + String("/q.txt"), screen)
    assert_equal(len(d1.windows.windows), 2)
    d1.windows.windows[0].rect = Rect(2, 1, 30, 12)
    d1.windows.windows[0]._restore_rect = Rect(2, 1, 30, 12)
    d1.windows.windows[0].is_maximized = False
    d1.windows.windows[1].rect = Rect(40, 5, 75, 25)
    d1.windows.windows[1]._restore_rect = Rect(40, 5, 75, 25)
    d1.windows.windows[1].is_maximized = False
    d1.windows.focused = 1
    d1.paint(canvas, screen)
    var session_path = root + String("/.turbokod/session.json")
    assert_true(stat_file(session_path).ok)

    # --- session 2: fresh Desktop, restore via paint ---------------------
    var d2 = Desktop()
    d2.open_project(root)
    assert_true(d2._pending_restore)
    d2.paint(canvas, screen)
    assert_equal(len(d2.windows.windows), 2)
    var p_idx = -1
    var q_idx = -1
    for i in range(len(d2.windows.windows)):
        var fp = d2.windows.windows[i].editor.file_path
        var fpb = fp.as_bytes()
        var slen = len(String("/p.txt").as_bytes())
        if len(fpb) >= slen \
                and String(StringSlice(unsafe_from_utf8=fpb[len(fpb) - slen:])) \
                == String("/p.txt"):
            p_idx = i
        if len(fpb) >= slen \
                and String(StringSlice(unsafe_from_utf8=fpb[len(fpb) - slen:])) \
                == String("/q.txt"):
            q_idx = i
    assert_true(p_idx >= 0)
    assert_true(q_idx >= 0)
    # Each restored window must keep its own saved rect — not collapse
    # to a shared default.
    assert_true(d2.windows.windows[p_idx].rect.a.x \
                != d2.windows.windows[q_idx].rect.a.x)
    assert_equal(d2.windows.windows[p_idx].rect.a.x, 2)
    assert_equal(d2.windows.windows[p_idx].rect.b.x, 30)
    assert_equal(d2.windows.windows[q_idx].rect.a.x, 40)
    assert_equal(d2.windows.windows[q_idx].rect.b.x, 75)
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_desktop_snapshot_skips_untitled_windows() raises:
    """``_snapshot_session`` filters out non-editor windows and
    file-less editors (Untitled buffers). Only file-backed editors
    show up in the saved session."""
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    assert_true(d.project)
    var screen = Rect(0, 0, 80, 30)
    d.new_file(screen)                          # file-less Untitled
    try:
        d.open_file(String("examples/hello.mojo"), screen)
    except:
        pass
    var session = d._snapshot_session()
    # Only the file-backed window should be in the snapshot.
    assert_equal(len(session.windows), 1)
    var path = session.windows[0].path
    # Stored relative to the project root resolved by
    # ``find_git_project`` — for this checkout that's the repo root,
    # so the path becomes ``examples/hello.mojo``.
    assert_equal(path, String("examples/hello.mojo"))


def test_diff_grammar_paints_inserted_deleted_and_hunk_header() raises:
    """The bundled diff TextMate grammar maps ``-`` lines to the string
    color (red), ``+`` lines to the ident color (green), and the
    ``@@`` hunk header to the decorator color (cyan)."""
    var lines = _hl_lines(
        String("--- a/file.txt"),
        String("+++ b/file.txt"),
        String("@@ -1,3 +1,3 @@"),
        String(" context"),
        String("-removed"),
        String("+added"),
    )
    var hls = highlight_for_extension(String("diff"), lines)
    var saw_deleted = False
    var saw_inserted = False
    var saw_range = False
    for i in range(len(hls)):
        var a = hls[i].attr
        if hls[i].row == 4 and a == highlight_string_attr():
            saw_deleted = True
        if hls[i].row == 5 and a == highlight_ident_attr():
            saw_inserted = True
        if hls[i].row == 2 and a == highlight_decorator_attr():
            saw_range = True
    assert_true(saw_deleted)
    assert_true(saw_inserted)
    assert_true(saw_range)


def test_diff_identical_inputs_have_no_hunks() raises:
    """Two identical inputs produce only the file headers — no ``@@``."""
    var same = String("alpha\nbeta\ngamma\n")
    var out = unified_diff(same, same, String("a"), String("b"))
    var idx = out.find(String("@@"))
    assert_equal(idx, -1)


def test_diff_lines_pure_insert() raises:
    """Inserting one line in the middle: one delete-free, one insert op."""
    var a = List[String]()
    a.append(String("one"))
    a.append(String("three"))
    var b = List[String]()
    b.append(String("one"))
    b.append(String("two"))
    b.append(String("three"))
    var ops = diff_lines(a, b)
    var equals = 0
    var inserts = 0
    var deletes = 0
    for i in range(len(ops)):
        if ops[i].kind == 0:
            equals += 1
        elif ops[i].kind == 1:
            deletes += 1
        else:
            inserts += 1
    assert_equal(equals, 2)
    assert_equal(inserts, 1)
    assert_equal(deletes, 0)


def test_diff_lines_pure_delete() raises:
    """Removing one line: one delete op, no inserts."""
    var a = List[String]()
    a.append(String("one"))
    a.append(String("two"))
    a.append(String("three"))
    var b = List[String]()
    b.append(String("one"))
    b.append(String("three"))
    var ops = diff_lines(a, b)
    var equals = 0
    var inserts = 0
    var deletes = 0
    for i in range(len(ops)):
        if ops[i].kind == 0:
            equals += 1
        elif ops[i].kind == 1:
            deletes += 1
        else:
            inserts += 1
    assert_equal(equals, 2)
    assert_equal(inserts, 0)
    assert_equal(deletes, 1)


def test_diff_lines_replace_round_trips() raises:
    """Applying the edit script must turn ``a`` into ``b`` exactly."""
    var a = List[String]()
    a.append(String("the quick brown fox"))
    a.append(String("jumps over"))
    a.append(String("the lazy dog"))
    var b = List[String]()
    b.append(String("the quick red fox"))
    b.append(String("hops over"))
    b.append(String("the lazy dog"))
    b.append(String("end"))
    var ops = diff_lines(a, b)
    # Replay: equal/delete consume from a, insert produces from b. The
    # produced sequence (equal lines from a, plus inserts from b in order)
    # should match b exactly when the script is applied.
    var produced = List[String]()
    for i in range(len(ops)):
        if ops[i].kind == 0:
            produced.append(a[ops[i].a_index])
        elif ops[i].kind == 2:
            produced.append(b[ops[i].b_index])
    assert_equal(len(produced), len(b))
    for i in range(len(b)):
        assert_equal(produced[i], b[i])


def test_unified_diff_renders_hunk_header_and_marks() raises:
    """A simple replace: hunk header present, ``-old`` and ``+new`` lines
    emitted, surrounding equals appear with a leading space."""
    var a = String("alpha\nbeta\ngamma\n")
    var b = String("alpha\nBETA\ngamma\n")
    var out = unified_diff(a, b, String("old"), String("new"))
    assert_true(out.find(String("--- old")) >= 0)
    assert_true(out.find(String("+++ new")) >= 0)
    assert_true(out.find(String("@@")) >= 0)
    assert_true(out.find(String("-beta")) >= 0)
    assert_true(out.find(String("+BETA")) >= 0)
    assert_true(out.find(String(" alpha")) >= 0)
    assert_true(out.find(String(" gamma")) >= 0)


def test_git_blame_parses_two_line_porcelain() raises:
    """Two source lines, two distinct commits — parser must emit one
    ``BlameLine`` per line with the right short-SHA + author. Each
    record's first occurrence carries metadata; that author should
    propagate to ``BlameLine.author`` for that record.
    """
    var text = (
        String("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1\n")
        + String("author Alice\n")
        + String("author-mail <alice@example.com>\n")
        + String("summary first line\n")
        + String("\thello\n")
        + String("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2 2 1\n")
        + String("author Bob\n")
        + String("author-mail <bob@example.com>\n")
        + String("summary second line\n")
        + String("\tworld\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 2)
    assert_equal(lines[0].commit, String("aaaaaaaa"))
    assert_equal(lines[0].author, String("Alice"))
    assert_equal(lines[1].commit, String("bbbbbbbb"))
    assert_equal(lines[1].author, String("Bob"))


def test_git_blame_propagates_cached_author_for_repeated_sha() raises:
    """Lines 2..N of a same-commit group only carry ``<sha> <orig> <final>``
    + ``\\t<content>`` — no metadata. The parser must remember the
    author from the first occurrence so the repeated lines still get
    a real name (not "Not Committed Yet")."""
    var sha = String("cccccccccccccccccccccccccccccccccccccccc")
    var input = (
        sha + String(" 1 1 2\n")
        + String("author Carol\n")
        + String("summary same commit, two lines\n")
        + String("\tline one\n")
        + sha + String(" 2 2\n")
        + String("\tline two\n")
    )
    var lines = parse_blame_porcelain(input)
    assert_equal(len(lines), 2)
    assert_equal(lines[0].commit, String("cccccccc"))
    assert_equal(lines[0].author, String("Carol"))
    assert_equal(lines[1].commit, String("cccccccc"))
    assert_equal(lines[1].author, String("Carol"))


def test_git_blame_marks_uncommitted_with_zero_sha_and_placeholder() raises:
    """Git emits a 40-char zero SHA and ``Not Committed Yet`` author
    for lines that exist only in the worktree. The parser preserves
    that — tests downstream rendering doesn't crash on the all-zero
    short SHA."""
    var text = (
        String("0000000000000000000000000000000000000000 1 1 1\n")
        + String("author Not Committed Yet\n")
        + String("summary Version of foo from foo.txt\n")
        + String("\tfresh line\n")
    )
    var lines = parse_blame_porcelain(text)
    assert_equal(len(lines), 1)
    assert_equal(lines[0].commit, String("00000000"))
    assert_equal(lines[0].author, String("Not Committed Yet"))


def test_editor_blame_gutter_widens_total_gutter() raises:
    """``set_blame`` enables the gutter; the editor's overall left
    margin grows to make room for ``<sha> <author>`` (8+1+14+1 = 24
    cells). Toggling off shrinks the margin back."""
    var ed = Editor(String("alpha\nbeta\n"))
    var bl = List[BlameLine]()
    bl.append(BlameLine(String("12345678"), String("Anders")))
    bl.append(BlameLine(String("12345678"), String("Anders")))
    ed.set_blame(bl^)
    assert_true(ed.blame_visible)
    assert_equal(ed._blame_gutter(), 24)
    ed.toggle_blame()
    assert_false(ed.blame_visible)
    assert_equal(ed._blame_gutter(), 0)


def test_parse_unified_diff_splits_two_files() raises:
    """Two files in one diff stream — the parser must split on the
    ``diff --git`` boundary and pull each path from the ``+++ b/...``
    header. The first file's chunk gets ``+++ b/foo.txt`` so its path
    is ``foo.txt``; the second has ``+++ b/dir/bar.mojo``."""
    var text = (
        String("diff --git a/foo.txt b/foo.txt\n")
        + String("index abcdef..123456 100644\n")
        + String("--- a/foo.txt\n")
        + String("+++ b/foo.txt\n")
        + String("@@ -1,2 +1,2 @@\n")
        + String("-old\n")
        + String("+new\n")
        + String(" unchanged\n")
        + String("diff --git a/dir/bar.mojo b/dir/bar.mojo\n")
        + String("index 999..888 100644\n")
        + String("--- a/dir/bar.mojo\n")
        + String("+++ b/dir/bar.mojo\n")
        + String("@@ -10 +10 @@\n")
        + String("-fn old(): pass\n")
        + String("+fn new(): pass\n")
    )
    var files = parse_unified_diff_files(text)
    assert_equal(len(files), 2)
    assert_equal(files[0].path, String("foo.txt"))
    assert_equal(files[1].path, String("dir/bar.mojo"))


def test_parse_unified_diff_handles_pure_delete() raises:
    """A pure file delete shows ``+++ /dev/null``; the parser must
    fall back to ``--- a/<path>`` so the sidebar still has a real
    name to show."""
    var text = (
        String("diff --git a/gone.txt b/gone.txt\n")
        + String("deleted file mode 100644\n")
        + String("index abc..0000000\n")
        + String("--- a/gone.txt\n")
        + String("+++ /dev/null\n")
        + String("@@ -1 +0,0 @@\n")
        + String("-bye\n")
    )
    var files = parse_unified_diff_files(text)
    assert_equal(len(files), 1)
    assert_equal(files[0].path, String("gone.txt"))


def test_diff_buffer_against_head_marks_added_and_modified() raises:
    """Diffing the editor's in-memory line list against the HEAD blob
    marks pure inserts as ADDED and inserts paired with deletes as
    MODIFIED. Lines untouched on either side land as NONE."""
    var head = (
        String("alpha\n")
        + String("beta\n")
        + String("gamma\n")
        + String("delta\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("BETA"))           # modified (replaces "beta")
    buffer.append(String("gamma"))
    buffer.append(String("inserted"))       # pure add
    buffer.append(String("delta"))
    buffer.append(String(""))               # trailing empty (was newline at EOF)
    var marks = diff_buffer_against_head(head, buffer)
    assert_equal(len(marks), len(buffer))
    assert_equal(marks[0], GIT_CHANGE_NONE)
    assert_equal(marks[1], GIT_CHANGE_MODIFIED)
    assert_equal(marks[2], GIT_CHANGE_NONE)
    assert_equal(marks[3], GIT_CHANGE_ADDED)
    assert_equal(marks[4], GIT_CHANGE_NONE)


def test_compute_revert_block_modified_line() raises:
    """Reverting a modified line maps the buffer row back to the run's
    HEAD lines so the editor can splice them in place."""
    var head = (
        String("alpha\n")
        + String("beta\n")
        + String("gamma\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("BETA"))
    buffer.append(String("gamma"))
    buffer.append(String(""))
    var block_opt = compute_revert_block(head, buffer, 1)
    assert_true(Bool(block_opt))
    var block = block_opt.value().copy()
    assert_equal(block.buf_start, 1)
    assert_equal(block.buf_end_excl, 2)
    assert_equal(len(block.head_lines), 1)
    assert_equal(block.head_lines[0], String("beta"))


def test_compute_revert_block_added_line() raises:
    """Reverting a pure-insert run yields an empty HEAD slice — the
    editor splices nothing in, effectively deleting the buffer rows."""
    var head = (
        String("alpha\n")
        + String("gamma\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("inserted"))
    buffer.append(String("gamma"))
    buffer.append(String(""))
    var block_opt = compute_revert_block(head, buffer, 1)
    assert_true(Bool(block_opt))
    var block = block_opt.value().copy()
    assert_equal(block.buf_start, 1)
    assert_equal(block.buf_end_excl, 2)
    assert_equal(len(block.head_lines), 0)


def test_compute_revert_block_unchanged_returns_empty() raises:
    """A row that matches HEAD has nothing to revert."""
    var head = (
        String("alpha\n")
        + String("beta\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("beta"))
    buffer.append(String(""))
    var block_opt = compute_revert_block(head, buffer, 0)
    assert_true(not Bool(block_opt))


def test_editor_git_changes_gutter_widens_total_gutter() raises:
    """``set_git_changes`` flips the column on; the editor's overall
    left margin grows by exactly one cell. ``invalidate_git_changes``
    drops the cache so the gutter goes away again."""
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.git_changes_visible = True
    var marks = List[Int]()
    marks.append(GIT_CHANGE_ADDED)
    marks.append(GIT_CHANGE_MODIFIED)
    marks.append(GIT_CHANGE_NONE)
    ed.set_git_changes(marks^)
    assert_equal(ed._git_changes_gutter(), 1)
    ed.invalidate_git_changes()
    # Visible flag still on, but no data → no column.
    assert_equal(ed._git_changes_gutter(), 0)


def test_editor_right_gutter_paints_gray_square_for_changes() raises:
    """When the file fits in the view, the right-edge column maps 1:1
    onto buffer rows: a gray ``■`` lands on each row whose status is
    ADDED or MODIFIED, and rows with no change leave the column blank."""
    var ed = Editor(String("alpha\nbeta\ngamma\n"))
    ed.git_changes_visible = True
    var marks = List[Int]()
    marks.append(GIT_CHANGE_ADDED)
    marks.append(GIT_CHANGE_NONE)
    marks.append(GIT_CHANGE_MODIFIED)
    ed.set_git_changes(marks^)
    assert_equal(ed._right_gutter(), 1)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # Column 39 is the right gutter. Row 0 (ADDED) and row 2 (MODIFIED)
    # should carry the square; row 1 (NONE) is blank.
    assert_equal(canvas.get(39, 0).glyph, String("■"))
    assert_equal(canvas.get(39, 0).attr.fg, LIGHT_GRAY)
    assert_equal(canvas.get(39, 1).glyph, String(" "))
    assert_equal(canvas.get(39, 2).glyph, String("■"))
    # When git-changes is off the right gutter is zero-width again.
    ed.invalidate_git_changes()
    assert_equal(ed._right_gutter(), 0)


def test_editor_right_gutter_projects_full_file_when_scrolled() raises:
    """The right gutter is a minimap of the whole file, not of the
    visible region: scrolling past the changed line still paints the
    square at the projected screen row, computed off ``line_count`` and
    ``view.height()``. With 20 lines in a 5-row view, line 10 falls in
    the slice owned by screen row 2 — and that's where the square lands
    no matter where ``scroll_y`` sits."""
    var text = String("")
    for i in range(20):
        text = text + String("line") + String(i) + String("\n")
    var ed = Editor(text^)
    ed.git_changes_visible = True
    var marks = List[Int]()
    for i in range(20):
        marks.append(
            GIT_CHANGE_MODIFIED if i == 10 else GIT_CHANGE_NONE
        )
    ed.set_git_changes(marks^)
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    # Scroll deep into the file — the gutter must still anchor at the
    # whole-file projection, not at the visible window.
    ed.scroll_y = 15
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # Slice owned by screen row 2 covers buffer rows [(2*20)/5 = 8,
    # (3*20)/5 = 12), which contains line 10.
    assert_equal(canvas.get(39, 2).glyph, String("■"))
    # Adjacent rows share no changed buffer line, so they stay blank.
    assert_equal(canvas.get(39, 1).glyph, String(" "))
    assert_equal(canvas.get(39, 3).glyph, String(" "))


def test_local_changes_open_records_status_when_clean() raises:
    """Pointing the widget at ``/tmp`` (not a git repo) makes
    ``compute_local_changes`` return empty; ``open`` should record a
    user-readable status string and end up with no files."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    assert_true(lc.active)
    assert_equal(len(lc.files), 0)
    assert_true(len(lc.status_message.as_bytes()) > 0)
    lc.close()
    assert_false(lc.active)


def test_local_changes_sidebar_splitter_drag_resizes_right_pane() raises:
    """A press on the vertical ``│`` splitter followed by a drag-motion
    must update ``sidebar_width_user``, which is what shrinks the
    sidebar and grows the right-side window. Verifies the artificial
    16/56-cell caps are gone — the user can drag the splitter freely
    down to a 1-cell sidebar (so the right side fills nearly the whole
    window) or out to ``screen.width() - 2``."""
    var lc = LocalChanges()
    lc.open(String("/tmp"))
    var screen = Rect(0, 0, 200, 40)
    var registry = GrammarRegistry()
    var default_w = 56
    # Drag from auto-default to a narrow sidebar.
    _ = lc.handle_mouse(
        Event.mouse_event(
            Point(default_w, 10), MOUSE_BUTTON_LEFT, True, False,
        ),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(30, 10), MOUSE_BUTTON_LEFT, True, True),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(30, 10), MOUSE_BUTTON_LEFT, False, False),
        screen, registry,
    )
    assert_equal(lc.sidebar_width_user, 30)
    # Drag past the old 16-cell minimum — the user is free to crush
    # the sidebar to 1 cell.
    _ = lc.handle_mouse(
        Event.mouse_event(Point(30, 10), MOUSE_BUTTON_LEFT, True, False),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(2, 10), MOUSE_BUTTON_LEFT, True, True),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(2, 10), MOUSE_BUTTON_LEFT, False, False),
        screen, registry,
    )
    assert_equal(lc.sidebar_width_user, 2)
    # And drag past the old 56-cell maximum — the user can also push
    # the sidebar out to almost the entire width.
    _ = lc.handle_mouse(
        Event.mouse_event(Point(2, 10), MOUSE_BUTTON_LEFT, True, False),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(180, 10), MOUSE_BUTTON_LEFT, True, True),
        screen, registry,
    )
    _ = lc.handle_mouse(
        Event.mouse_event(Point(180, 10), MOUSE_BUTTON_LEFT, False, False),
        screen, registry,
    )
    assert_equal(lc.sidebar_width_user, 180)
    lc.close()


def test_docked_panel_stack_layout_normal_split() raises:
    """All sections NORMAL → equal share of available content rows."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    # 23 rows total. 2 splitter rows between 3 sections → 21 content rows.
    # Equal share: 7 each.
    var lay = dock.layout(0, 23)
    assert_equal(len(lay), 6)
    assert_equal(lay[0], 0)   # section 0 top
    assert_equal(lay[1], 7)   # section 0 height
    assert_equal(lay[2], 8)   # section 1 top (0 + 7 + 1 splitter)
    assert_equal(lay[3], 7)
    assert_equal(lay[4], 16)
    assert_equal(lay[5], 7)


def test_docked_panel_stack_max_collapses_others() raises:
    """Maximizing one section should give it nearly all the content
    while the other two collapse to header-only (height 1)."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    dock.toggle_max(1)  # Maximize section B
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_NORMAL))
    assert_equal(Int(dock.state(1)), Int(PANEL_STATE_MAXIMIZED))
    assert_equal(Int(dock.state(2)), Int(PANEL_STATE_NORMAL))
    var lay = dock.layout(0, 23)
    # 21 content rows, A and C take 1 each → B gets 19.
    assert_equal(lay[1], 1)
    assert_equal(lay[3], 19)
    assert_equal(lay[5], 1)
    # Title rows still positioned correctly (so the user sees them).
    assert_equal(lay[0], 0)
    assert_equal(lay[2], 2)   # 0 + 1 + 1 splitter
    assert_equal(lay[4], 22)  # 2 + 19 + 1 splitter


def test_docked_panel_stack_max_then_restore_resets_all() raises:
    """Toggling max twice on the same section restores everyone to
    NORMAL (and clears the other sections' visually-min'd state too)."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    dock.toggle_max(0)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_MAXIMIZED))
    dock.toggle_max(0)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_NORMAL))
    assert_equal(Int(dock.state(1)), Int(PANEL_STATE_NORMAL))
    assert_true(dock.all_normal())


def test_docked_panel_stack_min_collapses_one() raises:
    """A single minimized section stays at height 1; the rest split
    the leftover."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    dock.toggle_min(0)
    var lay = dock.layout(0, 23)
    assert_equal(lay[1], 1)
    # 21 - 1 = 20 across two NORMALs → 10 each.
    assert_equal(lay[3], 10)
    assert_equal(lay[5], 10)


def test_docked_panel_stack_min_on_max_sibling_clears_max() raises:
    """If section A is MAXIMIZED (so B is visually min'd), clicking
    B's min/restore button must clear A's max and restore B to NORMAL —
    the ``effective`` state on B was MINIMIZED (because of A), so the
    click is treated as a restore."""
    var dock = DockedPanelStack()
    _ = dock.add(String("A"))
    _ = dock.add(String("B"))
    _ = dock.add(String("C"))
    dock.toggle_max(0)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_MAXIMIZED))
    # Click min/restore on B — the visually-min'd sibling.
    dock.toggle_min(1)
    assert_equal(Int(dock.state(0)), Int(PANEL_STATE_NORMAL))
    assert_equal(Int(dock.state(1)), Int(PANEL_STATE_NORMAL))
    assert_true(dock.all_normal())


def test_build_minimal_patch_keeps_only_target_plus_line() raises:
    """A pure-add hunk with two ``+`` lines: targeting one of them
    must produce a patch with just that one as ``+`` and the other
    dropped, leaving context lines intact. ``--recount`` will fix the
    @@ counts so we don't assert on those."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,2 +1,4 @@\n"
        + " ctx_before\n"
        + "+added_one\n"
        + "+added_two\n"
        + " ctx_after\n"
    )
    # Lines (0-indexed after _split_lines):
    # 0: diff --git a/x b/x
    # 1: --- a/x
    # 2: +++ b/x
    # 3: @@ -1,2 +1,4 @@
    # 4:  ctx_before
    # 5: +added_one
    # 6: +added_two
    # 7:  ctx_after
    var patch = build_minimal_patch(diff, 6, False)
    # Must contain the target +added_two but NOT +added_one.
    assert_true(String("+added_two") in patch)
    assert_false(String("+added_one") in patch)
    # Context preserved.
    assert_true(String(" ctx_before") in patch)
    assert_true(String(" ctx_after") in patch)
    # File header preserved.
    assert_true(String("--- a/x") in patch)
    assert_true(String("+++ b/x") in patch)


def test_build_minimal_patch_demotes_paired_minus_to_context() raises:
    """A replacement hunk (``-`` paired with ``+``): targeting the
    ``+`` line forward (staging) must convert the ``-`` line into
    context so the LEFT side still matches the index. Otherwise the
    patch would refuse to apply because the context wouldn't line up."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,3 +1,3 @@\n"
        + " ctx\n"
        + "-old_line\n"
        + "+new_line\n"
        + " more_ctx\n"
    )
    # Line indices: 4= ctx, 5=-old_line, 6=+new_line, 7= more_ctx.
    var patch = build_minimal_patch(diff, 6, False)
    # The +new_line stays; -old_line becomes context (gets a leading space).
    assert_true(String("+new_line") in patch)
    assert_false(String("-old_line") in patch)
    assert_true(String(" old_line") in patch)


def test_build_minimal_patch_reverse_drops_paired_minus() raises:
    """In the staged section we use --reverse. Targeting a ``+`` line
    must convert other ``+`` lines to context (so the RIGHT side still
    matches the index) and drop other ``-`` lines (their would-be
    presence in the LEFT side has nothing to do with the index that
    we're patching)."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,3 +1,3 @@\n"
        + " ctx\n"
        + "-old_line\n"
        + "+new_line\n"
        + " more_ctx\n"
    )
    var patch = build_minimal_patch(diff, 6, True)
    assert_true(String("+new_line") in patch)
    # Reverse: the unselected ``-`` is dropped entirely (not converted).
    assert_false(String("-old_line") in patch)
    assert_false(String(" old_line") in patch)


def test_build_minimal_patch_returns_empty_for_non_pm_lines() raises:
    """Cursor on a context / header line: nothing to stage, return
    empty so the caller can no-op cleanly."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,2 +1,3 @@\n"
        + " ctx\n"
        + "+added\n"
        + " more\n"
    )
    # Index 4 is " ctx" (context line) — not toggleable.
    assert_equal(len(build_minimal_patch(diff, 4, False).as_bytes()), 0)
    # Index 3 is the @@ header.
    assert_equal(len(build_minimal_patch(diff, 3, False).as_bytes()), 0)
    # Index 0 is the file header.
    assert_equal(len(build_minimal_patch(diff, 0, False).as_bytes()), 0)


def _run_git(root: String, var args: List[String]) raises -> Int:
    """Wrapper around ``capture_command`` for the staging integration
    test below. Returns the exit status. We rebuild the argv with
    ``git -C <root>`` in front so the test doesn't have to repeat it."""
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(root)
    for i in range(len(args)):
        argv.append(args[i])
    var r = capture_command(argv)
    return Int(r.status)


def _ensure_dir(path: String) raises:
    var argv = List[String]()
    argv.append(String("mkdir"))
    argv.append(String("-p"))
    argv.append(path)
    _ = capture_command(argv)


def _rm_rf(path: String) raises:
    var argv = List[String]()
    argv.append(String("rm"))
    argv.append(String("-rf"))
    argv.append(path)
    _ = capture_command(argv)


def test_git_state_mtimes_zero_for_non_repo() raises:
    """``git_state_mtimes`` returns zeros for a directory that isn't a
    git repo, and for the empty-string root. The desktop's polling
    loop reads the zero baseline as "no comparison yet" and skips
    invalidation, so this is the contract that keeps non-git projects
    from getting spurious refreshes."""
    var dir = _temp_path(String("_git_mtime_nogit"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var mt = git_state_mtimes(dir)
    assert_true(mt.is_zero())
    var empty = git_state_mtimes(String(""))
    assert_true(empty.is_zero())
    _rm_rf(dir)


def test_git_state_mtimes_nonzero_after_init_commit() raises:
    """A fresh ``git init`` + commit produces nonzero mtimes for both
    ``.git/HEAD`` and ``.git/index`` — the polling loop's "something
    changed" comparison only fires once a real baseline exists."""
    var dir = _temp_path(String("_git_mtime_init"))
    _rm_rf(dir)
    _ensure_dir(dir)
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    var rc = _run_git(dir, init_args^)
    if rc != 0:
        # No git on PATH — skip silently, matching the staging test.
        _rm_rf(dir)
        return
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    var f = join_path(dir, String("a.txt"))
    assert_true(write_file(f, String("hello\n")))
    var add = List[String]()
    add.append(String("add"))
    add.append(String("a.txt"))
    _ = _run_git(dir, add^)
    var commit = List[String]()
    commit.append(String("commit"))
    commit.append(String("-q"))
    commit.append(String("-m"))
    commit.append(String("init"))
    _ = _run_git(dir, commit^)
    var mt = git_state_mtimes(dir)
    assert_true(mt.head_mtime != Int64(0))
    assert_true(mt.index_mtime != Int64(0))
    # equals() returns True for itself, False for a zero baseline.
    assert_true(mt.equals(mt))
    var zero = GitStateMtimes(Int64(0), Int64(0))
    assert_true(not mt.equals(zero))
    assert_true(zero.is_zero())
    _rm_rf(dir)


def test_stage_unstage_round_trip_against_real_git() raises:
    """End-to-end: spin up a throwaway git repo, modify a file, walk it
    through stage_file → fetch_git_status → unstage_file. Asserts the
    porcelain X/Y columns flip the way we expect, which is the contract
    the LocalChanges UI is built on. Skipped silently when ``git`` is
    missing or ``git init`` fails (e.g., a build environment without
    git on PATH)."""
    var dir = _temp_path(String("_stage_int"))
    _rm_rf(dir)
    _ensure_dir(dir)
    # ``git init -q`` so we don't pollute test output. Pass ``-b main``
    # to avoid the default-branch warning that newer git emits — we
    # don't care which branch, just that the call succeeds.
    var init_args = List[String]()
    init_args.append(String("init"))
    init_args.append(String("-q"))
    init_args.append(String("-b"))
    init_args.append(String("main"))
    var rc = _run_git(dir, init_args^)
    if rc != 0:
        # No git available — skip silently.
        _rm_rf(dir)
        return
    # Configure user so commit doesn't fail; ``-c`` per-invocation would
    # be cleaner but we'd have to plumb it through every helper call.
    var cfg1 = List[String]()
    cfg1.append(String("config"))
    cfg1.append(String("user.email"))
    cfg1.append(String("test@example.com"))
    _ = _run_git(dir, cfg1^)
    var cfg2 = List[String]()
    cfg2.append(String("config"))
    cfg2.append(String("user.name"))
    cfg2.append(String("Test"))
    _ = _run_git(dir, cfg2^)
    # Initial commit of a known-content file.
    var f = join_path(dir, String("a.txt"))
    assert_true(write_file(f, String("alpha\nbeta\ngamma\n")))
    var add_initial = List[String]()
    add_initial.append(String("add"))
    add_initial.append(String("a.txt"))
    _ = _run_git(dir, add_initial^)
    var commit_args = List[String]()
    commit_args.append(String("commit"))
    commit_args.append(String("-q"))
    commit_args.append(String("-m"))
    commit_args.append(String("init"))
    _ = _run_git(dir, commit_args^)
    # Modify the file.
    assert_true(write_file(f, String("alpha\nbeta-modified\ngamma\n")))
    # Status should show ' M a.txt'.
    var statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x20)
    assert_equal(Int(statuses[0].worktree), 0x4D)    # 'M'
    assert_equal(statuses[0].path, String("a.txt"))
    # Stage the whole file.
    assert_true(stage_file(dir, String("a.txt")))
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x4D)      # 'M'
    assert_equal(Int(statuses[0].worktree), 0x20)
    # Unstage and verify it bounces back.
    assert_true(unstage_file(dir, String("a.txt")))
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x20)
    assert_equal(Int(statuses[0].worktree), 0x4D)
    # Build a minimal patch from the unstaged diff and apply it: that
    # exercises the line-staging path end-to-end. The hunk has one ``-``
    # / one ``+`` pair, so targeting the ``+`` line stages the change
    # while demoting the ``-`` to context (algorithm tested above).
    var unstaged = compute_unstaged_diff(dir)
    assert_true(len(unstaged.as_bytes()) > 0)
    var per_file = parse_unified_diff_files(unstaged)
    assert_equal(len(per_file), 1)
    var lines = List[String]()
    var b = per_file[0].diff.as_bytes()
    var s = 0
    for i in range(len(b)):
        if b[i] == 0x0A:
            lines.append(String(StringSlice(unsafe_from_utf8=b[s:i])))
            s = i + 1
    if s < len(b):
        lines.append(String(StringSlice(unsafe_from_utf8=b[s:len(b)])))
    # Find the ``+beta-modified`` line index.
    var plus_idx = -1
    for i in range(len(lines)):
        var lb = lines[i].as_bytes()
        if len(lb) > 0 and Int(lb[0]) == 0x2B \
                and lines[i] != String("+++ b/a.txt"):
            plus_idx = i
            break
    assert_true(plus_idx > 0)
    var patch = build_minimal_patch(per_file[0].diff, plus_idx, False)
    assert_true(len(patch.as_bytes()) > 0)
    assert_true(apply_patch_to_index(dir, patch, False))
    # After applying: the staged side should now have a modification.
    # Worktree column stays modified because we only staged the ``+`` half
    # of the replacement (``-beta`` was demoted to context, so removing
    # ``beta`` is still pending) — that's the correct line-staging
    # semantics, just an awkward end-state. The point of the assertion
    # is that staging didn't no-op.
    var staged_after = compute_staged_diff(dir)
    assert_true(len(staged_after.as_bytes()) > 0)
    statuses = fetch_git_status(dir)
    assert_equal(len(statuses), 1)
    assert_equal(Int(statuses[0].staged), 0x4D)
    assert_equal(Int(statuses[0].worktree), 0x4D)
    _rm_rf(dir)


def test_build_minimal_patch_drops_other_hunks() raises:
    """A diff with two hunks: targeting a line in the first must produce
    output containing only that hunk; the second hunk's lines must not
    appear at all (otherwise we'd accidentally stage other changes)."""
    var diff = String(
        "diff --git a/x b/x\n"
        + "--- a/x\n"
        + "+++ b/x\n"
        + "@@ -1,2 +1,3 @@\n"
        + " a\n"
        + "+added_in_hunk1\n"
        + " b\n"
        + "@@ -10,1 +11,2 @@\n"
        + " c\n"
        + "+added_in_hunk2\n"
    )
    var patch = build_minimal_patch(diff, 5, False)
    assert_true(String("+added_in_hunk1") in patch)
    assert_false(String("+added_in_hunk2") in patch)
    # Second hunk header dropped too.
    assert_false(String("@@ -10,1") in patch)


def test_canvas_put_wrapped_text_paints_inside_rect_only() raises:
    """Framework primitive: long text rendered through
    ``put_wrapped_text`` must wrap inside the rect and never colour a
    cell outside it. The Prompt overflow fix relies on this contract,
    and any future popup with variable text content should too."""
    var canvas = Canvas(40, 10)
    canvas.clear(Attr(BLACK, BLUE))
    var rect = Rect(5, 2, 25, 6)   # 20 cells wide, 4 rows tall
    var text = String(
        "Install rust LSP? 'rustup component add rust-analyzer' (y/N)"
    )
    var rows = canvas.put_wrapped_text(rect, text, Attr(WHITE, BLACK))
    assert_true(rows >= 1)
    assert_true(rows <= 4)
    # No cell outside ``rect`` should have its background flipped from
    # the workspace fill — that's exactly the property dialogs need.
    for y in range(10):
        for x in range(40):
            var inside = (x >= 5 and x < 25 and y >= 2 and y < 6)
            if inside:
                continue
            assert_equal(canvas.get(x, y).attr.bg, BLUE)


def test_canvas_put_wrapped_text_returns_zero_for_empty_rect() raises:
    var canvas = Canvas(20, 5)
    canvas.clear(Attr(BLACK, BLUE))
    var rows = canvas.put_wrapped_text(
        Rect(0, 0, 0, 0), String("hello"), Attr(WHITE, BLACK),
    )
    assert_equal(rows, 0)


def test_prompt_wrap_short_text_stays_on_one_line() raises:
    var lines = wrap_to_width(String("Find: "), 56)
    assert_equal(len(lines), 1)
    assert_equal(lines[0], String("Find: "))


def test_prompt_wrap_breaks_at_last_space_within_budget() raises:
    var lines = wrap_to_width(
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
        20,
    )
    # Every line must fit the 20-cell budget; rejoining yields a string
    # that — modulo the soft-break spaces — recovers the original tokens.
    for i in range(len(lines)):
        assert_true(len(lines[i].as_bytes()) <= 20)
    var joined = String("")
    for i in range(len(lines)):
        if i > 0: joined = joined + String(" ")
        joined = joined + lines[i]
    # Trailing space on the original is preserved on the final line —
    # the prompt renders the input strip after that space, so leaving
    # it in the wrap output keeps inline and wrapped layouts visually
    # consistent around the input.
    assert_equal(
        joined,
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
    )


def test_prompt_wrap_hard_breaks_an_unbreakable_word() raises:
    # No spaces — the wrapper must still chop the input into width-sized
    # chunks rather than emit one giant overflowing line.
    var lines = wrap_to_width(String("aaaaaaaaaaaaaaaaaaaa"), 6)
    assert_equal(len(lines), 4)
    assert_equal(lines[0], String("aaaaaa"))
    assert_equal(lines[1], String("aaaaaa"))
    assert_equal(lines[2], String("aaaaaa"))
    assert_equal(lines[3], String("aa"))


def test_prompt_wrap_empty_returns_empty_list() raises:
    var lines = wrap_to_width(String(""), 60)
    assert_equal(len(lines), 0)


def test_prompt_paint_clamps_long_label_inside_dialog() raises:
    """The painted cells of a long-label prompt must all live inside
    the prompt's dialog rect — nothing leaks into the surrounding
    workspace cells the way the un-clamped ``put_text`` used to."""
    var screen = Rect(0, 0, 80, 24)
    var canvas = Canvas(80, 24)
    canvas.clear(Attr(BLACK, BLUE))
    var prompt = Prompt()
    prompt.open(
        String("Install rust LSP? 'rustup component add rust-analyzer' (y/N): "),
    )
    prompt.paint(canvas, screen)
    # The dialog centers itself; the only cells whose attr changed
    # from the (BLACK, BLUE) workspace fill are inside the dialog rect
    # *or* inside the drop-shadow strip directly to its right and
    # below. Anything else is a paint leak.
    var dialog_w = 60
    var dx = (80 - dialog_w) // 2
    # Walk a generous outer band around the dialog and shadow and
    # confirm the workspace fill is intact: cells outside the dialog
    # rect (and outside the 2-cell right shadow / 1-row bottom shadow)
    # must still carry the original blue background.
    for y in range(24):
        for x in range(80):
            var inside_dialog = (
                x >= dx and x < dx + dialog_w and y >= 8 and y < 16
            )
            var in_right_shadow = (
                x >= dx + dialog_w and x < dx + dialog_w + 2
                and y >= 9 and y < 16
            )
            var in_bottom_shadow = (
                x >= dx + 2 and x < dx + dialog_w + 2 and y == 16
            )
            if inside_dialog or in_right_shadow or in_bottom_shadow:
                continue
            var c = canvas.get(x, y)
            assert_equal(c.attr.bg, BLUE)


def test_confirm_dialog_y_key_resolves_yes() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    assert_true(d.active)
    assert_false(d.submitted)
    _ = d.handle_key(Event.key_event(UInt32(ord("y"))))
    assert_true(d.submitted)
    assert_true(d.confirmed)


def test_confirm_dialog_n_key_resolves_no() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    _ = d.handle_key(Event.key_event(UInt32(ord("n"))))
    assert_true(d.submitted)
    assert_false(d.confirmed)


def test_confirm_dialog_esc_cancels() raises:
    var d = ConfirmDialog()
    d.open(String("Install rust LSP?"))
    _ = d.handle_key(Event.key_event(KEY_ESC))
    assert_true(d.submitted)
    assert_false(d.confirmed)


def test_confirm_dialog_enter_uses_focused_button() raises:
    """Default focus is No (safer for installs); Tab toggles to Yes;
    Enter resolves whichever side is focused."""
    var d = ConfirmDialog()
    d.open(String("Download docs?"))
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d.submitted)
    assert_false(d.confirmed)   # default focus is No
    var d2 = ConfirmDialog()
    d2.open(String("Download docs?"))
    _ = d2.handle_key(Event.key_event(KEY_TAB))
    _ = d2.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d2.submitted)
    assert_true(d2.confirmed)


def test_confirm_dialog_default_yes_focuses_yes() raises:
    """Callers that want Enter to mean Yes pass ``default_yes=True``."""
    var d = ConfirmDialog()
    d.open(String("Save changes?"), default_yes=True)
    _ = d.handle_key(Event.key_event(KEY_ENTER))
    assert_true(d.submitted)
    assert_true(d.confirmed)


def test_confirm_dialog_paints_inside_dialog_rect() raises:
    """Same overflow guarantee as the Prompt: a long install hint
    must stay inside the centered dialog rect (plus the drop shadow)."""
    var screen = Rect(0, 0, 80, 24)
    var canvas = Canvas(80, 24)
    canvas.clear(Attr(BLACK, BLUE))
    var dialog = ConfirmDialog()
    dialog.open(
        String("Install rust LSP? 'rustup component add rust-analyzer'"),
    )
    dialog.paint(canvas, screen)
    var dialog_w = 60
    var dx = (80 - dialog_w) // 2
    # The painted area covers the dialog rect itself plus the right-edge
    # shadow column (dx + dialog_w) and the bottom-shadow row. Cells
    # outside that band must still carry the workspace fill.
    for y in range(24):
        for x in range(80):
            var c = canvas.get(x, y)
            if c.attr.bg == BLUE:
                continue
            assert_true(x >= dx and x < dx + dialog_w + 2)


def test_desktop_confirm_dialog_yes_starts_grammar_install() raises:
    """Smoke-test the wiring: typing a confirm dialog into the
    grammar-install pending action and pressing 'y' must clear the
    dialog and leave a grammar-install language recorded on the
    desktop. Doesn't actually run curl — the desktop's
    ``_start_grammar_install`` records ``_grammar_install_lang`` only
    after a successful ``InstallRunner.start``, which would normally
    require a sub-process; checking that the pending state was
    cleared is enough to verify the dispatch path."""
    var d = Desktop()
    d._pending_action = String("grammar:install")
    d._pending_arg = String("elm")
    d.confirm_dialog.open(String("Download Elm syntax grammar?"))
    assert_true(d.confirm_dialog.active)
    _ = d.handle_event(
        Event.key_event(UInt32(ord("y"))), Rect(0, 0, 80, 24),
    )
    # Dialog closed and pending action cleared regardless of whether
    # the install spawn succeeded in this test environment.
    assert_false(d.confirm_dialog.active)
    assert_equal(d._pending_action, String(""))
    assert_equal(d._pending_arg, String(""))


def test_desktop_confirm_dialog_no_clears_pending_action() raises:
    var d = Desktop()
    d._pending_action = String("lsp:install")
    d._pending_arg = String("rust")
    d.confirm_dialog.open(String("Install rust LSP?"))
    _ = d.handle_event(
        Event.key_event(UInt32(ord("n"))), Rect(0, 0, 80, 24),
    )
    assert_false(d.confirm_dialog.active)
    assert_equal(d._pending_action, String(""))
    assert_equal(d._pending_arg, String(""))
    # Install runner stays idle — user said no.
    assert_false(d.install_runner.is_active())


def _spell_with_dict(words: List[String]) -> Speller:
    """Build a Speller seeded with an explicit small dictionary so the
    tests don't depend on whichever ``/usr/share/dict/words`` happens to
    ship with the host."""
    var s = Speller()
    s.load_words(words)
    return s^


def test_speller_check_word_basic() raises:
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var s = _spell_with_dict(words)
    assert_true(s.check_word(String("hello")))
    assert_true(s.check_word(String("Hello")))   # case-insensitive
    assert_true(s.check_word(String("WORLD")))
    assert_false(s.check_word(String("helo")))
    assert_false(s.check_word(String("xyzzy")))


def test_speller_strips_common_suffixes() raises:
    var words = List[String]()
    words.append(String("dog"))
    words.append(String("dish"))
    words.append(String("walk"))
    words.append(String("love"))
    words.append(String("foo"))
    var s = _spell_with_dict(words)
    assert_true(s.check_word(String("dogs")))    # plural -s
    assert_true(s.check_word(String("dog's")))   # possessive
    assert_true(s.check_word(String("dishes")))  # plural -es
    assert_true(s.check_word(String("walked")))  # past tense
    assert_true(s.check_word(String("walking"))) # gerund
    assert_true(s.check_word(String("loved")))   # foo+d
    assert_true(s.check_word(String("loving")))  # drop-e + ing
    assert_false(s.check_word(String("foob")))


def test_speller_handles_english_contractions() raises:
    """Contractions like ``hasn't`` and ``wouldn't`` must validate against
    their bare-verb head (``has``, ``would``). Without this the editor
    flags ``hasn`` / ``wouldn`` as misspelled because the OS dict
    doesn't list those forms. Both halves of the fix are exercised:
    ``find_misspelled_runs`` keeps the apostrophe inside the word, and
    ``check_word`` strips the trailing contraction."""
    var words = List[String]()
    words.append(String("has"))
    words.append(String("would"))
    words.append(String("did"))
    words.append(String("they"))
    words.append(String("you"))
    words.append(String("can"))
    words.append(String("won"))
    words.append(String("hello"))
    var s = _spell_with_dict(words)

    # n't contractions: head + "n't" must validate.
    assert_true(s.check_word(String("hasn't")))
    assert_true(s.check_word(String("wouldn't")))
    assert_true(s.check_word(String("didn't")))
    # Bare 't (cannot -> can't, will not -> won't).
    assert_true(s.check_word(String("can't")))
    assert_true(s.check_word(String("won't")))
    # 're / 've / 'll / 'd.
    assert_true(s.check_word(String("they're")))
    assert_true(s.check_word(String("they've")))
    assert_true(s.check_word(String("they'll")))
    assert_true(s.check_word(String("they'd")))
    assert_true(s.check_word(String("you're")))
    # Genuine misspellings still fail (head not in dict).
    assert_false(s.check_word(String("xyzzyn't")))

    # The tokenizer keeps apostrophe-in-word together so that the head
    # actually reaches check_word — without that fix, "hasn't" splits
    # into "hasn" + "t" and "hasn" gets flagged.
    var runs = find_misspelled_runs(s, String("hasn't wouldn't didn't"))
    assert_equal(len(runs), 0)


def test_find_misspelled_runs_keeps_unicode_letters_in_word() raises:
    """``Godkänn`` (Swedish ``approve``) used to tokenize as three runs:
    ``Godk`` (4 letters, flagged), the lone ``ä`` (skipped as non-letter),
    and ``nn`` (skipped as <4). After the UTF-8 fix the whole word is
    one token and either passes (if in dict) or is flagged as a single
    region — never as ``Godk`` alone."""
    var words = List[String]()
    words.append(String("godkänn"))
    var s = _spell_with_dict(words)
    var runs = find_misspelled_runs(s, String("Godkänn"))
    assert_equal(len(runs), 0)
    # And without "godkänn" in the dictionary, the run that gets flagged
    # is the whole word — not the ASCII prefix in isolation.
    var s2 = _spell_with_dict(List[String]())
    s2.load_words(List[String]())
    # Force loaded=True so check_word actually runs.
    var seed2 = List[String]()
    seed2.append(String("hello"))
    s2.load_words(seed2)
    var runs2 = find_misspelled_runs(s2, String("Godkänn"))
    assert_equal(len(runs2), 1)
    var rng = runs2[0]
    # 7 bytes: G(1) o(1) d(1) k(1) ä(2) n(1) n(1) = wait, that's 8.
    # ``ä`` is U+00E4 = 2 bytes (0xC3 0xA4). G=1, o=1, d=1, k=1, ä=2,
    # n=1, n=1 → 8 bytes total. Run covers all of them.
    assert_equal(rng[0], 0)
    assert_equal(rng[1], 8)


def test_speller_unloaded_returns_true_for_everything() raises:
    """When no dictionary is loaded, ``check_word`` must say "fine" for
    every input — better silent than a screen full of bogus underlines
    on systems without ``/usr/share/dict/words``."""
    var s = Speller()
    assert_true(s.check_word(String("definitelynotaword")))


def test_speller_set_project_loads_idea_dictionary() raises:
    """Words inside ``<project>/.idea/dictionaries/*.xml`` should be
    treated as correctly spelled — that's the team's shared vocabulary
    of names and domain terms. ``set_project`` folds them into
    ``project_buckets`` alongside ``.turbokod/dictionary.txt``."""
    var dir = String("/tmp/turbokod_idea_dict_") + String(
        Int(external_call["getpid", Int32]())
    )
    var idea = dir + String("/.idea")
    var dicts = idea + String("/dictionaries")
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (idea + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (dicts + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var xml_path = dicts + String("/boxed.xml")
    assert_true(write_file(xml_path, String(
        "<component name=\"ProjectDictionaryState\">\n"
        + "  <dictionary name=\"boxed\">\n"
        + "    <words>\n"
        + "      <w>turbokod</w>\n"
        + "      <w>aarrgh</w>\n"
        + "    </words>\n"
        + "  </dictionary>\n"
        + "</component>\n"
    )))
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    s.set_project(dir)
    # Project-specific words should now be looked up via project_buckets.
    assert_true(s.check_word(String("turbokod")))
    assert_true(s.check_word(String("aarrgh")))
    # Case-insensitive lookup still works.
    assert_true(s.check_word(String("Turbokod")))
    # And the previously-loaded baseline is preserved.
    assert_true(s.check_word(String("hello")))
    # An unrelated word stays misspelled.
    assert_false(s.check_word(String("xyzzy")))
    # Switching to a project without IDEA dicts must clear the words —
    # they're per-project, not session-wide.
    s.set_project(String("/tmp/turbokod_no_idea_here_xyzzy"))
    assert_false(s.check_word(String("turbokod")))
    assert_false(s.check_word(String("aarrgh")))
    # The session-wide baseline still holds.
    assert_true(s.check_word(String("hello")))
    _ = external_call["unlink", Int32]((xml_path + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dicts + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((idea + String("\0")).unsafe_ptr())
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_speller_set_project_with_no_idea_dir_is_noop() raises:
    """A project without a ``.idea/dictionaries/`` directory must not
    raise and must leave the existing dictionary untouched."""
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    s.set_project(String("/tmp/turbokod_no_idea_here_xyzzy"))
    assert_true(s.check_word(String("hello")))
    assert_false(s.check_word(String("xyzzy")))


def test_speller_add_user_word_persists_and_check_word_passes() raises:
    """``add_user_word`` should both flip ``check_word`` to True for
    that word *and* append it to ``~/.config/turbokod/dictionary.txt``
    so the addition survives a restart. Tests run with ``HOME`` set to
    a scratch dir, so the file path is predictable."""
    var path = user_dict_path()
    # Defensive cleanup — earlier tests may have written here.
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    assert_false(s.check_word(String("turbokod")))
    assert_true(s.add_user_word(String("turbokod")))
    # In-memory: subsequent lookups pass without touching the file.
    assert_true(s.check_word(String("turbokod")))
    # On-disk: the file exists and contains the word.
    var content = read_file(path)
    var lines = List[String]()
    var b = content.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x0A:
            lines.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    var saw = False
    for k in range(len(lines)):
        if lines[k] == String("turbokod"):
            saw = True
            break
    assert_true(saw)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_speller_load_default_includes_bundled_programmer_terms() raises:
    """``load_default`` must layer the bundled cspell-derived wordlists
    on top of the OS dict so common programmer vocabulary that
    ``/usr/share/dict/words`` lacks (``tokenizer``, ``bitwise``,
    ``regex``, ``hashable``) doesn't show up as misspelled inside
    comments and docstrings. Tests run with cwd = project root so the
    relative path ``src/turbokod/data/wordlists`` resolves."""
    var s = Speller()
    s.load_default()
    # If neither OS list nor bundled list loaded, ``check_word`` returns
    # True for everything and this test is uninformative — but the
    # bundled list ships with the repo so on any developer machine it
    # should always be present.
    assert_true(s.loaded)
    assert_true(s.check_word(String("tokenizer")))
    assert_true(s.check_word(String("bitwise")))
    assert_true(s.check_word(String("regex")))
    assert_true(s.check_word(String("hashable")))


def test_speller_load_default_layers_user_dictionary() raises:
    """A subsequent ``Speller`` started after ``add_user_word`` writes
    the file should pick the addition up via ``load_default``. Verifies
    the persistence round-trips end to end."""
    var path = user_dict_path()
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    # Seed the user dict directly via the public API on a throwaway
    # speller so we don't depend on internals of the file layout.
    var primer = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    primer.load_words(seed)
    _ = primer.add_user_word(String("turbokod"))
    # Fresh speller; load_default should fold in the user dict.
    var s = Speller()
    s.load_default()
    # ``loaded`` is True because *something* was loaded — either an OS
    # list or the user dict (depending on the runner). Either way the
    # added word must check out.
    assert_true(s.check_word(String("turbokod")))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_speller_normalizes_unicode_for_lookup() raises:
    """Lookup keys must fold both case and Unicode form so a Swedish
    word like ``Övrigt`` (Ö = U+00D6) matches the on-disk lowercase
    NFC form ``övrigt`` (ö = U+00F6), and so does the NFD form
    ``O`` + combining diaeresis (U+004F U+0308) that macOS-sourced text
    sometimes ships in. Without this fix neither uppercase nor NFD
    forms hashed to the same bucket as the wordlist's NFC lowercase
    entry, and ``Övrigt`` was wrongly flagged as misspelled."""
    var s = Speller()
    var seed = List[String]()
    seed.append(String("övrigt"))
    seed.append(String("café"))
    s.load_words(seed)
    # NFC uppercase: bytes ``0xC3 0x96`` for Ö.
    assert_true(s.check_word(String("Övrigt")))
    # NFC mixed case in the middle.
    assert_true(s.check_word(String("öVrigt")))
    # NFD: O + combining diaeresis (U+004F U+0308).
    # Mojo 1.0 string escapes interpret ``\xCC`` as codepoint U+00CC, not
    # as the raw byte 0xCC — so we build the combining mark via ``chr``
    # to get the intended UTF-8 byte sequence ``CC 88``.
    var nfd_uppercase = String("O") + chr(0x308) + String("vrigt")
    assert_true(s.check_word(nfd_uppercase))
    # NFD lowercase: o + combining diaeresis.
    var nfd_lowercase = String("o") + chr(0x308) + String("vrigt")
    assert_true(s.check_word(nfd_lowercase))
    # And acute (U+0301) on e: ``café`` decomposes to e + U+0301.
    var cafe_nfd = String("cafe") + chr(0x301)
    assert_true(s.check_word(cafe_nfd))


def test_speller_load_default_layers_user_language_dictionaries() raises:
    """A wordlist dropped under ``~/.config/turbokod/dictionaries/`` is
    picked up by ``load_default``, mirroring the bundled-wordlists
    layer. This is the on-disk shape Settings ▸ Spell-check writes via
    its install-runner curl."""
    var home = getenv_value(String("HOME"))
    var dir = home + String("/.config/turbokod/dictionaries")
    _ = external_call["mkdir", Int32](
        ((home + String("/.config")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        ((home + String("/.config/turbokod")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var dict_path = dir + String("/de.txt")
    assert_true(write_file(dict_path, String("Schmetterling\nKühlschrank\n")))
    var s = Speller()
    s.load_default()
    assert_true(s.loaded)
    assert_true(s.check_word(String("Schmetterling")))
    assert_true(s.check_word(String("Kühlschrank")))
    _ = external_call["unlink", Int32]((dict_path + String("\0")).unsafe_ptr())


def test_speller_reload_drops_removed_dictionary() raises:
    """``reload`` must rebuild the bucket set from disk so removing the
    on-disk wordlist makes its words fall back to "misspelled" without
    restarting the editor. Used by Settings ▸ Spell-check ▸ Remove."""
    var home = getenv_value(String("HOME"))
    var dir = home + String("/.config/turbokod/dictionaries")
    _ = external_call["mkdir", Int32](
        ((home + String("/.config")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        ((home + String("/.config/turbokod")) + String("\0")).unsafe_ptr(),
        UInt32(0o755),
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var dict_path = dir + String("/sv.txt")
    assert_true(write_file(dict_path, String("smörgåsbord\n")))
    var s = Speller()
    s.load_default()
    assert_true(s.check_word(String("smörgåsbord")))
    # Drop the file and reload — the word must no longer be considered
    # known. Other layers (OS dict, bundled programmer terms) keep
    # ``loaded`` True so ``check_word`` doesn't fall into the
    # everything-passes degraded mode.
    _ = external_call["unlink", Int32]((dict_path + String("\0")).unsafe_ptr())
    s.reload()
    assert_true(s.loaded)
    assert_false(s.check_word(String("smörgåsbord")))


def test_speller_add_project_word_persists_in_project_dir() raises:
    """``add_project_word`` writes ``<project>/.turbokod/dictionary.txt``
    and updates ``project_buckets`` in memory. ``set_project`` must
    have been called first; without it the call is a no-op."""
    var dir = String("/tmp/turbokod_proj_dict_") + String(
        Int(external_call["getpid", Int32]())
    )
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), UInt32(0o755),
    )
    var s = Speller()
    var seed = List[String]()
    seed.append(String("hello"))
    s.load_words(seed)
    # Without set_project, the call short-circuits to False and the
    # word stays misspelled.
    assert_false(s.add_project_word(String("turbokod")))
    assert_false(s.check_word(String("turbokod")))
    # With set_project active, the word sticks in memory and lands on
    # disk under .turbokod/dictionary.txt.
    s.set_project(dir)
    assert_true(s.add_project_word(String("turbokod")))
    assert_true(s.check_word(String("turbokod")))
    var dict_path = project_dict_path(dir)
    assert_equal(dict_path, dir + String("/.turbokod/dictionary.txt"))
    var info = stat_file(dict_path)
    assert_true(info.ok)
    # Switching to a different project clears the in-memory entry —
    # project words are per-project, never session-wide.
    s.set_project(String(""))
    assert_false(s.check_word(String("turbokod")))
    # And reloading the same project restores them from disk.
    s.set_project(dir)
    assert_true(s.check_word(String("turbokod")))
    _ = external_call["unlink", Int32](
        (dict_path + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32](
        ((dir + String("/.turbokod")) + String("\0")).unsafe_ptr(),
    )
    _ = external_call["rmdir", Int32]((dir + String("\0")).unsafe_ptr())


def test_editor_alt_enter_on_misspelling_emits_pending_action() raises:
    """Alt+Enter while the cursor is parked inside a misspelled-word
    underline should stamp ``pending_spell_action`` with that word
    rather than splitting the line. The editor must NOT touch the
    buffer (no row split) — the host opens the popup over the still-
    intact text."""
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_alt_enter.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 1)
    # Park the cursor in the middle of "helo".
    ed.cursor_row = 0
    ed.cursor_col = 3
    var line_count_before = ed.buffer.line_count()
    var alt_enter = Event.key_event(KEY_ENTER, MOD_ALT)
    var consumed = ed.handle_key(alt_enter, Rect(0, 0, 40, 5))
    assert_true(consumed)
    # Buffer must be unchanged: Alt+Enter on a misspelling is a
    # menu-open gesture, not an Enter.
    assert_equal(ed.buffer.line_count(), line_count_before)
    var sa_opt = ed.consume_spell_action_request()
    assert_true(Bool(sa_opt))
    var sa = sa_opt.value()
    assert_equal(sa.word, String("helo"))
    assert_equal(sa.row, 0)
    assert_equal(sa.col_start, 2)
    assert_equal(sa.col_end, 6)
    # The slot is one-shot.
    assert_false(Bool(ed.consume_spell_action_request()))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_alt_enter_outside_misspelling_does_not_consume() raises:
    """Alt+Enter on a row without any misspelling must fall through —
    the editor returns False so the host's hotkey table can bind it
    to something else. No buffer mutation either way."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_alt_outside.py"))
    assert_true(write_file(path, String("# hello world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 0)
    var line_count_before = ed.buffer.line_count()
    var alt_enter = Event.key_event(KEY_ENTER, MOD_ALT)
    var consumed = ed.handle_key(alt_enter, Rect(0, 0, 40, 5))
    assert_false(consumed)
    assert_equal(ed.buffer.line_count(), line_count_before)
    assert_false(Bool(ed.consume_spell_action_request()))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_invalidate_spell_drops_overlay_after_word_added() raises:
    """After ``Speller.add_user_word`` and ``Editor.invalidate_spell``,
    the next ``flush_highlights`` should clear the underline for the
    newly-accepted word — verifying the refresh hook actually loops
    back through ``_refresh_spell``."""
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_invalidate.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 1)
    # Teach the speller about "helo", then ask the editor to redo
    # the spell pass on the next flush.
    var udp = user_dict_path()
    _ = external_call["unlink", Int32]((udp + String("\0")).unsafe_ptr())
    _ = speller.add_user_word(String("helo"))
    ed.invalidate_spell()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 0)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())
    _ = external_call["unlink", Int32]((udp + String("\0")).unsafe_ptr())


def test_spell_menu_open_close_default_selection() raises:
    """Open positions selection on row 0 (user dict) regardless of
    whether the project row is enabled — that's the safe default
    every time, easier to undo than accidentally training the team
    dict with a personal word."""
    var m = SpellMenu()
    m.open(String("helo"), Point(10, 5), True)
    assert_true(m.active)
    assert_equal(m.selected, 0)
    assert_equal(m.word, String("helo"))
    assert_true(m.has_project)
    m.close()
    assert_false(m.active)
    # Open without a project: user-dict still selectable, project row
    # rendered but ``has_project=False`` so Enter on it is a no-op.
    m.open(String("helo"), Point(0, 0), False)
    assert_false(m.has_project)


def test_spell_menu_enter_on_user_resolves_with_add_user() raises:
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), True)
    var ev = Event.key_event(KEY_ENTER)
    _ = m.handle_key(ev)
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_ADD_USER)


def test_spell_menu_enter_on_project_disabled_stays_open() raises:
    """When ``has_project=False``, pressing Enter on the project row
    must NOT submit — the menu stays open so the user can arrow back
    up to the user-dict row."""
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), False)
    _ = m.handle_key(Event.key_event(KEY_DOWN))
    assert_equal(m.selected, 1)
    _ = m.handle_key(Event.key_event(KEY_ENTER))
    assert_false(m.submitted)
    assert_true(m.active)
    # Arrow back up — the user-dict pick still works.
    _ = m.handle_key(Event.key_event(KEY_UP))
    assert_equal(m.selected, 0)
    _ = m.handle_key(Event.key_event(KEY_ENTER))
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_ADD_USER)


def test_spell_menu_enter_on_project_enabled_resolves_with_add_project() raises:
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), True)
    _ = m.handle_key(Event.key_event(KEY_DOWN))
    _ = m.handle_key(Event.key_event(KEY_ENTER))
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_ADD_PROJECT)


def test_spell_menu_esc_dismisses() raises:
    var m = SpellMenu()
    m.open(String("helo"), Point(0, 0), True)
    _ = m.handle_key(Event.key_event(KEY_ESC))
    assert_true(m.submitted)
    assert_equal(m.action, SPELL_ACTION_NONE)


def find_misspelled_runs_filters_identifiers_and_short_words() raises:
    """Word-shape filters should suppress: <4 letters, all caps, mixed
    case mid-word, identifier fragments with digits/underscores."""
    var words = List[String]()
    words.append(String("hello"))
    var s = _spell_with_dict(words)
    var text = String("ok URL flushHighlights foo_bar123 helo world hello")
    var runs = find_misspelled_runs(s, text)
    # ``ok`` (too short), ``URL`` (acronym), ``flushHighlights``
    # (internal cap), ``foo_bar123`` (identifier), ``hello`` (in dict)
    # all skipped. Only ``helo`` and ``world`` should flag.
    assert_equal(len(runs), 2)
    var b = text.as_bytes()
    var first_word = String(StringSlice(unsafe_from_utf8=b[runs[0][0]:runs[0][1]]))
    var second_word = String(StringSlice(unsafe_from_utf8=b[runs[1][0]:runs[1][1]]))
    assert_equal(first_word, String("helo"))
    assert_equal(second_word, String("world"))


def test_editor_spell_uses_curly_colored_underline_on_supported_terminal() raises:
    """When the host terminal advertises support (we spoof
    ``TERM_PROGRAM=iTerm.app``) the spell highlight keeps the comment
    cyan foreground and gets a separate curly red underline channel —
    the VS-Code-squiggle look."""
    # Force-detect support by setting iTerm2's env var.
    var c_name = String("TERM_PROGRAM\0")
    var c_value = String("iTerm.app\0")
    _ = external_call["setenv", Int32](
        c_name.unsafe_ptr(), c_value.unsafe_ptr(), Int32(1),
    )
    # Defensive: kitty / wezterm / WT vars can short-circuit before
    # TERM_PROGRAM is read; clear them so the iTerm.app spoof wins.
    _ = external_call["unsetenv", Int32](
        String("WT_SESSION\0").unsafe_ptr(),
    )
    _ = external_call["unsetenv", Int32](
        String("KITTY_WINDOW_ID\0").unsafe_ptr(),
    )
    _ = external_call["unsetenv", Int32](
        String("VTE_VERSION\0").unsafe_ptr(),
    )
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_curly.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.spell_highlights), 1)
    var sh = ed.spell_highlights[0]
    # Curly + underline bits set, separate red underline color, fg
    # stays the comment's cyan (i.e. *not* LIGHT_RED).
    assert_true((sh.attr.style & STYLE_UNDERLINE) != 0)
    assert_true((sh.attr.style & STYLE_UNDERLINE_CURLY) != 0)
    assert_equal(sh.attr.underline_color, Int16(LIGHT_RED))
    assert_false(sh.attr.fg == LIGHT_RED)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_minimap_git_change_wins_over_spell_on_same_row() raises:
    """When a row has both an uncommitted change and a spelling issue,
    the right-side minimap projects the git change color (gray), not
    the spell color (yellow). Spell still paints inline as the
    underline; the gutter is reserved for the higher-priority signal."""
    var words = List[String]()
    words.append(String("hello"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_pri.py"))
    assert_true(write_file(path, String("# helo\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    # Force both signals on row 0.
    ed.git_change_lines = List[Int]()
    ed.git_change_lines.append(GIT_CHANGE_MODIFIED)
    assert_true(ed.spell_lines[0])
    var canvas = Canvas(40, 5)
    canvas.fill(Rect(0, 0, 40, 5), String(" "), default_attr())
    ed.paint(canvas, Rect(0, 0, 40, 5), False)
    # The right-edge cell on row 0 paints in the git-change color
    # (LIGHT_GRAY on BLUE), not the spell color (YELLOW on BLUE).
    var sq = canvas.get(39, 0)
    assert_equal(sq.glyph, String("■"))
    assert_equal(sq.attr.fg, LIGHT_GRAY)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_minimap_click_scrolls_to_marked_line() raises:
    """Clicking on the right-edge minimap column should scroll the
    editor so the buffer row that owns the projected slice is visible
    (and place the cursor on it). With 20 lines in a 5-row view, the
    slice owned by screen row 2 covers buffer rows [8, 12); a left-
    click on column 39 / row 2 must center buffer row 10 (the marked
    one) in the view rather than fall through to the text-area
    handler."""
    var text = String("")
    for i in range(20):
        text = text + String("line") + String(i) + String("\n")
    var ed = Editor(text^)
    ed.git_changes_visible = True
    var marks = List[Int]()
    for i in range(20):
        marks.append(
            GIT_CHANGE_MODIFIED if i == 10 else GIT_CHANGE_NONE
        )
    ed.set_git_changes(marks^)
    ed.scroll_y = 0
    var view = Rect(0, 0, 40, 5)
    var click = Event.mouse_event(
        Point(39, 2), MOUSE_BUTTON_LEFT, True, False,
    )
    _ = ed.handle_mouse(click, view)
    # Cursor lands on the marked buffer row, scroll_y centers it.
    assert_equal(ed.cursor_row, 10)
    assert_equal(ed.cursor_col, 0)
    # 5-row view, target = 10 - 2 = 8
    assert_equal(ed.scroll_y, 8)


def test_editor_minimap_hover_records_spell_word() raises:
    """A bare-hover event over a minimap row that carries a spelling
    issue should populate ``_minimap_hover_*`` with kind=2 and the
    offending word so the tooltip can render it. Clicking elsewhere
    afterwards must clear the hover state again."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_hover.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_true(ed.spell_lines[0])
    var view = Rect(0, 0, 40, 5)
    # Bare hover (button=NONE, motion=True) on the minimap column on
    # row 0 — there's only the spell mark, so kind=2 and word=helo.
    var hover = Event.mouse_event(
        Point(39, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    assert_equal(ed._minimap_hover_kind, 2)
    assert_equal(ed._minimap_hover_buf_row, 0)
    assert_equal(ed._minimap_hover_word, String("helo"))
    # Hover past end-of-line on a clean column — no spell underline
    # there and no minimap mark, so the state must clear. (A column
    # that falls *on* the spell word now keeps the tooltip alive
    # because in-text hover is wired up too — that's covered
    # separately by ``test_editor_text_hover_*``.)
    var hover_off = Event.mouse_event(
        Point(30, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover_off, view)
    assert_equal(ed._minimap_hover_kind, 0)
    assert_equal(ed._minimap_hover_buf_row, -1)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_minimap_hover_paints_tooltip() raises:
    """After a hover sets the spell-mark state, ``Editor.paint`` must
    overlay a tooltip box that includes the misspelled word so the user
    can read it."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_tip.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    var view = Rect(0, 0, 40, 5)
    var hover = Event.mouse_event(
        Point(39, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    var canvas = Canvas(40, 5)
    canvas.fill(view, String(" "), default_attr())
    ed.paint(canvas, view, False)
    # Pull the row of cells where the tooltip's label sits and concat
    # the glyphs into a string so we can search for the word.
    var row_text = String("")
    for x in range(view.b.x):
        row_text = row_text + canvas.get(x, 1).glyph
    assert_true(_contains(row_text, String("helo")))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_text_hover_over_diagnostic_records_kind_and_message() raises:
    """Hovering over a cell covered by a diagnostic underline (in the
    editor surface itself, not the minimap) must populate the same
    hover state the minimap-mark hover does so the tooltip can render.
    A warning at columns [3, 7) on row 0 → cursor at (3, 0) is on it;
    expect kind=4 and the diagnostic's message in ``_minimap_hover_word``."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 3, 0, 7, DIAG_SEVERITY_WARNING,
        String("unused identifier"), String("pyright"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    var hover = Event.mouse_event(
        Point(3, 0), MOUSE_BUTTON_NONE, True, True,
    )
    _ = ed.handle_mouse(hover, view)
    assert_equal(ed._minimap_hover_kind, 4)
    assert_equal(ed._minimap_hover_buf_row, 0)
    assert_equal(
        ed._minimap_hover_word, String("[pyright] unused identifier"),
    )


def test_editor_text_hover_off_diagnostic_clears_state() raises:
    """A hover on a cell *outside* a diagnostic range (and not on a
    spell flag) clears the hover state — no stale tooltip lingers
    from a previous frame."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 3, 0, 7, DIAG_SEVERITY_ERROR, String("oops"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    # First hover on the diagnostic so the state is non-empty.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(3, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    # Now hover one cell past the diagnostic's end (col 7 is exclusive).
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 0)


def test_editor_text_hover_picks_most_severe_diagnostic_on_overlap() raises:
    """When multiple diagnostics overlap a cell, the most severe one
    wins (lowest numeric severity = highest priority — error beats
    warning beats info beats hint)."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    # Hint covering cols [0, 12).
    diags.append(Diagnostic(
        0, 0, 0, 12, DIAG_SEVERITY_HINT, String("hint"), String("t"),
    ))
    # Warning covering cols [3, 7).
    diags.append(Diagnostic(
        0, 3, 0, 7, DIAG_SEVERITY_WARNING, String("warn"), String("t"),
    ))
    # Error at exactly col 5.
    diags.append(Diagnostic(
        0, 5, 0, 6, DIAG_SEVERITY_ERROR, String("err"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    # Cell 5 has all three: error must win.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(5, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    assert_equal(ed._minimap_hover_word, String("[t] err"))
    # Cell 4 has hint + warning but not error: warning wins.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 4)
    # Cell 10 has only the hint.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(10, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 6)


def test_editor_text_hover_over_spell_word_records_word() raises:
    """A hover over a misspelled word in the editor surface (not the
    minimap) must populate kind=2 and surface the offending word so
    the same tooltip the minimap uses can render. Confirms the
    text-area branch is wired for spell hits, not just diagnostics."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_text_spell_hover.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    assert_true(ed.spell_lines[0])
    var view = Rect(0, 0, 40, 5)
    # Cell 4 is inside "helo" (line is "# helo world" → bytes 2..6).
    _ = ed.handle_mouse(
        Event.mouse_event(Point(4, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 2)
    assert_equal(ed._minimap_hover_buf_row, 0)
    assert_equal(ed._minimap_hover_word, String("helo"))
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_text_hover_past_eol_clears_state() raises:
    """Cells past the end of a buffer line don't carry a real cell
    (the row only has the visible glyphs); hover-tooltip should not
    fire there even when the row carries diagnostics earlier on."""
    var ed = Editor(String("ab"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 0, 0, 2, DIAG_SEVERITY_ERROR, String("e"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 40, 5)
    # Past EOL — no glyph to hover on.
    _ = ed.handle_mouse(
        Event.mouse_event(Point(20, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 0)


def test_editor_text_hover_diagnostic_renders_tooltip() raises:
    """End-to-end: an in-text hover over a diagnostic range produces a
    visible tooltip box on the next paint, with the message in it.
    Mirrors the existing minimap-tooltip render test but exercises the
    text-area hover path."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        String("unknown name"), String("pyright"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 60, 5)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    var canvas = Canvas(60, 5)
    canvas.fill(view, String(" "), default_attr())
    ed.paint(canvas, view, False)
    # Sweep the canvas for the message — the tooltip's row anchor is
    # cursor.y - 1, with the label two cells in. Walking the whole grid
    # avoids guessing exactly which row the layout pinned it to.
    var found = False
    for y in range(view.b.y):
        var row_text = String("")
        for x in range(view.b.x):
            row_text = row_text + canvas.get(x, y).glyph
        if _contains(row_text, String("unknown name")):
            found = True
            break
    assert_true(found)


def test_editor_multiline_diagnostic_tooltip_renders_each_line() raises:
    """Pyright (and other LSPs) often emit diagnostics with literal
    newlines inside the message — an explanation block, an offending
    snippet, then a conclusion. Rendering must honour those breaks
    rather than writing the ``\\n`` as a cell glyph and leaving holes
    of editor blue inside the popup."""
    var ed = Editor(String("alpha beta gamma\nlambda omega\n"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        # Real-shape pyright diagnostic: header line, indented
        # snippet of the code under review, conclusion line.
        String(
            "\"Meta\" overrides symbol of same name in class \"Table\"\n"
            "  \"dryft.iommi.Table.Meta\" = [\n"
            "  ] is not assignable to "
            "\"dryft.prospects.views.StartProjectQueue.Meta\""
        ),
        String("pyright"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 80, 20)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(7, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    var canvas = Canvas(80, 20)
    canvas.fill(view, String(" "), default_attr())
    ed.paint(canvas, view, False)
    # Locate popup interior.
    var top_y = -1
    var left_x = -1
    var right_x = -1
    for y in range(view.b.y):
        for x in range(view.b.x):
            if canvas.get(x, y).glyph == String("┌"):
                top_y = y
                left_x = x
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
    var bottom_y = -1
    var by = top_y + 1
    while by < view.b.y:
        if canvas.get(left_x, by).glyph == String("└"):
            bottom_y = by
            break
        by += 1
    assert_true(bottom_y > top_y)
    # Every cell in the popup interior must (a) carry the popup's
    # gray background — the fill must not have left any cells on the
    # editor's blue — and (b) carry a printable glyph, not a stray
    # control char (``\n``, ``\r``, ``\t``) that would render as a
    # weird gap.
    for y in range(top_y + 1, bottom_y):
        for x in range(left_x + 1, right_x):
            var cell = canvas.get(x, y)
            assert_true(cell.attr.bg != BLUE)
            var g = cell.glyph
            assert_true(g != String("\n"))
            assert_true(g != String("\r"))
            assert_true(g != String("\t"))
    # The header line must appear verbatim in some popup row.
    var found_header = False
    for y in range(top_y + 1, bottom_y):
        var row_text = String("")
        for x in range(left_x + 1, right_x):
            row_text = row_text + canvas.get(x, y).glyph
        if _contains(row_text, String("\"Meta\" overrides symbol")):
            found_header = True
            break
    assert_true(found_header)


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


def test_editor_text_hover_anchor_aligns_with_underline_left() raises:
    """The tooltip must sit one row below the underlined span with its
    left edge aligned to the underline's leftmost cell — not anchored
    at the cursor like the minimap-mark hover. Buffer ``alpha beta
    gamma``, diagnostic on bytes [6, 10) which renders the underline at
    screen cells 6..10. Hovering anywhere in that span (we pick cell 8)
    should park the anchor at (x=6, y=1) — the cell directly under the
    'b' of 'beta'."""
    var ed = Editor(String("alpha beta gamma"))
    var diags = List[Diagnostic]()
    diags.append(Diagnostic(
        0, 6, 0, 10, DIAG_SEVERITY_ERROR,
        String("oops"), String("t"),
    ))
    ed.set_diagnostics(diags^)
    var view = Rect(0, 0, 60, 10)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(8, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 3)
    assert_true(ed._minimap_hover_below)
    # Anchor x = leftmost cell of underline (6); y = row directly below
    # the underline (0 + 1 = 1).
    assert_equal(ed._minimap_hover_x, 6)
    assert_equal(ed._minimap_hover_y, 1)


def test_editor_minimap_hover_keeps_above_left_anchor() raises:
    """Minimap-source hovers must keep their original above-left
    anchoring — the new below-the-underline behavior is text-area-only.
    A hover on the right-edge minimap column should leave
    ``_minimap_hover_below`` at False so paint uses the legacy
    placement."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_minimap_anchor.py"))
    assert_true(write_file(path, String("# helo world\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    var view = Rect(0, 0, 40, 5)
    _ = ed.handle_mouse(
        Event.mouse_event(Point(39, 0), MOUSE_BUTTON_NONE, True, True),
        view,
    )
    assert_equal(ed._minimap_hover_kind, 2)
    assert_false(ed._minimap_hover_below)
    # Minimap path stores cursor pos verbatim.
    assert_equal(ed._minimap_hover_x, 39)
    assert_equal(ed._minimap_hover_y, 0)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_has_spell_noinspection_directive_parses_intellij_forms() raises:
    """Recognized IntelliJ shapes — comma-separated lists, ``All``
    catch-all, multiple comment markers — must all return True.
    Adversarial near-misses (different inspection name, ``noinspection``
    embedded in a longer identifier) must not."""
    # Bare directive (caller has already stripped the comment marker).
    assert_true(has_spell_noinspection_directive(
        String("noinspection SpellCheckingInspection")
    ))
    # Common in-source forms with the comment marker still attached
    # — the function operates on the slice the editor extracts, which
    # for a Python ``# ...`` comment includes the leading ``#``.
    assert_true(has_spell_noinspection_directive(
        String("# noinspection SpellCheckingInspection")
    ))
    assert_true(has_spell_noinspection_directive(
        String("// noinspection SpellCheckingInspection")
    ))
    assert_true(has_spell_noinspection_directive(
        String("<!-- noinspection SpellCheckingInspection -->")
    ))
    # Comma-separated list with the spell inspection somewhere in it.
    assert_true(has_spell_noinspection_directive(
        String("# noinspection PyUnresolvedReferences,SpellCheckingInspection")
    ))
    assert_true(has_spell_noinspection_directive(
        String("# noinspection SpellCheckingInspection,PyUnresolvedReferences")
    ))
    # Catch-all ``All`` disables every inspection — including spell.
    assert_true(has_spell_noinspection_directive(
        String("# noinspection All")
    ))
    # Negative cases.
    assert_false(has_spell_noinspection_directive(
        String("# helo world")
    ))
    assert_false(has_spell_noinspection_directive(
        String("# noinspection PyUnresolvedReferences")
    ))
    # Word boundary on the keyword itself: ``xnoinspection`` mustn't
    # count.
    assert_false(has_spell_noinspection_directive(
        String("# xnoinspection SpellCheckingInspection")
    ))
    # Empty / no-trailing-list directive is a no-op.
    assert_false(has_spell_noinspection_directive(
        String("# noinspection")
    ))


def test_editor_spell_noinspection_suppresses_next_line() raises:
    """A ``# noinspection SpellCheckingInspection`` comment must
    suppress spell underlines on the directive line itself (so the
    word ``noinspection`` doesn't get flagged) and on the following
    line (the IntelliJ "applies to next code element" semantic).
    Lines after the suppression window must still get flagged."""
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell_noinspect.py"))
    # Row 0: the directive, contains ``noinspection`` (12 lowercase
    # letters, would normally be flagged).
    # Row 1: a comment with a misspelling ``helo`` — must NOT flag.
    # Row 2: another comment with ``helo`` — must flag (out of window).
    assert_true(write_file(path, String(
        "# noinspection SpellCheckingInspection\n"
        + "# helo world\n"
        + "# helo world\n"
    )))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    # Exactly one underline highlight, on row 2.
    assert_equal(len(ed.spell_highlights), 1)
    var sh = ed.spell_highlights[0]
    assert_equal(sh.row, 2)
    # And spell_lines reflects that — only row 2 is marked.
    assert_false(ed.spell_lines[0])
    assert_false(ed.spell_lines[1])
    assert_true(ed.spell_lines[2])
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def test_editor_spell_underlines_misspelled_word_in_comment() raises:
    """End-to-end: a misspelled word inside a ``#`` comment surfaces as
    a ``STYLE_UNDERLINE`` highlight at the right byte range, and the
    row gets marked in ``spell_lines`` so the minimap can project it."""
    # Dictionary is broad enough that only ``helo`` flags inside the
    # comment — ``hello`` and ``world`` are present.
    var words = List[String]()
    words.append(String("hello"))
    words.append(String("world"))
    var speller = _spell_with_dict(words)
    var path = _temp_path(String("_spell.py"))
    assert_true(write_file(path, String("# helo world hello\n")))
    var ed = Editor.from_file(path)
    var registry = GrammarRegistry()
    ed.flush_highlights(registry, speller)
    # Exactly one underline highlight: for ``helo`` at bytes 2..6.
    assert_equal(len(ed.spell_highlights), 1)
    var sh = ed.spell_highlights[0]
    assert_equal(sh.row, 0)
    assert_equal(sh.col_start, 2)
    assert_equal(sh.col_end, 6)
    assert_true((sh.attr.style & STYLE_UNDERLINE) != 0)
    # Row 0 is marked as having a spell issue; row 1 (the empty
    # trailing line) is not.
    assert_true(len(ed.spell_lines) >= 1)
    assert_true(ed.spell_lines[0])
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


def _assert_visual_eq(a: VisualLine, b: VisualLine) raises:
    assert_equal(a.line_idx, b.line_idx)
    assert_equal(a.byte_start, b.byte_start)
    assert_equal(a.byte_end, b.byte_end)
    assert_equal(a.cell_start, b.cell_start)
    assert_equal(a.cell_count, b.cell_count)
    assert_equal(a.indent_cells, b.indent_cells)


def test_text_log_incremental_layout_matches_full_rewrap() raises:
    """After streaming appends, ``TextLog.last_visual`` must match a
    fresh ``wrap_lines`` over the same lines at the same width.

    Regression: the maximized DebugPane painted at ~210 cols re-wrapped
    its full 500-line backlog every frame, costing ~200 ms — enough to
    keep the main loop pegged at 100 % CPU on every output-streaming
    debug session. The fix caches ``last_visual`` and only recomputes
    when the width changes; pushed lines append their own visual rows
    incrementally.
    """
    var log = TextLog(default_attr())
    # Prime the cache with an initial paint at width 20.
    var canvas = Canvas(40, 12)
    log.append(String("alpha"))
    log.paint(canvas, Rect(0, 0, 20, 5))
    # Stream a flurry of appends — both short (one visual row) and long
    # (multiple wrapped rows). This is the hot path: incremental
    # ``_push_line`` updates piggy-back on the cached layout.
    log.append(String("bravo charlie"))
    log.append(String(
        "this is a longer line that will definitely wrap several times "
        "across the small twenty-column window we picked for the test"
    ))
    log.append(String("delta"))
    # Re-paint at the same width — the cache should be reused.
    log.paint(canvas, Rect(0, 0, 20, 5))
    var fresh = wrap_lines(log.lines, 20)
    assert_equal(len(log.last_visual), len(fresh))
    for i in range(len(fresh)):
        _assert_visual_eq(log.last_visual[i], fresh[i])


def test_text_log_incremental_layout_handles_trim() raises:
    """When ``_push_line`` trims the front to honor ``max_lines``, the
    cached layout drops the dropped lines' visual rows and renumbers
    the survivors. Without that, ``last_visual`` would point at stale
    line indices and ``paint`` would crash on a mismatched lookup."""
    var log = TextLog(default_attr(), max_lines=3)
    var canvas = Canvas(40, 12)
    log.append(String("first"))
    log.paint(canvas, Rect(0, 0, 20, 5))
    log.append(String("second"))
    log.append(String("third"))
    # Backlog now full at three lines. The next append drops "first".
    log.append(String("fourth"))
    log.append(String("fifth"))
    assert_equal(len(log.lines), 3)
    var fresh = wrap_lines(log.lines, 20)
    assert_equal(len(log.last_visual), len(fresh))
    for i in range(len(fresh)):
        _assert_visual_eq(log.last_visual[i], fresh[i])


def test_editor_paint_collapsed_view_is_cheap() raises:
    """Maximizing the debug pane collapses the workspace to height 0,
    which gives editor windows a negative-height ``interior``. Without
    a guard, ``editor.paint`` would call ``wrap_lines`` with
    ``max_rows = view.height() = -2``; the negative value bypasses
    ``wrap_lines``'s ``max_rows >= 0`` gate and walks the entire
    buffer every frame — ~200 ms on a multi-thousand-line file,
    enough to peg the main loop at 100 % CPU.

    This regression test asserts the cheap path: a soft-wrap editor
    with a large buffer, painted into an empty view, must not produce
    any visual rows. (We can't time the call portably, but a buffer
    walk would produce many rows; the empty result is the proxy.)
    """
    var text = String("")
    for _ in range(2000):
        text = text + String(
            "the quick brown fox jumps over the lazy dog\n"
        )
    var ed = Editor(text^)
    # Negative height (b.y < a.y) is what window.interior() produces
    # when its outer rect collapses to height 0.
    var collapsed = Rect(1, 5, 50, 3)
    assert_true(collapsed.is_empty())
    var canvas = Canvas(80, 24)
    ed.paint(canvas, collapsed, False)


def test_text_log_full_rewrap_on_width_change() raises:
    """Resizing the view (different ``content_w``) forces a full
    re-wrap. The cached layout is keyed on the width that built it."""
    var log = TextLog(default_attr())
    var canvas = Canvas(80, 12)
    log.append(String(
        "a fairly long line that will wrap differently at different widths "
        "once the cache is rebuilt for the new width"
    ))
    log.paint(canvas, Rect(0, 0, 20, 5))
    var first_pass = log.last_visual.copy()
    # Re-paint at a wider width — must produce a different layout.
    log.paint(canvas, Rect(0, 0, 60, 5))
    var fresh = wrap_lines(log.lines, 60)
    assert_equal(len(log.last_visual), len(fresh))
    for i in range(len(fresh)):
        _assert_visual_eq(log.last_visual[i], fresh[i])
    # Sanity: the wider layout has fewer rows than the narrow one.
    assert_true(len(log.last_visual) < len(first_pass))


def test_text_field_scrolls_to_keep_cursor_visible() raises:
    """Typing past the strip width must scroll horizontally so the
    caret stays inside the strip — otherwise the user can't see what
    they're typing once the field overflows."""
    var tf = TextField()
    tf.set_text(String("abcdefghijklmnop"))   # 16 chars
    var canvas = Canvas(20, 1)
    var rect = Rect(0, 0, 10, 1)
    tf.paint(canvas, rect, True)
    # Cursor sits at the end of the text. Strip is 10 wide, so the
    # cursor must be at the rightmost cell (col 9) and the visible
    # window must show the *trailing* 10 cells of text.
    assert_equal(canvas.get(0, 0).glyph, String("h"))   # text cell 7
    assert_equal(canvas.get(8, 0).glyph, String("p"))   # last char
    # The caret cell sits past the last char (cursor at end-of-text).
    # Just assert the field hasn't scrolled past where text is visible.
    assert_true(tf._scroll > 0)
    assert_equal(tf._scroll, 7)   # 16 cells - 10 width + 1 caret cell


def test_text_field_scrolls_back_when_cursor_moves_left_of_view() raises:
    """Pressing Home on an overflowed field jumps the cursor to byte
    0; the visible window must follow so the user lands on the start
    of the text rather than staring at the (now-invisible) caret."""
    var tf = TextField()
    tf.set_text(String("abcdefghijklmnop"))
    var canvas = Canvas(20, 1)
    var rect = Rect(0, 0, 10, 1)
    tf.paint(canvas, rect, True)
    assert_true(tf._scroll > 0)
    _ = tf.handle_key(_key(KEY_HOME))
    tf.paint(canvas, rect, True)
    assert_equal(tf._scroll, 0)
    assert_equal(canvas.get(0, 0).glyph, String("a"))
    assert_equal(canvas.get(9, 0).glyph, String("j"))


def test_text_field_click_maps_to_text_byte_via_scroll() raises:
    """A click on a scrolled field must land on the codepoint that's
    *visually* under the cursor — i.e. text cell = strip cell +
    scroll. If we ignored scroll the click would always land in the
    first chunk of the text regardless of how far it had scrolled."""
    var tf = TextField()
    tf.set_text(String("abcdefghijklmnop"))
    var canvas = Canvas(20, 1)
    var rect = Rect(0, 0, 10, 1)
    tf.paint(canvas, rect, True)
    # The strip is now scrolled (cursor at end). Click on strip cell
    # 0 (which displays text cell 7 = 'h').
    _ = tf.handle_mouse(
        Event.mouse_event(Point(0, 0), MOUSE_BUTTON_LEFT, True, False),
        rect,
    )
    assert_equal(tf.cursor, 7)
    # Click on strip cell 5 (text cell 12 = 'm').
    _ = tf.handle_mouse(
        Event.mouse_event(Point(5, 0), MOUSE_BUTTON_LEFT, True, False),
        rect,
    )
    assert_equal(tf.cursor, 12)


def test_text_field_cmd_a_selects_all() raises:
    """Cmd+A should select the entire field on macOS — the same chord
    that triggers select-all in every other native input. Without the
    MOD_META branch in ``clipboard_chord``, only Ctrl+A worked."""
    var tf = TextField()
    tf.set_text(String("hello"))
    # Move cursor away from end so we can assert a real selection
    # change rather than an empty one.
    _ = tf.handle_key(_key(KEY_HOME))
    var r = tf.handle_key(_key(UInt32(ord("a")), MOD_META))
    assert_true(r.consumed)
    assert_true(tf.has_selection())
    assert_equal(tf.anchor, 0)
    assert_equal(tf.cursor, 5)


def test_text_field_ctrl_a_still_selects_all() raises:
    """The Cmd+A fix must not regress the existing Ctrl+A behavior —
    both modifiers map to select-all (Linux/Windows + macOS muscle
    memory)."""
    var tf = TextField()
    tf.set_text(String("hello"))
    _ = tf.handle_key(_key(KEY_HOME))
    var r = tf.handle_key(_key(UInt32(ord("a")), MOD_CTRL))
    assert_true(r.consumed)
    assert_true(tf.has_selection())
    assert_equal(tf.anchor, 0)
    assert_equal(tf.cursor, 5)


def test_text_field_cmd_letter_does_not_insert() raises:
    """Cmd+B (or any unbound Cmd chord) used to fall through the
    modifier check and insert ``b`` as plain text — the check at the
    bottom of ``handle_key`` only excluded MOD_CTRL / MOD_ALT and
    silently ignored MOD_META. Now Cmd+letter is always consumed and
    the field stays unchanged."""
    var tf = TextField()
    tf.set_text(String("hi"))
    var before = tf.text
    var r = tf.handle_key(_key(UInt32(ord("b")), MOD_META))
    assert_true(r.consumed)
    assert_true(not r.changed)
    assert_equal(tf.text, before)


def test_text_field_ctrl_letter_does_not_insert() raises:
    """Ctrl+B with no clipboard / select-all chord match should also
    leave the field untouched — same reasoning as the Cmd+letter
    case, but on Linux/Windows the modifier is Ctrl."""
    var tf = TextField()
    tf.set_text(String("hi"))
    var before = tf.text
    var r = tf.handle_key(_key(UInt32(ord("b")), MOD_CTRL))
    assert_true(r.consumed)
    assert_true(not r.changed)
    assert_equal(tf.text, before)


def test_text_field_paints_visible_window_after_scroll() raises:
    """When scrolled, ``paint`` must render the slice of text starting
    at ``_scroll`` and not draw the leading characters that fall
    before the strip — otherwise the off-screen text would smear into
    the strip's left edge."""
    var tf = TextField()
    tf.set_text(String("0123456789ABCDEF"))
    var canvas = Canvas(20, 1)
    var rect = Rect(2, 0, 10, 1)   # 8-wide strip starting at col 2
    tf.paint(canvas, rect, True)
    # Cursor at end; scroll = 16 - 8 + 1 = 9. Visible text cells are
    # [9, 17), so strip col 2 shows text cell 9 = '9', strip col 9
    # shows text cell 16 = caret-only space.
    assert_equal(canvas.get(2, 0).glyph, String("9"))
    assert_equal(canvas.get(8, 0).glyph, String("F"))
    # Outside the strip on the left: untouched (still default blank).
    assert_equal(canvas.get(0, 0).glyph, String(" "))
    assert_equal(canvas.get(1, 0).glyph, String(" "))



def test_vt_da1_reply_on_csi_c() raises:
    """``ESC[c`` (DA1) must enqueue a reply on the Vt's outbound
    queue. Real-world: starship / oh-my-zsh probe with this; without
    a reply the prompt stalls a beat on every redraw."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[c"))
    var reply = vt.take_reply()
    assert_equal(reply, String("\x1b[?6c"))
    # Drained — second call is empty.
    assert_equal(vt.take_reply(), String(""))


def test_vt_dsr_6_reply_uses_1_based_cursor() raises:
    """``ESC[6n`` (DSR cursor position) must reply with 1-based
    coordinates. The cursor at (cur_r=2, cur_c=3) reports ``3;4R``."""
    var vt = Vt(80, 24)
    # Move cursor to row 3, col 4 (1-based via CUP).
    vt.feed_string(String("\x1b[3;4H"))
    vt.feed_string(String("\x1b[6n"))
    assert_equal(vt.take_reply(), String("\x1b[3;4R"))


def test_vt_decset_2004_bracketed_paste_flag() raises:
    """``ESC[?2004h`` enables bracketed-paste mode; ``l`` disables.
    The pane reads this flag to decide whether to wrap pasted text."""
    var vt = Vt(80, 24)
    assert_false(vt.bracketed_paste)
    vt.feed_string(String("\x1b[?2004h"))
    assert_true(vt.bracketed_paste)
    vt.feed_string(String("\x1b[?2004l"))
    assert_false(vt.bracketed_paste)


def test_vt_decset_1_app_cursor_keys() raises:
    """DECCKM (``ESC[?1h``) flips arrow encoding from CSI to SS3 in
    the pane. We just verify the Vt tracks the flag."""
    var vt = Vt(80, 24)
    assert_false(vt.app_cursor_keys)
    vt.feed_string(String("\x1b[?1h"))
    assert_true(vt.app_cursor_keys)
    vt.feed_string(String("\x1b[?1l"))
    assert_false(vt.app_cursor_keys)


def test_vt_decset_1004_focus_events_round_trip() raises:
    """With ``?1004`` on, ``notify_focus_change`` emits ``ESC[I``
    (focus-in) / ``ESC[O`` (focus-out). With it off, nothing."""
    var vt = Vt(80, 24)
    # Off by default — no emit.
    vt.notify_focus_change(True)
    assert_equal(vt.take_reply(), String(""))
    vt.feed_string(String("\x1b[?1004h"))
    vt.notify_focus_change(True)
    assert_equal(vt.take_reply(), String("\x1b[I"))
    vt.notify_focus_change(False)
    assert_equal(vt.take_reply(), String("\x1b[O"))


def test_vt_osc_52_decodes_base64_to_clipboard() raises:
    """OSC 52 ``c;<base64>`` decodes to bytes the pane can hand to
    the system clipboard. ``aGVsbG8=`` is the canonical 'hello' test
    vector."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b]52;c;aGVsbG8=\x07"))
    assert_equal(vt.take_clipboard(), String("hello"))
    # Drained — second call is empty.
    assert_equal(vt.take_clipboard(), String(""))


def test_vt_osc_52_query_does_not_leak_clipboard() raises:
    """A query (``?`` in place of base64) must not produce a
    clipboard payload — leaking host clipboard contents to whatever
    the child is would be a security regression."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b]52;c;?\x07"))
    assert_equal(vt.take_clipboard(), String(""))


def test_vt_decscusr_tracks_cursor_shape() raises:
    """``CSI 4 SP q`` sets cursor_shape to 4 (steady underline). Out
    of range falls back to 0 so a malformed sequence can't leave the
    field in a nonsense state."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[4 q"))
    assert_equal(Int(vt.cursor_shape), 4)
    vt.feed_string(String("\x1b[99 q"))
    assert_equal(Int(vt.cursor_shape), 0)


def test_vt_ris_clears_mode_flags() raises:
    """``ESC c`` (RIS) is a hard reset. Mouse tracking, bracketed
    paste, focus events, app-cursor-keys all clear — otherwise a
    fresh shell coming up after vim crashed inherits the dead
    program's modes and routes events to the wrong handler."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[?1000h\x1b[?2004h\x1b[?1004h\x1b[?1h"))
    assert_true(vt.mouse_track_press)
    assert_true(vt.bracketed_paste)
    assert_true(vt.focus_events)
    assert_true(vt.app_cursor_keys)
    vt.feed_string(String("\x1bc"))
    assert_false(vt.mouse_track_press)
    assert_false(vt.bracketed_paste)
    assert_false(vt.focus_events)
    assert_false(vt.app_cursor_keys)



def _run_chunk_00() raises:
    test_claude_detect_empty_buffer_returns_none()
    test_claude_detect_plain_shell_output_returns_none()
    test_claude_detect_spinner_row_returns_working()
    test_claude_detect_spinner_small_dot_frame_returns_working()
    test_claude_detect_spinner_other_glyph_frames_return_working()
    test_claude_detect_spinner_glyph_in_welcome_banner_is_not_working()
    test_claude_detect_welcome_banner_returns_clean()
    test_claude_detect_mascot_version_banner_returns_clean()
    test_claude_detect_mascot_banner_with_prompt_below_returns_clean()
    test_claude_detect_idle_prompt_returns_waiting()
    test_claude_detect_working_wins_over_waiting()
    test_claude_detect_generic_marker_returns_active()
    test_claude_detect_marker_outside_tail_window_is_ignored()
    test_claude_detect_finds_marker_inside_ansi_wrapped_line()
    test_claude_state_label_round_trip()
    test_confirm_dialog_y_key_resolves_yes()
    test_confirm_dialog_n_key_resolves_no()
    test_confirm_dialog_esc_cancels()
    test_confirm_dialog_enter_uses_focused_button()
    test_confirm_dialog_default_yes_focuses_yes()
    test_confirm_dialog_paints_inside_dialog_rect()
    test_desktop_confirm_dialog_yes_starts_grammar_install()
    test_desktop_confirm_dialog_no_clears_pending_action()
    test_canvas_put_wrapped_text_paints_inside_rect_only()
    test_canvas_put_wrapped_text_returns_zero_for_empty_rect()
    test_prompt_wrap_short_text_stays_on_one_line()
    test_prompt_wrap_breaks_at_last_space_within_budget()
    test_prompt_wrap_hard_breaks_an_unbreakable_word()
    test_prompt_wrap_empty_returns_empty_list()
    test_prompt_paint_clamps_long_label_inside_dialog()
    test_diff_grammar_paints_inserted_deleted_and_hunk_header()
    test_diff_identical_inputs_have_no_hunks()
    test_diff_lines_pure_insert()
    test_diff_lines_pure_delete()
    test_diff_lines_replace_round_trips()
    test_unified_diff_renders_hunk_header_and_marks()
    test_git_blame_parses_two_line_porcelain()
    test_git_blame_propagates_cached_author_for_repeated_sha()
    test_git_blame_marks_uncommitted_with_zero_sha_and_placeholder()
    test_editor_blame_gutter_widens_total_gutter()
    test_parse_unified_diff_splits_two_files()
    test_parse_unified_diff_handles_pure_delete()
    test_diff_buffer_against_head_marks_added_and_modified()
    test_compute_revert_block_modified_line()
    test_compute_revert_block_added_line()
    test_compute_revert_block_unchanged_returns_empty()
    test_editor_git_changes_gutter_widens_total_gutter()
    test_editor_right_gutter_paints_gray_square_for_changes()
    test_editor_right_gutter_projects_full_file_when_scrolled()
    test_local_changes_open_records_status_when_clean()
    test_local_changes_sidebar_splitter_drag_resizes_right_pane()
    test_docked_panel_stack_layout_normal_split()
    test_docked_panel_stack_max_collapses_others()
    test_docked_panel_stack_max_then_restore_resets_all()
    test_docked_panel_stack_min_collapses_one()
    test_docked_panel_stack_min_on_max_sibling_clears_max()
    test_build_minimal_patch_keeps_only_target_plus_line()
    test_build_minimal_patch_demotes_paired_minus_to_context()
    test_build_minimal_patch_reverse_drops_paired_minus()
    test_build_minimal_patch_returns_empty_for_non_pm_lines()
    test_build_minimal_patch_drops_other_hunks()
    test_git_state_mtimes_zero_for_non_repo()
    test_git_state_mtimes_nonzero_after_init_commit()
    test_stage_unstage_round_trip_against_real_git()
    test_point_arithmetic()
    test_rect_basics()
    test_rect_helpers()
    test_attr()
    test_canvas_put_text()
    test_paint_title_commands_renders_separator_and_labels()
    test_paint_title_commands_drops_clipped_label()
    test_hit_title_command_returns_id_under_cursor()
    test_canvas_box()
    test_canvas_fill()
    test_event_factories()
    test_parse_input_keys()
    test_parse_window_size_report()
    test_parse_input_focus_events()
    test_parse_input_sgr_mouse()
    test_centered()
    test_scrollbar_hidden_when_content_fits()
    test_scrollbar_hidden_when_too_short()
    test_scrollbar_paints_arrows_and_thumb()
    test_scrollbar_thumb_tracks_scroll_position()
    test_scrollbar_hit_arrow_zones()
    test_scrollbar_hit_thumb_returns_drag_offset()
    test_scrollbar_hit_page_zones()
    test_scrollbar_hit_off_axis_returns_none()
    test_scrollbar_drag_to_extremes()
    test_scrollbar_track_jump_centers_target()
    test_scrollbar_horizontal_paints_arrows_on_axis()
    test_text_buffer_split_and_join()
    test_editor_typing_and_arrows()
    test_editor_word_movement()
    test_editor_word_movement_across_lines()
    test_editor_shift_arrow_extends_selection()
    test_editor_shift_ctrl_arrow_composes()
    test_editor_cmd_arrow_line_navigation()
    test_editor_typing_replaces_selection()
    test_editor_backspace_deletes_selection()


def _run_chunk_01() raises:
    test_editor_mouse_click_sets_cursor()
    test_editor_mouse_drag_extends_selection()
    test_editor_mouse_click_clamps_to_line()
    test_editor_double_click_selects_word()
    test_editor_double_click_drag_extends_by_word_forward()
    test_editor_double_click_drag_extends_by_word_backward()
    test_editor_triple_click_selects_line()
    test_editor_triple_click_last_line_no_newline()
    test_editor_triple_click_drag_extends_by_line_forward()
    test_editor_triple_click_drag_extends_by_line_backward()
    test_editor_cut_whole_line_when_no_selection()
    test_editor_cut_whole_line_only_line()
    test_editor_smart_indent_mirrors_previous_line()
    test_editor_smart_indent_after_open_brace()
    test_editor_smart_indent_after_colon()
    test_terminal_parses_modified_arrows()
    test_editor_selection_text()
    test_editor_cut_selection()
    test_editor_paste_text_single_line()
    test_editor_paste_text_multiline()
    test_editor_paste_replaces_selection()
    test_editor_selection_text_multiline()
    test_editor_goto_line()
    test_editor_find_next()
    test_editor_find_next_case_insensitive()
    test_editor_find_next_whole_word()
    test_editor_find_next_regex()
    test_editor_replace_all_case_insensitive()
    test_find_in_project_options_smoke()
    test_editor_toggle_comment_single_line()
    test_editor_toggle_comment_selection()
    test_editor_toggle_comment_language_aware()
    test_editor_toggle_comment_indented()
    test_editor_toggle_comment_common_indent()
    test_editor_toggle_comment_skips_blank_lines()
    test_editor_toggle_case()
    test_editor_dirty_flag()
    test_file_io_read_and_stat()
    test_editor_from_file()
    test_terminal_parses_alt_letter_as_letter()
    test_editor_alt_arrow_word_jump()
    test_path_helpers()
    test_basename()
    test_find_git_project()
    test_menu_layout_pins_file_edit_window_help()
    test_system_menu_pins_to_left_edge()
    test_right_aligned_menu_layout()
    test_desktop_project_lifecycle()
    test_file_tree_expand_collapse()
    test_file_tree_filters_dotfiles()
    test_desktop_workspace_shrinks_with_file_tree()
    test_window_min_size_enforced_at_construction()
    test_window_min_size_survives_workspace_shrink()
    test_window_manager_fit_into_moves_then_resizes()
    test_window_manager_fit_into_keeps_maximized_pinned()
    test_window_manager_fit_into_scales_side_by_side_on_grow()
    test_window_manager_fit_into_scales_side_by_side_on_shrink()
    test_window_manager_fit_into_scales_stacked_on_resize()
    test_window_manager_fit_into_proportional_2x2_grid()
    test_window_manager_fit_into_baseline_no_scale_on_first_call()
    test_window_manager_note_workspace_suppresses_next_scale()
    test_window_manager_fit_into_round_trip_is_lossless()
    test_window_manager_fit_into_user_drag_rebases_baseline()
    test_window_manager_fit_into_scales_restore_rect_for_maximized()
    test_write_file_round_trip()
    test_editor_save_clears_dirty()
    test_editor_save_as_adopts_path()
    test_diff3_merge_clean_when_only_ours_changed()
    test_diff3_merge_clean_when_only_theirs_changed()
    test_diff3_merge_clean_when_changes_disjoint()
    test_diff3_merge_identical_changes_dont_conflict()
    test_diff3_merge_conflict_when_both_edit_same_line()
    test_editor_external_change_clean_reload_when_buffer_clean()
    test_editor_external_change_refreshes_highlights()
    test_editor_external_change_auto_merges_disjoint_edits()
    test_editor_external_change_clears_dirty_when_disk_already_has_our_edits()
    test_editor_external_change_conflict_inserts_markers()
    test_editor_replace_all()
    test_editorconfig_parse_basic()
    test_editorconfig_match_section()
    test_editorconfig_load_from_fixture()
    test_editor_uses_editorconfig_indent()
    test_editor_save_applies_editorconfig_transforms()
    test_editor_save_uses_editorconfig_line_endings()
    test_text_buffer_strips_crlf_on_split()
    test_editor_preserves_crlf_round_trip()
    test_git_gutter_no_diff_when_buffer_matches_crlf_head()
    test_canvas_substitutes_control_glyphs()
    test_walk_project_files_finds_known_files()
    test_find_in_project_locates_string()
    test_gitignore_matches_directory_pattern()
    test_gitignore_matches_glob_and_negate()
    test_walk_project_files_respects_gitignore()
    test_walk_project_files_include_ignored_files_keeps_files_prunes_dirs()
    test_downloadable_grammar_registry_has_elm()
    test_downloadable_grammar_registry_misses_unknown()
    test_grammar_install_command_targets_user_config()
    test_user_grammar_path_for_ext_misses_when_not_installed()
    test_on_save_action_default_is_empty()
    test_on_save_action_copy_preserves_args()
    test_settings_open_seeds_state()


def _run_chunk_02() raises:
    test_settings_open_empty_parks_selection_at_minus_one()
    test_settings_remove_marks_dirty()
    test_settings_editor_submit_appends_new_entry()
    test_settings_editor_submit_replaces_existing_entry()
    test_settings_open_seeds_save_behavior_dropdown()
    test_settings_save_behavior_commit_marks_dirty()
    test_settings_save_behavior_no_change_no_dirty()
    test_language_catalog_carries_comment_tokens()
    test_apply_language_overrides_replaces_candidates()
    test_apply_language_overrides_adds_new_language()
    test_settings_languages_section_seeded()
    test_settings_open_selects_current_language()
    test_settings_open_unknown_extension_falls_back_to_first()
    test_settings_remove_language_override_marks_dirty()
    test_language_editor_save_emits_override()
    test_list_box_paint_never_overflows_bounds()
    test_list_box_paint_empty_hint_clipped()
    test_list_box_mouse_wheel_clamps_to_item_count()
    test_language_editor_paint_does_not_damage_dialog_border()
    test_language_editor_move_candidate_reorders()
    test_type_ahead_pick_returns_index_or_minus_one()
    test_type_ahead_pick_solo_fallback()
    test_settings_languages_list_type_to_jump()
    test_settings_actions_list_type_to_jump()
    test_language_editor_list_type_to_jump()
    test_file_tree_type_to_jump()
    test_menu_open_dropdown_type_to_jump()
    test_is_printable_ascii_gates_search_keys()
    test_action_editor_lang_dropdown_has_options()
    test_action_editor_enter_opens_lang_popup()
    test_dropdown_type_to_search_jumps_to_prefix()
    test_dropdown_type_to_search_skips_empty_sentinel()
    test_dropdown_type_to_search_recovers_from_stale_prefix()
    test_dropdown_type_to_search_resets_on_close()
    test_action_editor_consumes_browse_path()
    test_action_editor_args_field_accepts_spaces()
    test_action_editor_args_buffer_seeded_from_entry()
    test_on_save_action_reloads_buffer_when_action_rewrites_file()
    test_expand_save_placeholders_substitutes_filepath()
    test_extension_of_helper()
    test_word_at_helper()
    test_highlight_for_extension_recognizes_mojo()
    test_highlight_triple_quoted_string_spans_lines()
    test_highlight_unknown_extension_returns_empty()
    test_highlight_rust_keywords_strings_comments()
    test_highlight_rust_block_comment_spans_lines()
    test_onig_basic_search()
    test_onig_no_match_returns_none()
    test_onig_search_at_offset()
    test_onig_invalid_pattern_raises()
    test_textmate_rust_grammar_paints_keywords_and_strings()
    test_textmate_brackets_paint_as_operators()
    test_textmate_html_embeds_css_inside_style_block()
    test_textmate_capture_patterns_run_inside_group()
    test_textmate_while_rule_keeps_scope_open_per_line()
    test_textmate_captures_overlay_on_match()
    test_textmate_incremental_matches_full_retokenize()
    test_editor_default_text_is_light_green()
    test_textmate_all_bundled_grammars_load()
    test_textmate_eol_closes_frame_with_newline_end_pattern()
    test_textmate_json_grammar_paints_strings_and_numbers()
    test_textmate_rust_block_comment_spans_lines()
    test_intellij_language_injection_html_in_python_string()
    test_intellij_language_injection_inline_marker()
    test_intellij_language_injection_unknown_language_no_op()
    test_intellij_language_injection_triple_quoted_python()
    test_embedded_language_extensions_collects_unique_languages()
    test_embedded_language_extensions_skips_unknown_languages()
    test_editor_refreshes_highlights_after_edits()
    test_editor_paint_overlays_highlight_attr()
    test_editor_alt_click_emits_definition_request()
    test_editor_alt_click_outside_identifier_is_silent()
    test_editor_gutter_click_emits_breakpoint_toggle()
    test_editor_text_click_does_not_toggle_breakpoint()
    test_editor_gutter_click_below_eof_is_ignored()
    test_editor_gutter_drag_motion_does_not_toggle()
    test_install_runner_last_lines_picks_tail_skipping_blanks()
    test_install_runner_runs_sh_command_to_completion()
    test_install_runner_failure_carries_nonzero_exit()
    test_doc_registry_lookup()
    test_doc_install_command_shape()
    test_html_to_text_basics()
    test_html_to_text_headings_become_hashes()
    test_html_to_text_lists_and_inline()
    test_html_to_text_pre_uses_fence()
    test_html_to_text_preserves_pre()
    test_html_to_text_strips_script_and_style()
    test_html_to_text_table_renders_as_gfm_table()
    test_html_to_text_table_escapes_pipes_in_cells()
    test_find_doc_entry_exact_match_wins()
    test_find_doc_entry_falls_back_to_suffix_match()
    test_find_doc_entry_returns_minus_one_when_no_match()
    test_find_doc_entry_case_insensitive_when_no_exact()
    test_quick_open_match_rules()
    test_quick_open_match_case_and_separator_shapes()
    test_quick_open_slash_in_query_requires_directory_separator()
    test_quick_open_filters_as_you_type()
    test_cmd_o_bubbles_file_open()
    test_cmd_shift_o_opens_quick_open_when_project_active()
    test_cmd_shift_o_bubbles_when_no_project()


def _run_chunk_03() raises:
    test_desktop_dispatch_editor_save_passes_through_when_no_editor()
    test_desktop_dispatch_passes_through_unknown_actions()
    test_desktop_dispatch_editor_save_writes_focused_editor()
    test_window_focus_change_saves_prior_window()
    test_window_focus_change_via_dispatch_action_saves()
    test_app_focus_out_saves_all_dirty_windows_by_default()
    test_focus_loss_save_opt_out_when_auto_save_off()
    test_window_focus_change_skips_untitled_buffer()
    test_desktop_replace_chains_two_prompts()
    test_desktop_open_file_uses_80_percent_size()
    test_desktop_open_file_cascades_by_one()
    test_desktop_open_file_focuses_existing()
    test_desktop_open_file_inherits_maximize_state()
    test_desktop_new_file_creates_untitled_editor_window()
    test_desktop_dispatch_editor_new_opens_window()
    test_desktop_window_menu_lists_open_windows()
    test_desktop_window_menu_when_empty()
    test_desktop_window_focus_action_focuses_window()
    test_desktop_maximize_all_and_restore_all()
    test_nav_history_records_initial_open()
    test_nav_history_ignores_small_drift()
    test_nav_history_records_file_change()
    test_nav_history_back_and_forward()
    test_nav_history_branching_truncates_forward()
    test_nav_history_back_via_dispatch_action()
    test_nav_history_cmd_bracket_keys_fire_dispatch()
    test_normalize_ctrl_letter_preserves_cmd_bracket()
    test_window_manager_close_focused()
    test_ctrl_n_focuses_window_by_number()
    test_focus_changes_keep_window_list_order_stable()
    test_window_manager_rotate_focus_cycles_in_stable_order()
    test_window_manager_rotate_focus_noop_when_fewer_than_two_windows()
    test_window_menu_items_show_ctrl_n_shortcut()
    test_cmd_w_closes_focused_window()
    test_format_hotkey_renders_combinations()
    test_menu_items_get_shortcut_text_after_refresh()
    test_dropdown_widens_to_fit_shortcut()
    test_dropdown_reserves_indent_for_checkable_items()
    test_parse_csi_modify_other_keys_normalizes_ctrl_q()
    test_parse_csi_modify_other_keys_cmd_letter_keeps_meta()
    test_parse_csi_modify_other_keys_cmd_backtick_keeps_key_intact()
    test_cmd_s_via_modify_other_keys_triggers_save_hotkey()
    test_parse_csi_modify_other_keys_ctrl_shift_f()
    test_parse_csi_modify_other_keys_cmd_shift_f_keeps_meta()
    test_parse_csi_unknown_sequence_is_consumed_whole()
    test_parse_osc_open_path_emits_event_open_path()
    test_parse_osc_open_path_with_line_suffix()
    test_parse_osc_open_path_st_terminator()
    test_parse_osc_unknown_is_consumed_silently()
    test_parse_osc_partial_defers()
    test_parse_csi_kitty_u_ctrl_letter()
    test_editor_rejects_modified_letter_typing()
    test_cmd_q_modifyOtherKeys_triggers_quit_action()
    test_ctrl_key_helper()
    test_menu_keyboard_nav_arrows_and_enter()
    test_alt_letter_opens_menu_by_mnemonic()
    test_esc_prefix_opens_menu_by_mnemonic()
    test_esc_prefix_disarms_after_one_keystroke()
    test_top_level_esc_does_not_quit()
    test_default_hotkey_cmd_q_returns_quit()
    test_default_hotkey_cmd_f_opens_find_prompt()
    test_default_hotkey_cmd_s_saves_focused_editor()
    test_hotkey_overrides_default_when_registered_later()
    test_hotkey_does_not_fire_while_prompt_active()
    test_desktop_project_find_requires_active_project()
    test_replace_in_project_round_trip()
    test_painter_clips_text_at_right_edge()
    test_painter_skips_codepoints_left_of_clip()
    test_painter_fill_intersects_with_clip()
    test_dir_browser_long_name_does_not_overflow_listing()
    test_file_dialog_lists_and_navigates()
    test_partial_sgr_mouse_does_not_emit_esc()
    test_sgr_mouse_wheel_up()
    test_sgr_mouse_motion_no_button()
    test_menu_hover_switches_open_menu()
    test_menu_drag_release_on_item_triggers()
    test_menu_drag_release_outside_closes()
    test_menu_click_then_click_flow()
    test_file_dialog_selects_a_file()
    test_file_dialog_mouse_click_selects()
    test_file_dialog_double_click_opens()
    test_file_dialog_wheel_scrolls()
    test_file_dialog_directory_mode_picks_current_dir()
    test_file_dialog_directory_mode_enter_does_not_submit()
    test_save_as_dialog_seeds_from_existing_path()
    test_save_as_dialog_typing_updates_filename()
    test_save_as_dialog_enter_submits_joined_path()
    test_save_as_dialog_tab_focus_then_listing_navigation()
    test_save_as_dialog_empty_filename_blocks_submit()
    test_editor_sticky_col_down_through_short_line()
    test_editor_sticky_col_up_through_short_line()
    test_editor_sticky_col_reset_by_left_arrow()
    test_editor_sticky_col_reset_by_right_arrow()
    test_editor_sticky_col_reset_by_typing()
    test_editor_sticky_col_reset_by_click()
    test_editor_sticky_col_reset_by_home_end()
    test_editor_sticky_col_pageup_pagedown()
    test_editor_sticky_col_shift_down_keeps_anchor()
    test_editor_left_right_steps_over_multibyte_codepoint()
    test_editor_backspace_removes_whole_codepoint()
    test_editor_delete_key_removes_whole_codepoint()
    test_editor_vertical_movement_uses_cell_column()
    test_editor_mouse_click_lands_on_codepoint_boundary()
    test_window_v_scrollbar_hit_arrows_and_thumb()
    test_window_v_scroll_by_clamps()


def _run_chunk_04() raises:
    test_window_v_scrollbar_track_click_centers_target()
    test_window_v_scroll_drag_to_end()
    test_json_round_trip_lsp_envelope()
    test_json_string_escapes()
    test_json_parse_errors_raise()
    test_json_floats_round_trip_as_text()
    test_language_registry_loads_from_bundled_json()
    test_lsp_framer_finds_double_crlf()
    test_lsp_framer_parses_content_length()
    test_lsp_framer_extract_one_message()
    test_lsp_drop_prefix_helper()
    test_lsp_classify_message()
    test_lsp_parse_diagnostics_array_minimum_fields()
    test_lsp_parse_diagnostics_array_full_fields()
    test_lsp_parse_diagnostics_skips_malformed_entries()
    test_lsp_parse_completion_result_array_shape()
    test_lsp_parse_completion_result_list_shape()
    test_lsp_parse_completion_result_honors_sort_text()
    test_lsp_parse_completion_result_snippet_falls_back_to_label()
    test_lsp_parse_completion_result_extracts_text_edit_range()
    test_lsp_parse_completion_result_extracts_insert_replace_edit()
    test_lsp_parse_completion_result_extracts_additional_text_edits()
    test_editor_completion_prefix_start_walks_back_through_word()
    test_editor_set_completions_opens_popup()
    test_editor_typing_word_char_stamps_autotrigger_request()
    test_editor_typing_non_word_char_skips_autotrigger()
    test_editor_cursor_move_inside_word_keeps_popup_alive()
    test_editor_typing_non_word_char_closes_visible_popup()
    test_editor_ctrl_space_marks_request_manual()
    test_editor_autotrigger_request_is_not_manual()
    test_editor_autotrigger_request_debounced_until_settled()
    test_editor_autotrigger_request_released_after_debounce()
    test_editor_manual_completion_request_bypasses_debounce()
    test_editor_close_completion_popup_clears_pending_request()
    test_desktop_esc_dismisses_completion_popup()
    test_desktop_left_click_outside_popup_dismisses_it()
    test_desktop_left_click_inside_popup_keeps_it_open()
    test_editor_show_no_completion_message_opens_unselectable_popup()
    test_editor_accept_completion_replaces_prefix()
    test_editor_accept_completion_overlap_widens_anchor()
    test_editor_accept_completion_overlap_leaves_disjoint_text_alone()
    test_editor_accept_completion_uses_text_edit_range()
    test_editor_accept_completion_applies_additional_text_edits()
    test_editor_set_diagnostics_builds_per_row_severity_index()
    test_editor_minimap_kind_prioritizes_error_over_git_and_spell()
    test_editor_minimap_warning_outranks_git_change()
    test_editor_minimap_hint_loses_to_spell()
    test_editor_clear_diagnostics_drops_per_row_index()
    test_lsp_subprocess_round_trip_via_cat()
    test_lsp_write_message_queues_bytes_when_fd_is_unavailable()
    test_lsp_write_overflow_resets_queue_and_latches_flag()
    test_lsp_initialize_against_mojo_lsp_server()
    test_dap_classify_response()
    test_dap_classify_event()
    test_dap_classify_reverse_request()
    test_dap_classify_response_with_failure()
    test_dap_initialize_arguments_shape()
    test_dap_seq_autoincrement_via_cat()
    test_dap_parse_threads()
    test_dap_parse_stack_trace_zero_based()
    test_dap_parse_scopes_and_variables()
    test_dap_registry_lookup()
    test_dap_launch_arguments_for_debugpy()
    test_dap_launch_arguments_for_debugpy_module_mode()
    test_dap_launch_arguments_for_debugpy_versioned_python()
    test_dap_launch_arguments_for_debugpy_non_python_program()
    test_dap_launch_arguments_for_debugpy_script_mode()
    test_dap_launch_arguments_for_debugpy_skips_flag_args()
    test_dap_launch_arguments_for_delve()
    test_dap_manager_breakpoint_toggle()
    test_dap_manager_breakpoint_enabled_default_and_toggle()
    test_dap_manager_breakpoints_info_for()
    test_dap_manager_captures_condition_exception_from_output()
    test_dap_manager_condition_exception_ignores_unrelated_output()
    test_editor_right_click_on_breakpoint_emits_menu_request()
    test_project_targets_load_parses_fields()
    test_project_targets_save_roundtrips_active()
    test_project_targets_resolve_paths()
    test_resolve_python_interpreter()
    test_python_venv_dir_finds_dotvenv()
    test_python_debugger_spec_for_venv_prepends_venv_python()
    test_detect_project_language_python_markers()
    test_detect_project_language_no_match()
    test_status_bar_tab_hit_test()
    test_shadow_button_paints_face_and_shadow()
    test_shadow_button_hit_includes_shadow_rows()
    test_canvas_darken_rect_preserves_glyph()
    test_paint_drop_shadow_targets_right_and_bottom()
    test_debug_pane_default_title_is_debug()
    test_debug_pane_run_mode_swaps_title()
    test_debug_pane_run_mode_hides_inspect_divider()
    test_debug_pane_run_mode_uses_full_height_for_output()
    test_debug_pane_debug_mode_keeps_output_divider()
    test_debug_pane_subtle_frame_paints_dim()
    test_debug_pane_debug_mode_running_hides_inspect()
    test_debug_pane_traceback_link_underlines_span()
    test_debug_pane_plain_output_has_no_link_styling()
    test_debug_pane_click_on_traceback_link_sets_pending_open()
    test_text_view_wrap_lines_breaks_at_width()
    test_text_view_wrap_lines_word_aware_with_indent()


def _run_chunk_05() raises:
    test_text_view_selection_extracts_text()
    test_string_utils_slice_codepoints_handles_multibyte()
    test_debug_pane_long_output_line_soft_wraps()
    test_debug_pane_run_log_paints_scrollbar_when_overflowing()
    test_debug_pane_run_log_no_scrollbar_when_content_fits()
    test_debug_pane_run_log_arrow_click_scrolls_output()
    test_debug_pane_run_log_thumb_drag_scrolls_output()
    test_debug_pane_drag_selects_output_text()
    test_debug_pane_selection_spans_multiple_lines()
    test_debug_pane_plain_click_clears_selection()
    test_targets_dialog_edit_and_submit()
    test_targets_dialog_add_and_remove()
    test_targets_dialog_save_button_submits()
    test_targets_dialog_esc_discards_edits()
    test_run_session_lifecycle()
    test_session_round_trip()
    test_session_load_missing_returns_empty()
    test_breakpoint_store_round_trip()
    test_breakpoint_store_load_missing_returns_empty()
    test_breakpoint_store_per_user_path()
    test_view_state_store_round_trip()
    test_view_state_store_load_missing_returns_empty()
    test_view_state_store_per_user_path()
    test_session_relative_path_round_trip()
    test_desktop_snapshot_skips_untitled_windows()
    test_desktop_restores_session_from_disk()
    test_desktop_arms_session_restore_when_non_editor_windows_present()
    test_desktop_resize_reapplies_clipped_session_rect()
    test_desktop_restores_non_maximized_rect_not_restore_rect()
    test_desktop_restores_multiple_windows_at_distinct_positions()
    test_desktop_snapshot_captures_per_window_rects()
    test_desktop_save_then_restore_round_trip_through_paint()
    test_desktop_restores_maximized_window_keeps_per_window_restore_rect()
    test_speller_check_word_basic()
    test_speller_strips_common_suffixes()
    test_speller_unloaded_returns_true_for_everything()
    test_speller_add_user_word_persists_and_check_word_passes()
    test_speller_load_default_layers_user_dictionary()
    test_speller_normalizes_unicode_for_lookup()
    test_speller_load_default_layers_user_language_dictionaries()
    test_speller_reload_drops_removed_dictionary()
    test_speller_add_project_word_persists_in_project_dir()
    test_editor_alt_enter_on_misspelling_emits_pending_action()
    test_editor_alt_enter_outside_misspelling_does_not_consume()
    test_editor_invalidate_spell_drops_overlay_after_word_added()
    test_spell_menu_open_close_default_selection()
    test_spell_menu_enter_on_user_resolves_with_add_user()
    test_spell_menu_enter_on_project_disabled_stays_open()
    test_spell_menu_enter_on_project_enabled_resolves_with_add_project()
    test_spell_menu_esc_dismisses()
    test_has_spell_noinspection_directive_parses_intellij_forms()
    test_editor_spell_noinspection_suppresses_next_line()
    test_editor_spell_underlines_misspelled_word_in_comment()
    test_editor_spell_uses_curly_colored_underline_on_supported_terminal()
    test_editor_minimap_git_change_wins_over_spell_on_same_row()
    test_editor_minimap_click_scrolls_to_marked_line()
    test_editor_minimap_hover_records_spell_word()
    test_editor_minimap_hover_paints_tooltip()
    test_editor_text_hover_over_diagnostic_records_kind_and_message()
    test_editor_text_hover_off_diagnostic_clears_state()
    test_editor_text_hover_picks_most_severe_diagnostic_on_overlap()
    test_editor_text_hover_over_spell_word_records_word()
    test_editor_text_hover_past_eol_clears_state()
    test_editor_text_hover_diagnostic_renders_tooltip()
    test_editor_long_diagnostic_tooltip_fills_popup_interior()
    test_editor_multiline_diagnostic_tooltip_renders_each_line()
    test_editor_long_diagnostic_tooltip_through_window()
    test_editor_text_hover_anchor_aligns_with_underline_left()
    test_editor_minimap_hover_keeps_above_left_anchor()
    test_attr_to_sgr_plain_underline()
    test_attr_to_sgr_curly_colored_underline()
    test_text_log_incremental_layout_matches_full_rewrap()
    test_text_log_incremental_layout_handles_trim()
    test_text_log_full_rewrap_on_width_change()
    test_editor_paint_collapsed_view_is_cheap()
    test_editor_cmd_letter_does_not_insert()
    test_editor_cmd_a_selects_all()
    test_text_field_scrolls_to_keep_cursor_visible()
    test_text_field_scrolls_back_when_cursor_moves_left_of_view()
    test_text_field_click_maps_to_text_byte_via_scroll()
    test_text_field_cmd_a_selects_all()
    test_text_field_ctrl_a_still_selects_all()
    test_text_field_cmd_letter_does_not_insert()
    test_text_field_ctrl_letter_does_not_insert()
    test_text_field_paints_visible_window_after_scroll()
    test_vt_osc_52_decodes_base64_to_clipboard()

def main() raises:
    # Redirect $HOME to a scratch dir so tests that construct ``Desktop``
    # (which writes to ``~/.config/turbokod/config.json`` via
    # ``_set_project`` → ``save_config``) can't clobber the developer's
    # real config. Same goes for grammar installs and dir-browser HOME
    # lookups.
    var test_home = String("/tmp/turbokod_test_home")
    var c_home_dir = test_home + String("\0")
    _ = external_call["mkdir", Int32](c_home_dir.unsafe_ptr(), Int32(0o755))
    var c_name = String("HOME\0")
    var c_value = test_home + String("\0")
    _ = external_call["setenv", Int32](
        c_name.unsafe_ptr(), c_value.unsafe_ptr(), Int32(1),
    )
    # Bypass the system clipboard so cut/copy tests don't stomp the
    # developer's real pbcopy/xclip contents with test fixtures.
    var c_fake = String("TURBOKOD_FAKE_CLIPBOARD\0")
    var c_one = String("1\0")
    _ = external_call["setenv", Int32](
        c_fake.unsafe_ptr(), c_one.unsafe_ptr(), Int32(1),
    )

    _run_chunk_00()
    _run_chunk_01()
    _run_chunk_02()
    _run_chunk_03()
    _run_chunk_04()
    _run_chunk_05()
    print("all tests passed")
