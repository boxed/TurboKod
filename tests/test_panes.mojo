"""Terminal emulation and output panes.

One of the per-topic suites split out of the former
``test_basic.mojo``; shared fixtures live in ``tests/support.mojo``
and ``scripts/run_tests.sh`` runs every suite.
"""

from std.testing import assert_equal, assert_false, assert_true
from turbokod.canvas import Canvas
from turbokod.claude_detect import (
    CLAUDE_ACTIVE, CLAUDE_NONE, CLAUDE_WAITING, CLAUDE_WORKING
)
from turbokod.colors import (
    Attr, BLACK, LIGHT_GRAY, RED, FG_TRUECOLOR, BG_TRUECOLOR, _rgb_to_256,
    attr_to_sgr, default_attr, parse_sgr
)
from turbokod.debug_pane import DebugPane
from turbokod.text_view import TextLog, VisualLine, wrap_lines
from turbokod.window import (
    PANEL_STATE_MAXIMIZED, PANEL_STATE_MINIMIZED, PANEL_STATE_NORMAL
)
from turbokod.events import (
    Event, EVENT_KEY, EVENT_MOUSE, KEY_DOWN, KEY_ESC, KEY_LEFT, KEY_RIGHT,
    KEY_TAB, KEY_UP, MOD_ALT, MOD_CTRL, MOD_NONE, MOD_SHIFT,
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_NONE, MOUSE_WHEEL_UP
)
from turbokod.geometry import Point, Rect
from turbokod.terminal import parse_input
from turbokod import Vt
from turbokod.terminal_pane import TerminalPane

from support import setup_test_env


def _terminal_pane_with_text(text: String) -> TerminalPane:
    """A pane whose VT row 0 holds ``text``, with a body rect set so
    screen Point(x, 1) maps to grid (row 0, col x). Skips paint so the
    test doesn't need a TTY."""
    var pane = TerminalPane()
    pane.vt.feed_string(text)
    # Body starts one row below the panel top (the chrome border row),
    # so a body click lands at y >= 1 and never trips chrome hit-tests.
    pane.sel._last_body = Rect(Point(0, 1), Point(pane.vt.cols, 25))
    return pane^


def _assert_visual_eq(a: VisualLine, b: VisualLine) raises:
    assert_equal(a.line_idx, b.line_idx)
    assert_equal(a.byte_start, b.byte_start)
    assert_equal(a.byte_end, b.byte_end)
    assert_equal(a.cell_start, b.cell_start)
    assert_equal(a.cell_count, b.cell_count)
    assert_equal(a.indent_cells, b.indent_cells)


def test_terminal_pane_attention_on_working_to_waiting() raises:
    """Working → waiting fires exactly one attention event once the
    done-debounce window elapses; the intermediate ``active`` wobble
    neither fires nor disarms, and a working flare inside the window
    cancels the pending done."""
    var pane = TerminalPane()
    pane._note_claude_state(CLAUDE_WORKING, 0)
    assert_equal(pane.take_attention(), 0)
    pane._note_claude_state(CLAUDE_ACTIVE, 100)       # between-turns wobble
    assert_equal(pane.take_attention(), 0)
    # First waiting only starts the debounce timer — no event yet.
    pane._note_claude_state(CLAUDE_WAITING, 200)
    assert_equal(pane.take_attention(), 0)
    # Still inside the 1s window: no event.
    pane._note_claude_state(CLAUDE_WAITING, 900)
    assert_equal(pane.take_attention(), 0)
    # Past the window: fires exactly one.
    pane._note_claude_state(CLAUDE_WAITING, 1300)
    assert_equal(pane.take_attention(), 1)
    # Disarmed: staying in waiting doesn't keep firing.
    pane._note_claude_state(CLAUDE_WAITING, 1400)
    assert_equal(pane.take_attention(), 0)
    # A transient working flare inside the debounce window cancels the
    # pending done — a spinner-frame dropout produces no spurious event.
    pane._note_claude_state(CLAUDE_WORKING, 2000)
    pane._note_claude_state(CLAUDE_NONE, 2100)        # candidate armed
    pane._note_claude_state(CLAUDE_WORKING, 2200)     # resumed — cancels
    pane._note_claude_state(CLAUDE_NONE, 2300)        # candidate re-armed
    assert_equal(pane.take_attention(), 0)            # not yet 1s held
    # Claude exiting after a working stint counts as "done" once held.
    pane._note_claude_state(CLAUDE_NONE, 3400)
    assert_equal(pane.take_attention(), 1)
    # Waiting without ever having been working is not attention-worthy.
    pane._note_claude_state(CLAUDE_WAITING, 3500)
    assert_equal(pane.take_attention(), 0)


