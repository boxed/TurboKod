"""Core data types: geometry, colors, canvas, strings, stores.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.claude_detect import (
    CLAUDE_ACTIVE, CLAUDE_CLEAN, CLAUDE_NONE, CLAUDE_WAITING, CLAUDE_WORKING,
    claude_state_label, detect_claude_state
)
from turbokod.cell import Cell
from turbokod.colors import (
    Attr, BLACK, BLUE, DARK_GRAY, GREEN, LIGHT_GRAY, LIGHT_GREEN, LIGHT_RED,
    STYLE_UNDERLINE, STYLE_UNDERLINE_CURLY, WHITE, YELLOW, BORDER_FOCUS,
    CARET_BG, CARET_FG, EDITOR_BG, EDITOR_FG, SYN_IDENT, PANE_BG, attr_to_sgr,
    attr_to_sgr_rgb, attr_to_sgr_indexed, default_attr
)
from turbokod.theme import (
    Theme, built_in_themes, default_theme_name, theme_by_name, theme_names
)
from turbokod.editor import Editor
from turbokod.editorconfig import (
    load_editorconfig_for_path, match_section, parse_editorconfig
)
from turbokod.drafts_store import StoredDraft, load_drafts, save_drafts
from turbokod.desktop import (
    APP_QUIT_ACTION, Desktop, EDITOR_SAVE, PROJECT_FIND
)
from turbokod.file_io import (
    delete_path, join_path, list_directory, parent_path, read_file,
    stat_file, write_file
)
from turbokod.git_changes import (
    compute_deletion_revert_block, compute_revert_block, parse_line_history,
    parse_unified_diff_files
)
from turbokod.local_changes import build_minimal_patch
from turbokod.file_tree import FileTree, FileTreeEntry
from turbokod.menu import Menu, MenuBar, MenuItem
from turbokod.project import FileIndexer
from turbokod.project_targets import detect_project_language
from turbokod.string_utils import slice_codepoints, shell_escape_path
from turbokod.project_on_save import on_save_equal
from turbokod.quick_open import QuickOpen
from turbokod.doc_config import (
    built_in_docsets, docs_install_command, find_docset_by_language,
    find_docset_for_extension
)
from turbokod.json import (
    encode_json, json_int, json_null, json_object, json_str, parse_json
)
from turbokod.language_config import (
    LanguageSpec, apply_language_overrides, built_in_servers,
    find_language_by_id
)
from turbokod.lsp import capture_command
from turbokod.highlight import GrammarRegistry, word_at
from turbokod.posix import monotonic_ms, which
from turbokod.spell import Speller
from turbokod.grammar_install import (
    user_grammar_path, user_grammar_path_for_ext
)
from turbokod.project_grammars import (
    GrammarOverride, load_project_grammar_overrides, write_grammar_overrides
)
from turbokod.config import LanguageServerOverride, OnSaveAction
from turbokod.settings import Settings
from turbokod.events import (
    Event, EVENT_FOCUS_IN, EVENT_FOCUS_OUT, EVENT_KEY, EVENT_MOUSE,
    EVENT_NONE, EVENT_OPEN_PATH, EVENT_RESIZE, KEY_END, KEY_ENTER, KEY_ESC,
    MOD_ALT, MOD_CTRL, MOD_META, MOD_SHIFT, MOUSE_BUTTON_LEFT
)
from turbokod.geometry import Point, Rect
from turbokod.prompt import Prompt
from turbokod.terminal import parse_input
from turbokod.window import Window

from support import (
    _SCREEN, _contains, _empty_menu, _key, _temp_path, setup_test_env
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


def test_canvas_put_text() raises:
    var c = Canvas(20, 5)
    var n = c.put_text(Point(2, 1), String("hello"), default_attr())
    assert_equal(n, 5)
    assert_equal(c.get(2, 1).glyph, String("h"))
    assert_equal(c.get(6, 1).glyph, String("o"))
    assert_equal(c.get(7, 1).glyph, String(" "))  # untouched


def test_shell_escape_path_escapes_metacharacters() raises:
    """``shell_escape_path`` backslash-escapes the ASCII shell metacharacters
    so a dropped path survives the shell intact, and leaves plain characters
    (and multi-byte UTF-8) untouched."""
    assert_equal(shell_escape_path(String("/tmp/plain.txt")),
                 String("/tmp/plain.txt"))
    assert_equal(shell_escape_path(String("/tmp/My File.txt")),
                 String("/tmp/My\\ File.txt"))
    assert_equal(shell_escape_path(String("a(b)c&d;e")),
                 String("a\\(b\\)c\\&d\\;e"))
    assert_equal(shell_escape_path(String("a'b\"c`d$e")),
                 String("a\\'b\\\"c\\`d\\$e"))
    # Multi-byte UTF-8 (here an em dash) passes through unescaped.
    assert_equal(shell_escape_path(String("/tmp/a—b.txt")),
                 String("/tmp/a—b.txt"))


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


def test_file_io_read_and_stat() raises:
    """Check we can read & stat a file we know exists in the repo."""
    var path = String("examples/hello.mojo")
    var info = stat_file(path)
    assert_true(info.ok)
    assert_true(Int(info.size) > 0)
    var text = read_file(path)
    assert_equal(Int(info.size), len(text.as_bytes()))


def test_path_helpers() raises:
    assert_equal(join_path(String("a"), String("b")), String("a/b"))
    assert_equal(join_path(String("a/"), String("b")), String("a/b"))
    assert_equal(join_path(String(""), String("b")), String("b"))
    assert_equal(parent_path(String("/foo/bar")), String("/foo"))
    assert_equal(parent_path(String("/")), String("/"))
    assert_equal(parent_path(String("foo")), String("."))


def test_parse_line_history_splits_commits() raises:
    """``parse_line_history`` splits the RS-delimited commit blocks emitted
    by ``git log -L``, pulls the four US-separated header fields, and keeps
    each commit's range-scoped patch — without bleeding the next commit's
    header into the previous patch."""
    var rs = chr(0x1E)
    var us = chr(0x1F)
    var blob = (
        rs + "abc1234" + us + "Ada L" + us + "2026-05-09" + us
        + "Tweak reveal\n"
        + "diff --git a/x.mojo b/x.mojo\n"
        + "@@ -40,3 +40,3 @@\n"
        + "-    old\n"
        + "+    new\n"
        + rs + "def5678" + us + "Bob" + us + "2026-04-01" + us + "Initial\n"
        + "diff --git a/x.mojo b/x.mojo\n"
        + "@@ -0,0 +40,3 @@\n"
        + "+    first\n"
    )
    var entries = parse_line_history(blob)
    assert_equal(len(entries), 2)
    assert_equal(entries[0].short_sha, String("abc1234"))
    assert_equal(entries[0].author, String("Ada L"))
    assert_equal(entries[0].date, String("2026-05-09"))
    assert_equal(entries[0].subject, String("Tweak reveal"))
    assert_true(entries[0].patch.find(String("+    new")) >= 0)
    # The next commit's metadata must not leak into the first patch.
    assert_true(entries[0].patch.find(String("def5678")) < 0)
    assert_equal(entries[1].short_sha, String("def5678"))
    assert_equal(entries[1].subject, String("Initial"))
    assert_true(entries[1].patch.find(String("+    first")) >= 0)
    # Empty output (untracked / no-history / not a repo) → no entries.
    assert_equal(len(parse_line_history(String(""))), 0)


def test_display_order_pins_help_after_right_aligned() raises:
    """``_display_order_indices`` (which drives the native NSMenu bar
    order) must place a left-aligned Help menu dead last — after the
    right-aligned Project menu — so the native frontend follows the
    macOS convention of Help being the rightmost menu."""
    var bar = MenuBar()
    var sys_items = List[MenuItem]()
    sys_items.append(MenuItem(String("Quit"), String("quit")))
    bar.add(Menu(String("≡"), sys_items^, is_system=True))
    bar.add(_empty_menu(String("File")))
    bar.add(Menu(String("Project"), List[MenuItem](), right_aligned=True))
    bar.add(_empty_menu(String("Debug")))
    bar.add(_empty_menu(String("Help")))
    var order = bar._display_order_indices()
    var labels = List[String]()
    for i in range(len(order)):
        labels.append(bar.menus[order[i]].label)
    # System first, Help last, Project immediately before it.
    assert_equal(labels[0], String("≡"))
    assert_equal(labels[len(labels) - 1], String("Help"))
    assert_equal(labels[len(labels) - 2], String("Project"))


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


def test_file_tree_chevron_click_expands_immediately() raises:
    """A click on a directory's expand/collapse chevron toggles it on the
    first click — it must not take one click to select the row and a
    second to expand."""
    var t = FileTree()
    t.open(String("."))
    var screen = Rect(0, 0, 100, 30)
    var area = t.rect(screen)
    var examples_idx = -1
    for i in range(len(t.entries)):
        if t.entries[i].name == String("examples") and t.entries[i].is_dir:
            examples_idx = i
            break
    assert_true(examples_idx >= 0)
    # Nothing selected yet — the chevron click must not need a
    # select-first round trip.
    assert_equal(t.selected, -1)
    var initial_count = len(t.entries)
    # Chevron column for a depth-0 entry is the first content column;
    # rows start at the panel's top edge (no title row).
    var chevron_x = area.a.x + 1
    var row_y = area.a.y + examples_idx
    var click = Event.mouse_event(
        Point(chevron_x, row_y), MOUSE_BUTTON_LEFT, True, False,
    )
    assert_true(t.handle_mouse(click, screen))
    assert_true(t.entries[examples_idx].is_expanded)
    assert_true(len(t.entries) > initial_count)
    assert_equal(t.selected, examples_idx)
    # Same click again collapses right back — still single-click.
    assert_true(t.handle_mouse(click, screen))
    assert_false(t.entries[examples_idx].is_expanded)
    assert_equal(len(t.entries), initial_count)
    # A click on the *name* (past the chevron) of a non-selected dir
    # still selects without toggling, preserving the two-step open for
    # everything that isn't the chevron.
    t.selected = -1
    var name_click = Event.mouse_event(
        Point(chevron_x + 2, row_y), MOUSE_BUTTON_LEFT, True, False,
    )
    assert_true(t.handle_mouse(name_click, screen))
    assert_false(t.entries[examples_idx].is_expanded)
    assert_equal(t.selected, examples_idx)


def test_file_tree_starts_at_top_row_when_host_owns_menu() raises:
    """Terminal frontend: row 0 is the in-grid menu bar, the tree starts
    at row 1. Swift frontend (host-owned menu): the workspace starts at
    row 0 and Desktop.paint syncs the tree up one row so the panel
    doesn't render a blank line above its title."""
    var t = FileTree()
    var screen = Rect(0, 0, 100, 30)
    assert_equal(t.rect(screen).a.y, 1)   # terminal default
    var d = Desktop()
    d.detect_project_from(String("examples/hello.mojo"))
    d._cycle_file_tree()
    d.host_owns_menu = True
    var canvas = Canvas(screen.width(), screen.height())
    d.paint(canvas, screen)
    assert_equal(d.file_tree.top, 0)
    assert_equal(d.file_tree.rect(screen).a.y, 0)
    # And back: an in-grid menu reclaims row 0.
    d.host_owns_menu = False
    d.paint(canvas, screen)
    assert_equal(d.file_tree.rect(screen).a.y, 1)


