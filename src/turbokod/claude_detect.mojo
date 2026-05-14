"""Claude Code mode detector.

Examines the tail of a terminal's output buffer for visible Claude Code
UI markers and returns a coarse state — clean (welcome screen / freshly
cleared, the mascot is visible), waiting (idle prompt awaiting input),
working (spinner visible), active (Claude is running but no precise
marker matched), or none (Claude Code not detected at all).

The detector is intentionally a tail-only string scan: we look at the
last ~12 lines and OR together substring matches. False positives are
cheap (a wrong label on the title bar that the user can ignore); false
negatives are cheap (we fall back to the static label). The signals are
deliberately Claude-Code-specific phrases that don't appear in normal
shell output:

* ``esc to interrupt`` — printed next to the working spinner.
* ``Welcome to Claude Code`` / ``/help for help`` — the welcome banner
  shown on startup and after ``/clear`` (the "mascot" state).
* ``? for shortcuts`` / ``shift+tab to`` — the idle prompt hint strip.

When Claude is running but none of the precise markers match (mid-
conversation, between turns), we fall back to ``CLAUDE_ACTIVE`` so the
title bar still reflects that Claude is present.
"""

from std.collections.list import List


comptime CLAUDE_NONE    = UInt8(0)
"""Claude Code is not detected in the visible output."""

comptime CLAUDE_CLEAN   = UInt8(1)
"""Welcome screen / freshly cleared — the mascot is the dominant
visual element. Matches the banner printed on startup and after
``/clear``."""

comptime CLAUDE_WAITING = UInt8(2)
"""Idle prompt visible, awaiting the next user message. Matches the
shortcut hint strip painted below the input box."""

comptime CLAUDE_WORKING = UInt8(3)
"""Spinner visible — Claude is actively processing. Matches the
``esc to interrupt`` text printed next to the spinner."""

comptime CLAUDE_ACTIVE  = UInt8(4)
"""Claude Code is running but no precise state marker is in the tail.
Used when only generic Claude markers match (e.g. a stray brand glyph
in scrollback)."""


comptime _TAIL_LINES = 12
"""How many lines from the end of the buffer to scan. The user asked
for ~10; we use 12 to give a little margin so a single intervening
status line doesn't push the marker out of view between drains."""


fn detect_claude_state(lines: List[String]) -> UInt8:
    """Classify the visible Claude Code state from the last few lines.

    Priority when multiple markers match in the same tail: working >
    clean > waiting > active. Working wins because the spinner is the
    most time-sensitive signal and is briefly visible alongside the
    prompt right after the user submits. Clean wins over waiting
    because the welcome banner is paired with an empty prompt — both
    matchers would fire, but the user thinks of that state as ``clean``,
    not ``waiting``.

    Matching is case-insensitive (Claude's labels have shifted between
    ``esc`` / ``Esc`` / ``ESC`` across versions) and we test each row
    individually AND the rows concatenated without separators. The
    concatenated pass catches markers that have been split across two
    grid rows by terminal wrapping — a narrow pane wraps
    ``(esc to interrupt · ctrl+t to show todos)`` across lines and the
    per-row scan would miss it.
    """
    var n = len(lines)
    if n == 0:
        return CLAUDE_NONE
    var start = n - _TAIL_LINES
    if start < 0:
        start = 0

    # Build a lower-cased view of the tail rows once. Both the per-row
    # and the concatenated-rows checks read from this.
    var rows_lc = List[String]()
    for i in range(start, n):
        rows_lc.append(_to_lower(lines[i]))
    var joined_bytes = List[UInt8]()
    for i in range(len(rows_lc)):
        var rb = rows_lc[i].as_bytes()
        for k in range(len(rb)):
            joined_bytes.append(rb[k])
    var joined = String(StringSlice(
        ptr=joined_bytes.unsafe_ptr(), length=len(joined_bytes),
    ))

    var has_working_marker  = False
    var has_clean_marker    = False
    var has_waiting_marker  = False
    var has_generic_marker  = False

    # --- working ------------------------------------------------------
    # ``esc to interrupt`` is the spinner-row companion text. Claude
    # Code paints something like ``✻ Synthesizing… (5s · esc to
    # interrupt · ctrl+t to show todos)`` — the parenthesized substring
    # is stable across spinner verbs and time updates. ``ctrl+t to show
    # todos`` is a second working-only marker on the same row so the
    # pane still detects working if the ``esc to`` half wrapped onto
    # the previous line.
    if _any_contains(rows_lc, joined, String("esc to interrupt")):
        has_working_marker = True
        has_generic_marker = True
    if _any_contains(rows_lc, joined, String("ctrl+t to show todos")):
        has_working_marker = True
        has_generic_marker = True
    if _any_contains(rows_lc, joined, String("to interrupt)")):
        has_working_marker = True
        has_generic_marker = True
    # --- clean / welcome ----------------------------------------------
    if _any_contains(rows_lc, joined, String("welcome to claude code")):
        has_clean_marker = True
        has_generic_marker = True
    # ``/help for help`` is on the second welcome row; a separate match
    # catches the case where the first row scrolled past but the help
    # hint is still visible.
    if _any_contains(rows_lc, joined, String("/help for help")):
        has_clean_marker = True
        has_generic_marker = True
    # --- waiting ------------------------------------------------------
    # The shortcut strip below the idle prompt. The exact wording has
    # churned (``? for shortcuts``, ``shift+tab to cycle``, ``bypass
    # permissions``); we match the most stable fragments.
    if _any_contains(rows_lc, joined, String("? for shortcuts")):
        has_waiting_marker = True
        has_generic_marker = True
    if _any_contains(rows_lc, joined, String("shift+tab to")):
        has_waiting_marker = True
        has_generic_marker = True
    # --- generic Claude marker ----------------------------------------
    # The brand glyph (``✻``) appears on the welcome banner, on the
    # spinner row, and as a bullet on Claude's reply lines. On its own
    # it doesn't tell us *which* state we're in, but it does tell us
    # Claude is somewhere on screen — enough to label the title bar as
    # ``active`` if no precise marker matches.
    if _any_contains(rows_lc, joined, String("✻")):
        has_generic_marker = True

    if has_working_marker:
        return CLAUDE_WORKING
    if has_clean_marker:
        return CLAUDE_CLEAN
    if has_waiting_marker:
        return CLAUDE_WAITING
    if has_generic_marker:
        return CLAUDE_ACTIVE
    return CLAUDE_NONE