def test_terminal_double_click_selects_word() raises:
    var pane = _terminal_pane_with_text(String("hello world foo bar"))
    var panel = Rect(Point(0, 0), Point(80, 25))
    # Press with click_count == 2 — the terminal parser stamps this the
    # way the native/terminal frontends do for a genuine double-click.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(8, 1), MOUSE_BUTTON_LEFT, True, False,
                          MOD_NONE, 2), panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(8, 1), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_true(pane.has_selection())
    assert_equal(pane.selected_text(), String("world"))


def test_terminal_double_click_drag_extends_by_word() raises:
    var pane = _terminal_pane_with_text(String("hello world foo bar"))
    var panel = Rect(Point(0, 0), Point(80, 25))
    _ = pane.handle_mouse(
        Event.mouse_event(Point(8, 1), MOUSE_BUTTON_LEFT, True, False,
                          MOD_NONE, 2), panel,
    )
    # Drag (button held, motion) onto "bar" — selection grows whole
    # words, not cell-by-cell.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(17, 1), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(17, 1), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_equal(pane.selected_text(), String("world foo bar"))


def test_terminal_double_click_drag_backward_by_word() raises:
    var pane = _terminal_pane_with_text(String("hello world foo bar"))
    var panel = Rect(Point(0, 0), Point(80, 25))
    # Double-click "foo" (col 13), then drag back to "hello" (col 2).
    _ = pane.handle_mouse(
        Event.mouse_event(Point(13, 1), MOUSE_BUTTON_LEFT, True, False,
                          MOD_NONE, 2), panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(2, 1), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(2, 1), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_equal(pane.selected_text(), String("hello world foo"))


def test_terminal_triple_click_drag_extends_by_line() raises:
    var pane = _terminal_pane_with_text(String("row zero\r\nrow one\r\nrow two"))
    var panel = Rect(Point(0, 0), Point(80, 25))
    # Triple-click row 0, then drag down to row 2 — whole rows select.
    _ = pane.handle_mouse(
        Event.mouse_event(Point(3, 1), MOUSE_BUTTON_LEFT, True, False,
                          MOD_NONE, 3), panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(3, 3), MOUSE_BUTTON_LEFT, True, True),
        panel,
    )
    _ = pane.handle_mouse(
        Event.mouse_event(Point(3, 3), MOUSE_BUTTON_LEFT, False, False),
        panel,
    )
    assert_equal(pane.selected_text(), String("row zero\nrow one\nrow two"))


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


def test_terminal_parses_bare_modifier_transition() raises:
    """``CSI <mod-id> ; <state> z`` — turbokod-private bare-modifier
    transition emitted by the native wrapper on every press / release
    of a lone modifier key. The two-param 'z' final shares the same
    parse branch as the modifier-arrow forms, so this is the regression
    test that protects it from being shadowed."""
    from turbokod.events import EVENT_MOD_KEY, MOD_KEY_ALT, MOD_KEY_META
    var alt_press = parse_input(String("\x1b[2;1z"))
    assert_true(alt_press[0].kind == EVENT_MOD_KEY)
    assert_equal(alt_press[0].key, MOD_KEY_ALT)
    assert_true(alt_press[0].pressed)
    assert_equal(alt_press[1], 6)
    var alt_release = parse_input(String("\x1b[2;0z"))
    assert_true(alt_release[0].kind == EVENT_MOD_KEY)
    assert_equal(alt_release[0].key, MOD_KEY_ALT)
    assert_false(alt_release[0].pressed)
    var super_press = parse_input(String("\x1b[4;1z"))
    assert_true(super_press[0].kind == EVENT_MOD_KEY)
    assert_equal(super_press[0].key, MOD_KEY_META)
    assert_true(super_press[0].pressed)


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