def test_file_tree_reveal_expands_and_selects() raises:
    """View ▸ Show in file tree: ``reveal`` expands every ancestor of
    the target path and lands the selection on its entry."""
    var t = FileTree()
    t.open(String("."))
    t.reveal(String("./src/turbokod/file_tree.mojo"))
    assert_true(t.selected >= 0)
    assert_equal(t.entries[t.selected].name, String("file_tree.mojo"))
    assert_equal(t.entries[t.selected].depth, 2)
    # The ancestors got expanded along the way.
    var src_expanded = False
    for i in range(len(t.entries)):
        if t.entries[i].name == String("src") and t.entries[i].depth == 0:
            src_expanded = t.entries[i].is_expanded
    assert_true(src_expanded)
    # A path outside the root is a silent no-op.
    var before = t.selected
    t.reveal(String("/nonexistent/elsewhere.txt"))
    assert_equal(t.selected, before)


def test_file_tree_modified_rows_tinted_like_tab_bar() raises:
    """Files with uncommitted changes pick up the tab bar's dirty
    colors: LIGHT_GREEN surface for plain rows, GREEN with WHITE text
    when the row is also the selection."""
    var t = FileTree()
    t.open(String("."))
    var screen = Rect(0, 0, 100, 40)
    var area = t.rect(screen)
    # Flag the first top-level file entry as modified.
    var file_idx = -1
    for i in range(len(t.entries)):
        if not t.entries[i].is_dir:
            file_idx = i
            break
    assert_true(file_idx >= 0)
    t.modified_paths.append(t.entries[file_idx].path)
    var c = Canvas(screen.width(), screen.height())
    t.paint(c, screen)
    var row_y = area.a.y + file_idx       # scroll is 0, no title row
    var cx = area.a.x + 1                 # first content column (right dock)
    assert_equal(c.get(cx, row_y).attr.bg, LIGHT_GREEN)
    assert_equal(c.get(cx, row_y).attr.fg, BLACK)
    # Selecting the row flips it to the active-tab dirty colors.
    t.selected = file_idx
    t.paint(c, screen)
    assert_equal(c.get(cx, row_y).attr.bg, GREEN)
    assert_equal(c.get(cx, row_y).attr.fg, WHITE)


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
    # Multibyte content round-trips byte-for-byte (atomic rename preserves bytes).
    var mb = String("smörgåsbord — café 🚀\n")
    assert_true(write_file(path, mb))
    assert_equal(read_file(path), mb)
    # A payload larger than a typical single write exercises the short-write loop.
    var big = String("")
    for _ in range(5000):
        big += String("0123456789abcdef\n")
    assert_true(write_file(path, big))
    assert_equal(read_file(path), big)
    _ = external_call["unlink", Int32]((path + String("\0")).unsafe_ptr())


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