fn claude_state_label(state: UInt8) -> String:
    """Short human-readable label for the title bar. Empty string when
    no Claude state is detected so callers can paint a different
    fallback title without branching on the enum themselves."""
    if state == CLAUDE_WORKING:
        return String("working")
    if state == CLAUDE_WAITING:
        return String("waiting")
    if state == CLAUDE_CLEAN:
        return String("clean")
    if state == CLAUDE_ACTIVE:
        return String("active")
    return String("")


# --- helpers --------------------------------------------------------------


fn _contains(haystack: String, needle: String) -> Bool:
    """Byte-level substring search. The lines we scan may have ANSI
    color escapes embedded around (but not inside) the marker strings
    we look for, so a plain byte search is sufficient and avoids the
    cost of stripping escapes."""
    var h = haystack.as_bytes()
    var nd = needle.as_bytes()
    var hl = len(h)
    var nl = len(nd)
    if nl == 0:
        return True
    if nl > hl:
        return False
    var limit = hl - nl + 1
    for i in range(limit):
        var matched = True
        for j in range(nl):
            if h[i + j] != nd[j]:
                matched = False
                break
        if matched:
            return True
    return False


fn _any_contains(rows_lc: List[String], joined: String, needle_lc: String) -> Bool:
    """True if ``needle_lc`` is in any individual row or in the
    concatenation of all rows. Caller passes the lowercased needle and
    the prepared lowercased haystacks so we don't redo that work per
    marker. The joined check catches markers that wrapped across rows
    in a narrow pane."""
    for i in range(len(rows_lc)):
        if _contains(rows_lc[i], needle_lc):
            return True
    return _contains(joined, needle_lc)


fn _to_lower(s: String) -> String:
    """ASCII-only lowercase. Claude Code's marker strings are all
    plain ASCII (``esc to interrupt``, ``? for shortcuts``, etc.), so
    a byte-level uppercase→lowercase mapping is sufficient; multibyte
    sequences (the brand glyph, middle dots) pass through unchanged.
    Used so the detector matches across ``esc`` / ``Esc`` / ``ESC``
    variants without maintaining a per-marker alternate list."""
    var src = s.as_bytes()
    var n = len(src)
    var out = List[UInt8]()
    out.reserve(n)
    for i in range(n):
        var b = src[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            out.append(b + UInt8(0x20))
        else:
            out.append(b)
    return String(StringSlice(
        ptr=out.unsafe_ptr(), length=n,
    ))