def test_terminal_pane_esc_steps_chrome_ladder_without_claude() raises:
    """Baseline for the Claude exception below: with plain shell
    output in the pane, ESC walks the dock chrome ladder
    (NORMAL → MINIMIZED) instead of reaching the child."""
    var pane = TerminalPane()
    pane.focused = True
    pane.vt.feed_string(String("$ ls\nfile.txt\n$ "))
    assert_equal(Int(pane.dock.state), Int(PANEL_STATE_NORMAL))
    assert_true(pane.handle_key(Event.key_event(KEY_ESC)))
    assert_equal(Int(pane.dock.state), Int(PANEL_STATE_MINIMIZED))


def test_terminal_pane_esc_bypasses_chrome_ladder_in_claude_mode() raises:
    """When a Claude Code session is detected in the pane, ESC must go
    to the child (it interrupts the agent / clears the input) rather
    than stepping the dock down the max → normal → min ladder. The pty
    write is a no-op without a live child — the dock state is the
    observable: it must NOT change."""
    var pane = TerminalPane()
    pane.focused = True
    # Park the marker near the grid bottom — the detector scans only
    # the bottom rows (``tail_rows``), matching where Claude actually
    # paints its status line.
    pane.vt.feed_string(
        String("\x1b[23;1H✻ Pondering… (12s · esc to interrupt)")
    )
    assert_equal(Int(pane.dock.state), Int(PANEL_STATE_NORMAL))
    assert_true(pane.handle_key(Event.key_event(KEY_ESC)))
    assert_equal(Int(pane.dock.state), Int(PANEL_STATE_NORMAL))
    pane.dock.set_state(PANEL_STATE_MAXIMIZED)
    assert_true(pane.handle_key(Event.key_event(KEY_ESC)))
    assert_equal(Int(pane.dock.state), Int(PANEL_STATE_MAXIMIZED))


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


def test_text_log_streaming_appends_continue_open_line() raises:
    """Raw stdout/stderr arrives in chunks with no newline between
    them — pytest emits one ``.`` per test, and each lands in its own
    drain tick. A ``streaming`` append whose chunk doesn't end in a
    newline must continue the current row instead of starting a new
    one, so the dots stay on a single line (the reported bug was one
    dot per line)."""
    var log = TextLog(default_attr())
    # Three dots arrive as three separate streaming chunks, then the
    # line is closed by pytest's percentage suffix + newline.
    log.append(String("."), streaming=True)
    log.append(String("."), streaming=True)
    log.append(String("."), streaming=True)
    assert_equal(len(log.lines), 1)
    assert_equal(log.lines[0], String("..."))
    log.append(String(" [100%]\n"), streaming=True)
    assert_equal(len(log.lines), 1)
    assert_equal(log.lines[0], String("... [100%]"))
    # After the newline the line is closed, so the next chunk starts a
    # fresh row.
    log.append(String("next"), streaming=True)
    assert_equal(len(log.lines), 2)
    assert_equal(log.lines[1], String("next"))


def test_text_log_discrete_appends_stay_separate_rows() raises:
    """Non-streaming (console-banner) appends keep one-row-per-call
    semantics even without a trailing newline — and a discrete append
    must close any open streaming line so a later streaming chunk
    doesn't glue onto the banner."""
    var log = TextLog(default_attr())
    log.append(String("$ pytest"))   # discrete, no newline
    log.append(String("$ done"))     # discrete, no newline
    assert_equal(len(log.lines), 2)
    assert_equal(log.lines[0], String("$ pytest"))
    assert_equal(log.lines[1], String("$ done"))
    # A streaming dot after a discrete line starts its own row, not a
    # continuation of "$ done".
    log.append(String("."), streaming=True)
    assert_equal(len(log.lines), 3)
    assert_equal(log.lines[2], String("."))