def test_parse_csi_kitty_u_ctrl_letter() raises:
    """Kitty kbd protocol: ``CSI <cp> ; <mod> u``. ``ESC[113;5u`` (Ctrl+Q)
    parses to the canonical ``(ord('q'), MOD_CTRL)``."""
    var ev = parse_input(String("\x1b[113;5u"))
    assert_true(ev[0].kind == EVENT_KEY)
    assert_equal(Int(ev[0].key), Int(ord("q")))
    assert_equal(Int(ev[0].mods), Int(MOD_CTRL))


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


def test_file_indexer_ignored_mode_skips_directory_entries() raises:
    """The async ``FileIndexer`` in ``ignored_only`` mode (QuickOpen's
    second enumeration) must yield individually-gitignored files but
    drop the ``dir/`` entries ``--directory`` emits for wholly-ignored
    directories — its ``poll`` parses the NUL stream separately from
    the sync ``_git_ls_project_files`` path, so test it separately."""
    var root = _temp_path(String("_indexer_ignored"))
    var init = List[String]()
    init.append(String("git"))
    init.append(String("init"))
    init.append(String("-q"))
    init.append(root)
    var cap = capture_command(init)
    if Int(cap.status) != 0:
        return  # no git available
    var nm = join_path(root, String("node_modules"))
    _ = external_call["mkdir", Int32](
        (nm + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(
        join_path(root, String(".gitignore")),
        String(".env\nnode_modules/\n"),
    ))
    assert_true(write_file(join_path(root, String(".env")), String("X=1\n")))
    assert_true(write_file(
        join_path(nm, String("dep.js")), String("// noise\n"),
    ))

    var idx_opt = FileIndexer.start(root, ignored_only=True)
    assert_true(Bool(idx_opt))
    var got = List[String]()
    # Poll until the child exits; tiny repo, so bound the wait at ~10 s.
    for _ in range(2000):
        var batch = idx_opt.value().poll(root)
        for i in range(len(batch)):
            got.append(batch[i])
        if not idx_opt.value().alive:
            break
        _ = external_call["usleep", Int32](Int32(5000))   # 5 ms
    assert_false(idx_opt.value().alive)
    var saw_env = False
    var saw_dir_entry = False
    for i in range(len(got)):
        if _contains(got[i], String("/.env")):
            saw_env = True
        if _contains(got[i], String("node_modules")):
            saw_dir_entry = True
    assert_true(saw_env)
    assert_false(saw_dir_entry)

    var rm = List[String]()
    rm.append(String("rm"))
    rm.append(String("-rf"))
    rm.append(root)
    _ = capture_command(rm)


def test_file_indexer_drains_full_stream_to_eof() raises:
    """The async ``FileIndexer`` must return *every* file git enumerates,
    not just whatever happened to be read before the child exited.

    Regression for a tail-drop race: ``poll`` used to flip ``alive`` to
    False as soon as ``waitpid`` reported the child gone — but a process
    can write its final batch into the pipe buffer and exit before we read
    it, so keying "done" off the exit silently dropped the *tail* of the
    listing (in a real project, the last-emitted paths like
    ``pyproject.toml`` / ``settings.py``, which then never showed up in
    Quick Open). The fix keys completion off pipe EOF instead.

    Triggering it needs output larger than one pipe buffer (~64 KiB) so
    git produces it in multiple bursts, plus a small inter-poll delay to
    widen the window where the child finishes mid-drain. We run several
    times and assert the count is the full set every time — with the bug
    this dropped entries on a sizeable fraction of runs."""
    var root = _temp_path(String("_indexer_eof"))
    var init = List[String]()
    init.append(String("git"))
    init.append(String("init"))
    init.append(String("-q"))
    init.append(root)
    var cap = capture_command(init)
    if Int(cap.status) != 0:
        return  # no git available
    # ~1600 files under a long-named dir so the NUL stream comfortably
    # exceeds a 64 KiB pipe buffer (avg path ~55 bytes ⇒ ~88 KiB). One
    # `sh` invocation keeps repo creation cheap.
    var sub = String("a_directory_with_a_deliberately_long_name_for_padding")
    var mk = List[String]()
    mk.append(String("sh"))
    mk.append(String("-c"))
    mk.append(
        String("cd ") + root + String(" && mkdir -p ") + sub
        + String(" && for i in $(seq 1 1600); do : > ")
        + sub + String("/source_file_number_$i.txt; done")
    )
    if Int(capture_command(mk).status) != 0:
        var rm0 = List[String]()
        rm0.append(String("rm"))
        rm0.append(String("-rf"))
        rm0.append(root)
        _ = capture_command(rm0)
        return
    var expected = 1600

    var ok = True
    for _ in range(6):
        var idx_opt = FileIndexer.start(root)
        assert_true(Bool(idx_opt))
        var count = 0
        for _ in range(5000):
            var batch = idx_opt.value().poll(root)
            count += len(batch)
            if not idx_opt.value().alive:
                break
            _ = external_call["usleep", Int32](Int32(1000))   # 1 ms
        # Once drained, no entries may be lost: alive must only flip after
        # EOF, so the full set is always returned.
        if count != expected:
            ok = False
    assert_true(ok)

    var rm = List[String]()
    rm.append(String("rm"))
    rm.append(String("-rf"))
    rm.append(root)
    _ = capture_command(rm)


def test_file_indexer_returns_its_pipes_on_every_path() raises:
    """A completed ``FileIndexer`` must give back the three descriptors it
    holds — and so must a terminated one.

    QuickOpen starts *two* of these per open (the tracked pass and the
    ignored-only pass), so a leak here cost 6 descriptors per Cmd+P, for
    the life of the process; a few hundred Quick Opens exhausted the
    table. The normal end-of-output path was the leaky one: ``_terminate``
    only fires past ``QUICK_OPEN_FILE_CAP``, and it wasn't closing
    anything either (the "close fds" comment sat above a statement that
    evaluated a field and discarded it).

    ``/dev/fd`` is the count of descriptors this process has open, so the
    assertion is direct rather than a proxy.
    """
    var root = _temp_path(String("_indexer_fds"))
    var init = List[String]()
    init.append(String("git"))
    init.append(String("init"))
    init.append(String("-q"))
    init.append(root)
    var cap = capture_command(init)
    if Int(cap.status) != 0:
        return  # no git available
    assert_true(write_file(join_path(root, String("a.txt")), String("hi\n")))

    # Warm once: the first spawn can open lazily-initialised state.
    _ = _drain_indexer(root)
    var base = len(list_directory(String("/dev/fd")))
    for _ in range(5):
        _ = _drain_indexer(root)
    assert_equal(len(list_directory(String("/dev/fd"))), base)

    # The cut-short path too — ``close()`` on the picker takes this one.
    for _ in range(5):
        var idx_opt = FileIndexer.start(root)
        assert_true(Bool(idx_opt))
        var idx = idx_opt.take()
        _ = idx.poll(root)
        idx._terminate()
    assert_equal(len(list_directory(String("/dev/fd"))), base)

    var rm = List[String]()
    rm.append(String("rm"))
    rm.append(String("-rf"))
    rm.append(root)
    _ = capture_command(rm)


def _drain_indexer(root: String) raises -> Int:
    """Run one ``FileIndexer`` to completion; return the path count."""
    var idx_opt = FileIndexer.start(root)
    if not idx_opt:
        return -1
    var idx = idx_opt.take()
    var total = 0
    for _ in range(5000):
        total += len(idx.poll(root))
        if not idx.alive:
            break
        _ = external_call["usleep", Int32](Int32(1000))   # 1 ms
    return total


def test_load_project_grammar_overrides_missing_file_is_empty() raises:
    """No project root, or a project root with no ``.turbokod/grammars.json``,
    yields an empty override list — the editor stays usable when the
    user hasn't opted any project into custom grammars."""
    assert_equal(len(load_project_grammar_overrides(String(""))), 0)
    var dir = _temp_path(String("_grammar_noconf"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_equal(len(load_project_grammar_overrides(dir)), 0)


def test_load_project_grammar_overrides_parses_extensions_map() raises:
    """A well-formed ``grammars.json`` produces one ``GrammarOverride``
    per entry in the ``extensions`` map. Order doesn't matter, but the
    ext → language_id pairing must round-trip exactly."""
    var dir = _temp_path(String("_grammar_ok"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var sub = dir + String("/.turbokod")
    _ = external_call["mkdir", Int32](
        (sub + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    assert_true(write_file(
        sub + String("/grammars.json"),
        String(
            "{\"extensions\": {\"html\": \"django-html\","
            " \"txt\": \"plain-text\"}}"
        ),
    ))
    var overrides = load_project_grammar_overrides(dir)
    assert_equal(len(overrides), 2)
    var html_lang = String("")
    var txt_lang = String("")
    for i in range(len(overrides)):
        if overrides[i].ext == String("html"):
            html_lang = overrides[i].language_id
        elif overrides[i].ext == String("txt"):
            txt_lang = overrides[i].language_id
    assert_equal(html_lang, String("django-html"))
    assert_equal(txt_lang, String("plain-text"))


def test_load_project_grammar_overrides_malformed_is_empty() raises:
    """Malformed JSON, the wrong top-level shape, or non-string values
    all degrade to "no overrides" — the highlighter falls back to the
    default extension map rather than crashing the load."""
    var dir = _temp_path(String("_grammar_bad"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var sub = dir + String("/.turbokod")
    _ = external_call["mkdir", Int32](
        (sub + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var path = sub + String("/grammars.json")
    assert_true(write_file(path, String("not valid json {")))
    assert_equal(len(load_project_grammar_overrides(dir)), 0)
    # Wrong top-level shape (array, not object).
    assert_true(write_file(path, String("[\"html\", \"django-html\"]")))
    assert_equal(len(load_project_grammar_overrides(dir)), 0)
    # Non-string values get skipped silently.
    assert_true(write_file(
        path,
        String("{\"extensions\": {\"html\": 42, \"py\": \"python\"}}"),
    ))
    var overrides = load_project_grammar_overrides(dir)
    assert_equal(len(overrides), 1)
    assert_equal(overrides[0].ext, String("py"))
    assert_equal(overrides[0].language_id, String("python"))


def test_write_grammar_overrides_round_trips_through_loader() raises:
    """``write_grammar_overrides`` emits the shape the loader reads:
    write a set of mappings, load them back, and they must match. The
    writer creates ``.turbokod/`` if it doesn't exist yet (the dialog's
    Save shouldn't require the dir to pre-exist)."""
    var dir = _temp_path(String("_grammar_write"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    # Note: no .turbokod subdir created here — the writer must mkdir it.
    var to_write = List[GrammarOverride]()
    to_write.append(GrammarOverride(String("html"), String("django-html")))
    to_write.append(GrammarOverride(String("txt"), String("plain-text")))
    assert_true(write_grammar_overrides(dir, to_write))
    var loaded = load_project_grammar_overrides(dir)
    assert_equal(len(loaded), 2)
    var html_lang = String("")
    var txt_lang = String("")
    for i in range(len(loaded)):
        if loaded[i].ext == String("html"):
            html_lang = loaded[i].language_id
        elif loaded[i].ext == String("txt"):
            txt_lang = loaded[i].language_id
    assert_equal(html_lang, String("django-html"))
    assert_equal(txt_lang, String("plain-text"))


def test_write_grammar_overrides_drops_blank_and_duplicate_rows() raises:
    """Half-filled rows (empty ext or language) never reach disk, and a
    duplicate extension keeps only its first mapping — matching
    ``GrammarRegistry.lookup_override``'s first-match resolution so the
    UI can't write a config that shadows itself."""
    var dir = _temp_path(String("_grammar_write_clean"))
    _ = external_call["mkdir", Int32](
        (dir + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var to_write = List[GrammarOverride]()
    to_write.append(GrammarOverride(String("html"), String("django-html")))
    to_write.append(GrammarOverride(String(""), String("python")))  # blank ext
    to_write.append(GrammarOverride(String("md"), String("")))      # blank lang
    to_write.append(GrammarOverride(String("html"), String("html"))) # dup ext
    assert_true(write_grammar_overrides(dir, to_write))
    var loaded = load_project_grammar_overrides(dir)
    assert_equal(len(loaded), 1)
    assert_equal(loaded[0].ext, String("html"))
    assert_equal(loaded[0].language_id, String("django-html"))


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
    # On-save actions are per-project now — ``_run_on_save_actions`` walks
    # the project's cached enabled set, not the global library.
    d.project_on_save.append(OnSaveAction(
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


def test_themes_have_full_palettes() raises:
    """Every bundled theme exposes a complete 256-entry RGB palette, and the
    standard xterm cube + grayscale tail is preserved across all of them (only
    the chrome + reserved slots are overridden)."""
    var themes = built_in_themes()
    assert_true(len(themes) >= 12)
    for i in range(len(themes)):
        var pal = themes[i].palette.copy()
        assert_equal(len(pal), 256)
        # Cube tail untouched: last cube cell is white, grayscale ramp intact.
        assert_equal(pal[231], UInt32(0xFFFFFF))
        assert_equal(pal[232], UInt32(0x080808))
        assert_equal(pal[255], UInt32(0xEEEEEE))


def test_default_theme_matches_classic_look() raises:
    """The default theme must reproduce the pre-theme RGB exactly, so existing
    screenshots / muscle memory are unchanged. This pins the reserved editor +
    syntax slots to the classic Turbo C++ colors."""
    assert_equal(default_theme_name(), String("Turbo C++ 3.0"))
    var names = theme_names()
    assert_equal(names[0], String("Turbo C++ 3.0"))
    var d = theme_by_name(String("Turbo C++ 3.0"))
    assert_equal(d.palette[Int(EDITOR_BG)], UInt32(0x0021AA))   # classic blue
    assert_equal(d.palette[Int(EDITOR_FG)], UInt32(0xE5E5E5))   # light gray
    assert_equal(d.palette[Int(SYN_IDENT)], UInt32(0x00FF00))   # light green
    # Caret block: the classic blue-glyph-on-yellow-block pair, now on
    # dedicated slots so every theme can pin its own cursor color.
    assert_equal(d.palette[Int(CARET_FG)], UInt32(0x0021AA))
    assert_equal(d.palette[Int(CARET_BG)], UInt32(0xCDCD00))
    # Focused border: classic white by default; light themes set a dark one.
    assert_equal(d.palette[Int(BORDER_FOCUS)], UInt32(0xFFFFFF))
    var sl = theme_by_name(String("Solarized Light"))
    assert_equal(sl.palette[Int(BORDER_FOCUS)], UInt32(0x002B36))
    # ANSI slots match the original Swift base16.
    assert_equal(d.palette[4], UInt32(0x0021AA))                # BLUE
    assert_equal(d.palette[7], UInt32(0xE5E5E5))                # LIGHT_GRAY
    assert_equal(d.palette[15], UInt32(0xFFFFFF))               # WHITE


def test_theme_lookup_and_distinctness() raises:
    """An unknown name falls back to the default; a real alternate theme has a
    genuinely different editor background."""
    var fallback = theme_by_name(String("does-not-exist"))
    assert_equal(fallback.palette[Int(EDITOR_BG)], UInt32(0x0021AA))
    var dracula: Theme = theme_by_name(String("Dracula"))
    assert_equal(dracula.palette[Int(EDITOR_BG)], UInt32(0x282A36))
    assert_true(
        dracula.palette[Int(EDITOR_BG)] != fallback.palette[Int(EDITOR_BG)]
    )


def test_attr_to_sgr_rgb_resolves_palette() raises:
    """The truecolor SGR renderer resolves indices through the supplied
    palette and emits ``38;2;r;g;b`` / ``48;2;r;g;b`` so a theme renders in
    the terminal independent of the user's own color scheme."""
    var d = theme_by_name(String("Turbo C++ 3.0"))
    var sgr = attr_to_sgr_rgb(Attr(SYN_IDENT, EDITOR_BG), d.palette)
    # SYN_IDENT = 0x00FF00 -> fg 0;255;0 ; EDITOR_BG = 0x0021AA -> bg 0;33;170.
    assert_true(sgr.find(String("38;2;0;255;0")) >= 0)
    assert_true(sgr.find(String("48;2;0;33;170")) >= 0)


def test_attr_to_sgr_rgb_emits_truecolor_channels() raises:
    """When a channel is truecolor (e.g. a pty cell painted by
    ``ESC[38;2;…``), ``attr_to_sgr_rgb`` emits the cell's own ``fg_rgb`` /
    ``bg_rgb`` directly rather than looking the folded index up in the
    palette — so truecolor terminals get the exact color, not the 256
    approximation."""
    var d = theme_by_name(String("Turbo C++ 3.0"))
    var a = Attr().with_fg_rgb(0x123456).with_bg_rgb(0xAB12FF)
    var sgr = attr_to_sgr_rgb(a, d.palette)
    assert_true(sgr.find(String("38;2;18;52;86")) >= 0)    # 0x12,0x34,0x56
    assert_true(sgr.find(String("48;2;171;18;255")) >= 0)  # 0xAB,0x12,0xFF


def test_attr_to_sgr_indexed_folds_theme_through_palette() raises:
    """On a 256-color-only terminal (Apple Terminal.app) the indexed renderer
    must resolve theme indices through the palette and fold to nearest-256 —
    NOT emit the raw index. EDITOR_BG is index 16, which is plain black in the
    xterm cube; the theme's actual blue (0x0021AA) must fold to a blue cube
    color instead. This is the regression guard for the black-editor-background
    bug."""
    var d = theme_by_name(String("Turbo C++ 3.0"))
    var sgr = attr_to_sgr_indexed(Attr(EDITOR_FG, EDITOR_BG), d.palette)
    # EDITOR_BG = 0x0021AA folds to cube index 19 (a blue), never raw 16/black.
    assert_true(sgr.find(String(";48;5;19")) >= 0)
    assert_true(sgr.find(String(";48;5;16")) < 0)
    # EDITOR_FG = 0xE5E5E5 folds to the gray ramp (253), readable on the blue.
    assert_true(sgr.find(String(";38;5;253")) >= 0)


def test_attr_to_sgr_indexed_folds_truecolor_channels() raises:
    """A cell carrying its own truecolor RGB (a pty cell) folds that RGB to
    nearest-256 in the indexed path rather than reading the palette index."""
    var d = theme_by_name(String("Turbo C++ 3.0"))
    var a = Attr().with_fg_rgb(0x0021AA)
    var sgr = attr_to_sgr_indexed(a, d.palette)
    assert_true(sgr.find(String(";38;5;19")) >= 0)  # 0x0021AA -> cube 19


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


def test_json_surrogate_pair_decodes_to_astral_utf8() raises:
    """A UTF-16 surrogate pair (``\\uD83D\\uDE00``) must combine into one
    codepoint and emit the 4-byte UTF-8 for U+1F600 (😀), not two 3-byte
    WTF-8 sequences. An unpaired surrogate degrades to U+FFFD."""
    var dec = parse_json(String("\"\\uD83D\\uDE00\""))
    assert_true(dec.is_string())
    assert_equal(dec.as_str(), String("😀"))
    # Round-trips back through the parser unchanged.
    var again = parse_json(encode_json(dec))
    assert_equal(again.as_str(), String("😀"))
    # Unpaired high surrogate → replacement character, no crash.
    var lone = parse_json(String("\"\\uD83Dx\""))
    assert_true(lone.is_string())
    assert_equal(lone.as_str(), String("�x"))


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
    # Attr is the shadow attr — DARK_GRAY on the dark pane surface.
    assert_equal(c.get(2, 0).attr.fg, DARK_GRAY)
    assert_equal(c.get(2, 0).attr.bg, PANE_BG)
    assert_equal(c.get(3, 1).attr.fg, DARK_GRAY)
    assert_equal(c.get(3, 1).attr.bg, PANE_BG)
    # Cells outside the rect are untouched.
    assert_equal(c.get(0, 0).attr.fg, WHITE)
    assert_equal(c.get(0, 0).attr.bg, BLUE)
    assert_equal(c.get(4, 0).attr.fg, WHITE)


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


def test_on_save_equal_matching() raises:
    """``on_save_equal`` is structural across all four fields — the identity
    used for checkbox state, enable/disable, and library back-fill dedup."""
    var a = OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    )
    var b = OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    )
    assert_true(on_save_equal(a, b))
    assert_false(on_save_equal(a, OnSaveAction(
        String("rust"), String("/usr/bin/black"),
        List[String](), String(""),
    )))
    assert_false(on_save_equal(a, OnSaveAction(
        String("python"), String("/opt/black"),
        List[String](), String(""),
    )))
    var with_arg = OnSaveAction(
        String("python"), String("/usr/bin/black"),
        List[String](), String(""),
    )
    with_arg.args.append(String("--x"))
    assert_false(on_save_equal(a, with_arg))


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


def test_drafts_store_round_trip() raises:
    """Untitled buffers persist their full content + geometry + cursor
    and decode back to the same fields. Unlike the session store there's
    no path involved — the content is the payload that survives a
    restart."""
    var root = String("/tmp/turbokod_drafts_round_trip")
    var cleanup = String("rm -rf '") + root + String("'\0")
    _ = external_call["system", Int32](cleanup.unsafe_ptr())
    _ = external_call["mkdir", Int32](
        (root + String("\0")).unsafe_ptr(), Int32(0o755),
    )
    var drafts = List[StoredDraft]()
    var d0 = StoredDraft()
    d0.seq = 1
    d0.content = String("hello\nworld")
    d0.rect_a_x = 4
    d0.rect_a_y = 2
    d0.rect_b_x = 50
    d0.rect_b_y = 18
    d0.restore_a_x = 4
    d0.restore_a_y = 2
    d0.restore_b_x = 50
    d0.restore_b_y = 18
    d0.cursor_row = 1
    d0.cursor_col = 3
    d0.scroll_y = 7
    d0.last_focus_ms = 123456
    drafts.append(d0^)
    var d1 = StoredDraft()
    d1.seq = 5
    d1.content = String("scratch")
    drafts.append(d1^)
    assert_true(save_drafts(root, drafts))
    var loaded = load_drafts(root)
    assert_equal(len(loaded), 2)
    assert_equal(loaded[0].seq, 1)
    assert_equal(loaded[0].content, String("hello\nworld"))
    assert_equal(loaded[0].rect_a_x, 4)
    assert_equal(loaded[0].rect_b_y, 18)
    assert_equal(loaded[0].cursor_row, 1)
    assert_equal(loaded[0].cursor_col, 3)
    assert_equal(loaded[0].scroll_y, 7)
    assert_equal(loaded[0].last_focus_ms, 123456)
    assert_equal(loaded[1].seq, 5)
    assert_equal(loaded[1].content, String("scratch"))
    _ = external_call["system", Int32](cleanup.unsafe_ptr())


def test_drafts_store_load_missing_returns_empty() raises:
    """No file → empty list, same contract as the sibling stores."""
    var drafts = load_drafts(String("/tmp/turbokod_drafts_does_not_exist_xyz"))
    assert_equal(len(drafts), 0)


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


def test_compute_deletion_revert_block_reinserts_lines() raises:
    """Clicking the deletion marker on the row above a removed run yields a
    block that re-inserts the removed HEAD lines just below that row (an
    empty buffer range, so ``apply_revert_block`` inserts not replaces)."""
    var head = (
        String("alpha\n")
        + String("beta\n")
        + String("gamma\n")
        + String("delta\n")
    )
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("delta"))
    buffer.append(String(""))
    var block_opt = compute_deletion_revert_block(head, buffer, 0)
    assert_true(Bool(block_opt))
    var block = block_opt.value().copy()
    # Empty range at row 1 → pure insertion of the two removed lines.
    assert_equal(block.buf_start, 1)
    assert_equal(block.buf_end_excl, 1)
    assert_equal(len(block.head_lines), 2)
    assert_equal(block.head_lines[0], String("beta"))
    assert_equal(block.head_lines[1], String("gamma"))


def test_compute_deletion_revert_block_unchanged_row_returns_empty() raises:
    """A row with no pure deletion below it yields no deletion block."""
    var head = String("alpha\nbeta\n")
    var buffer = List[String]()
    buffer.append(String("alpha"))
    buffer.append(String("beta"))
    buffer.append(String(""))
    var block_opt = compute_deletion_revert_block(head, buffer, 0)
    assert_true(not Bool(block_opt))


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


def test_detect_pytest_tests() raises:
    """Editor's gutter test detection finds ``def test*`` / ``class Test*``
    with correct pytest node ids, honoring class nesting and pytest's
    collection rules (no methods of non-Test classes)."""
    var src = String(
        "import pytest\n"
        "\n"
        "def test_top():\n"
        "    pass\n"
        "\n"
        "class TestThing:\n"
        "    def test_method(self):\n"
        "        pass\n"
        "\n"
        "class Helper:\n"
        "    def test_not_collected(self):\n"
        "        pass\n"
        "\n"
        "async def test_async():\n"
        "    pass\n"
    )
    var ed = Editor(src)
    ed.file_path = String("/x/test_foo.py")
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.test_rows), 4)
    assert_equal(ed.test_nodes[0], String("/x/test_foo.py::test_top"))
    assert_equal(ed.test_nodes[1], String("/x/test_foo.py::TestThing"))
    assert_equal(
        ed.test_nodes[2], String("/x/test_foo.py::TestThing::test_method")
    )
    assert_equal(ed.test_nodes[3], String("/x/test_foo.py::test_async"))


def test_detect_skips_non_test_file() raises:
    """A file pytest wouldn't collect (not ``test_*.py`` / ``*_test.py``)
    gets no run-icons, even with ``test_*`` functions."""
    var ed = Editor(String("def test_top():\n    pass\n"))
    ed.file_path = String("/x/helpers.py")
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.test_rows), 0)


def test_detect_custom_python_files_glob() raises:
    """A project's pytest ``python_files`` globs (e.g. ``*__tests.py``)
    drive detection: a file the defaults would skip becomes a test file
    once the project's globs are pushed via ``set_test_file_globs``."""
    var ed = Editor(String("def test_round():\n    assert True\n"))
    ed.file_path = String("/x/utils__tests.py")
    # With pytest defaults this isn't a test file.
    var registry = GrammarRegistry()
    var speller = Speller()
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.test_rows), 0)
    # Push the project's globs → now it's collectable.
    var globs = List[String]()
    globs.append(String("test_*.py"))
    globs.append(String("*__tests.py"))
    ed.set_test_file_globs(globs)
    ed.flush_highlights(registry, speller)
    assert_equal(len(ed.test_rows), 1)
    assert_equal(ed.test_nodes[0], String("/x/utils__tests.py::test_round"))


def test_write_file_in_place_fallback_replaces_fully() raises:
    """When the directory is read-only (no sibling temp possible) but the
    file itself is writable, ``write_file`` falls back to an in-place
    overwrite. That path must fully replace the contents — including
    ``ftruncate``-ing away a stale tail when the new content is shorter —
    not leave a hybrid of new-prefix + old-suffix.
    """
    var dir = String("/tmp/turbokod_test_home/ro_writedir")
    var path = dir + String("/data.txt")
    var c_dir = dir + String("\0")

    # Fresh, writable dir + a long initial file.
    _ = external_call["mkdir", Int32](c_dir.unsafe_ptr(), Int32(0o755))
    var long = String("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")  # 36 bytes
    assert_true(write_file(path, long))
    assert_equal(read_file(path), long)

    # Make the directory read-only so the ``.tk-tmp`` create fails and the
    # in-place fallback (open O_WRONLY, no upfront truncate) is exercised.
    _ = external_call["chmod", Int32](c_dir.unsafe_ptr(), Int32(0o555))

    var short = String("bb")  # shorter than the old content
    var wrote = write_file(path, short)

    # Restore write perms before asserting so cleanup can't be blocked.
    _ = external_call["chmod", Int32](c_dir.unsafe_ptr(), Int32(0o755))

    assert_true(wrote)
    # The stale tail of the old 36-byte file must be gone — exact match,
    # not "bb" followed by leftover 'A's.
    assert_equal(read_file(path), short)

    _ = delete_path(path)


def main() raises:
    setup_test_env()
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
    test_point_arithmetic()
    test_rect_basics()
    test_rect_helpers()
    test_attr()
    test_attr_to_sgr_plain_underline()
    test_attr_to_sgr_curly_colored_underline()
    test_canvas_put_text()
    test_shell_escape_path_escapes_metacharacters()
    test_canvas_box()
    test_canvas_fill()
    test_parse_input_keys()
    test_parse_window_size_report()
    test_parse_input_focus_events()
    test_parse_input_sgr_mouse()
    test_file_io_read_and_stat()
    test_path_helpers()
    test_parse_line_history_splits_commits()
    test_display_order_pins_help_after_right_aligned()
    test_system_menu_pins_to_left_edge()
    test_file_tree_expand_collapse()
    test_file_tree_filters_dotfiles()
    test_file_tree_chevron_click_expands_immediately()
    test_file_tree_starts_at_top_row_when_host_owns_menu()
    test_file_tree_reveal_expands_and_selects()
    test_file_tree_modified_rows_tinted_like_tab_bar()
    test_write_file_round_trip()
    test_editorconfig_parse_basic()
    test_editorconfig_match_section()
    test_editorconfig_load_from_fixture()
    test_canvas_substitutes_control_glyphs()
    test_parse_csi_modify_other_keys_normalizes_ctrl_q()
    test_parse_csi_modify_other_keys_ctrl_shift_f()
    test_parse_csi_modify_other_keys_cmd_shift_f_keeps_meta()
    test_parse_csi_unknown_sequence_is_consumed_whole()
    test_parse_osc_open_path_emits_event_open_path()
    test_parse_osc_open_path_with_line_suffix()
    test_parse_osc_open_path_st_terminator()
    test_parse_osc_unknown_is_consumed_silently()
    test_parse_osc_partial_defers()
    test_parse_csi_modify_other_keys_cmd_letter_keeps_meta()
    test_parse_csi_modify_other_keys_cmd_backtick_keeps_key_intact()
    test_parse_csi_kitty_u_ctrl_letter()
    test_top_level_esc_does_not_quit()
    test_default_hotkey_cmd_q_returns_quit()
    test_default_hotkey_cmd_f_opens_find_prompt()
    test_default_hotkey_cmd_s_saves_focused_editor()
    test_file_indexer_ignored_mode_skips_directory_entries()
    test_file_indexer_drains_full_stream_to_eof()
    test_file_indexer_returns_its_pipes_on_every_path()
    test_load_project_grammar_overrides_missing_file_is_empty()
    test_load_project_grammar_overrides_parses_extensions_map()
    test_load_project_grammar_overrides_malformed_is_empty()
    test_write_grammar_overrides_round_trips_through_loader()
    test_write_grammar_overrides_drops_blank_and_duplicate_rows()
    test_user_grammar_path_for_ext_misses_when_not_installed()
    test_on_save_action_default_is_empty()
    test_on_save_action_copy_preserves_args()
    test_apply_language_overrides_replaces_candidates()
    test_apply_language_overrides_adds_new_language()
    test_file_tree_type_to_jump()
    test_on_save_action_reloads_buffer_when_action_rewrites_file()
    test_word_at_helper()
    test_themes_have_full_palettes()
    test_default_theme_matches_classic_look()
    test_theme_lookup_and_distinctness()
    test_attr_to_sgr_rgb_resolves_palette()
    test_attr_to_sgr_rgb_emits_truecolor_channels()
    test_attr_to_sgr_indexed_folds_theme_through_palette()
    test_attr_to_sgr_indexed_folds_truecolor_channels()
    test_json_round_trip_lsp_envelope()
    test_json_string_escapes()
    test_json_surrogate_pair_decodes_to_astral_utf8()
    test_json_parse_errors_raise()
    test_json_floats_round_trip_as_text()
    test_detect_project_language_python_markers()
    test_detect_project_language_no_match()
    test_canvas_darken_rect_preserves_glyph()
    test_string_utils_slice_codepoints_handles_multibyte()
    test_on_save_equal_matching()
    test_doc_registry_lookup()
    test_doc_install_command_shape()
    test_drafts_store_round_trip()
    test_drafts_store_load_missing_returns_empty()
    test_parse_unified_diff_splits_two_files()
    test_parse_unified_diff_handles_pure_delete()
    test_compute_deletion_revert_block_reinserts_lines()
    test_compute_deletion_revert_block_unchanged_row_returns_empty()
    test_compute_revert_block_modified_line()
    test_compute_revert_block_added_line()
    test_compute_revert_block_unchanged_returns_empty()
    test_build_minimal_patch_keeps_only_target_plus_line()
    test_build_minimal_patch_demotes_paired_minus_to_context()
    test_build_minimal_patch_reverse_drops_paired_minus()
    test_build_minimal_patch_returns_empty_for_non_pm_lines()
    test_build_minimal_patch_drops_other_hunks()
    test_canvas_put_wrapped_text_paints_inside_rect_only()
    test_canvas_put_wrapped_text_returns_zero_for_empty_rect()
    test_detect_pytest_tests()
    test_detect_skips_non_test_file()
    test_detect_custom_python_files_glob()
    test_write_file_in_place_fallback_replaces_fully()
    print("core: 116 tests passed")