def test_text_log_streaming_continuation_keeps_layout_cache() raises:
    """Continuing an open line mutates the last row in place; the
    incremental layout cache must re-wrap just that line and stay
    equal to a fresh full wrap (no stale or duplicated visual rows)."""
    var log = TextLog(default_attr())
    var canvas = Canvas(40, 12)
    log.append(String("alpha\n"), streaming=True)
    log.paint(canvas, Rect(0, 0, 20, 5))   # prime the cache at width 20
    # Stream a run of dots that will eventually wrap past 20 cells.
    for _ in range(30):
        log.append(String("."), streaming=True)
    var fresh = wrap_lines(log.lines, 20)
    assert_equal(len(log.last_visual), len(fresh))
    for i in range(len(fresh)):
        _assert_visual_eq(log.last_visual[i], fresh[i])


def test_text_log_autoscroll_pins_to_bottom_on_append() raises:
    """While ``autoscroll`` is True, new lines arriving must keep the
    last row visible — ``last_first_visual`` shifts as content grows
    so the bottom of the log stays at the bottom of the view."""
    var log = TextLog(default_attr())
    var canvas = Canvas(40, 12)
    var view = Rect(0, 0, 20, 5)
    for i in range(8):
        log.append(String("row ") + String(i))
    log.paint(canvas, view)
    var before = log.last_first_visual
    # Append more lines and re-paint. With autoscroll on, the visible
    # window must slide down so the bottom row is still at the
    # bottom — ``last_first_visual`` increases by exactly the row
    # count we added.
    log.append(String("row 8"))
    log.append(String("row 9"))
    log.paint(canvas, view)
    assert_true(log.autoscroll)
    assert_equal(log.last_first_visual, before + 2)
    # And the actual painted bottom row matches the freshest line.
    assert_equal(canvas.get(0, 4).glyph, String("r"))   # 'row 9'
    assert_equal(canvas.get(4, 4).glyph, String("9"))


def test_text_log_scroll_stays_in_sync_during_autoscroll() raises:
    """``self.scroll`` must track the painted bottom row while
    autoscroll is on. Without this, a wheel-up from the bottom after
    fresh output would warp the view back to a stale row instead of
    nudging one row up from the actually-visible bottom."""
    var log = TextLog(default_attr())
    var canvas = Canvas(40, 12)
    var view = Rect(0, 0, 20, 5)
    for i in range(20):
        log.append(String("line ") + String(i))
    log.paint(canvas, view)
    # 20 visual rows (each line is short, fits in one row); visible=5.
    # Last visible row = 19, first = 15.
    assert_true(log.autoscroll)
    assert_equal(log.scroll, 19)
    assert_equal(log.last_first_visual, 15)
    # Wheel up one row — should disengage autoscroll and shift the
    # window by exactly one row, not jump to row 0.
    log.scroll_by(-1)
    assert_false(log.autoscroll)
    log.paint(canvas, view)
    assert_equal(log.last_first_visual, 14)


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


def test_vt_truecolor_fg_keeps_rgb_and_folds_index() raises:
    """``ESC[38;2;r;g;b m`` must preserve the exact 24-bit RGB on the
    cell's attr (``FG_TRUECOLOR`` set, ``fg_rgb`` = the packed value) so
    truecolor terminals / the native app render it faithfully — while
    still baking the nearest-256 fold into ``fg`` so 256-color terminals
    degrade without extra logic."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[38;2;10;20;30mX"))
    var cell = vt.cell_at(0, 0)
    assert_equal(cell.glyph, String("X"))
    assert_true((cell.attr.color_mode & FG_TRUECOLOR) != 0)
    assert_equal(Int(cell.attr.fg_rgb), 0x0A141E)
    # Degrade path: the palette index is the rgb→256 fold, not raw RGB.
    assert_equal(cell.attr.fg, _rgb_to_256(10, 20, 30))
    # A subsequent indexed color clears the truecolor flag (no stale RGB).
    vt.feed_string(String("\x1b[31mY"))
    var cell2 = vt.cell_at(0, 1)
    assert_true((cell2.attr.color_mode & FG_TRUECOLOR) == 0)
    assert_equal(Int(cell2.attr.fg_rgb), 0)
    assert_equal(cell2.attr.fg, RED)


def test_vt_truecolor_bg_keeps_rgb() raises:
    """``ESC[48;2;r;g;b m`` preserves the background RGB the same way."""
    var vt = Vt(80, 24)
    vt.feed_string(String("\x1b[48;2;200;100;50mZ"))
    var cell = vt.cell_at(0, 0)
    assert_true((cell.attr.color_mode & BG_TRUECOLOR) != 0)
    assert_equal(Int(cell.attr.bg_rgb), 0xC86432)


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


def test_sgr_parse() raises:
    """``parse_sgr`` decodes ANSI color into clean text + ColorRuns — the
    in-direction counterpart to ``attr_to_sgr`` that lets the test/run
    panes colorize ``pytest --color=yes`` output instead of showing raw
    escape bytes."""
    var base = Attr(LIGHT_GRAY, BLACK)
    var esc = String("\x1b")
    # ESC[31m FAIL ESC[0m ok → clean "FAIL ok", one red run over [0,4).
    var parsed = parse_sgr(
        esc + String("[31mFAIL") + esc + String("[0m ok"), base,
    )
    assert_equal(parsed[0], String("FAIL ok"))
    var runs = parsed[1].copy()
    assert_equal(len(runs), 1)
    assert_equal(runs[0].start, 0)
    assert_equal(runs[0].end, 4)
    assert_equal(Int(runs[0].attr.fg), Int(RED))
    # 256-color extended form.
    var p2 = parse_sgr(esc + String("[38;5;208mX"), base)
    assert_equal(p2[0], String("X"))
    var r2 = p2[1].copy()
    assert_equal(len(r2), 1)
    assert_equal(Int(r2[0].attr.fg), 208)
    # Plain text → unchanged, no runs.
    var p3 = parse_sgr(String("plain"), base)
    assert_equal(p3[0], String("plain"))
    assert_equal(len(p3[1]), 0)


def main() raises:
    setup_test_env()
    test_terminal_pane_attention_on_working_to_waiting()
    test_terminal_double_click_selects_word()
    test_terminal_double_click_drag_extends_by_word()
    test_terminal_double_click_drag_backward_by_word()
    test_terminal_triple_click_drag_extends_by_line()
    test_terminal_parses_modified_arrows()
    test_terminal_parses_bare_modifier_transition()
    test_terminal_parses_shift_tab()
    test_terminal_parses_alt_letter_as_letter()
    test_terminal_pane_esc_steps_chrome_ladder_without_claude()
    test_terminal_pane_esc_bypasses_chrome_ladder_in_claude_mode()
    test_sgr_mouse_wheel_up()
    test_sgr_mouse_motion_no_button()
    test_text_log_incremental_layout_matches_full_rewrap()
    test_text_log_incremental_layout_handles_trim()
    test_text_log_full_rewrap_on_width_change()
    test_text_log_streaming_appends_continue_open_line()
    test_text_log_discrete_appends_stay_separate_rows()
    test_text_log_streaming_continuation_keeps_layout_cache()
    test_text_log_autoscroll_pins_to_bottom_on_append()
    test_text_log_scroll_stays_in_sync_during_autoscroll()
    test_vt_da1_reply_on_csi_c()
    test_vt_dsr_6_reply_uses_1_based_cursor()
    test_vt_decset_2004_bracketed_paste_flag()
    test_vt_decset_1_app_cursor_keys()
    test_vt_decset_1004_focus_events_round_trip()
    test_vt_truecolor_fg_keeps_rgb_and_folds_index()
    test_vt_truecolor_bg_keeps_rgb()
    test_vt_osc_52_decodes_base64_to_clipboard()
    test_vt_osc_52_query_does_not_leak_clipboard()
    test_vt_decscusr_tracks_cursor_shape()
    test_vt_ris_clears_mode_flags()
    test_sgr_parse()
    print("panes: 33 tests passed")
