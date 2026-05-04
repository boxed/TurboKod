"""Shared type-to-search buffer for list-style widgets.

A user typing letters into a focused list (file dialog's directory
listing, the language dropdown's popup, …) expects the highlight to
jump to the first matching entry. The mechanics are the same in every
case:

1. Accumulate consecutive keystrokes into a prefix buffer.
2. After a pause (default 800 ms), discard the buffer and start over.
3. On no match for the accumulated prefix, retry with just the latest
   keystroke — typing a letter after a stale chain should land
   somewhere useful instead of feeling like a dead key.

Each consumer brings its own match-and-select logic (file lists skip
``..``, dropdowns skip the empty ``(none)`` sentinel, etc.), so the
shared piece is just the buffer and the case-insensitive prefix test.

Standard usage::

    var prefix = self.type_ahead.append(ch)
    if try_select(prefix):
        return True
    if len(prefix.as_bytes()) > 1:
        var solo = self.type_ahead.solo_fallback(ch)
        if try_select(solo):
            return True
    return False
"""

from .posix import monotonic_ms


# Pause longer than this between keystrokes resets the prefix buffer
# on the next ``append``. 800 ms is the threshold ``DirBrowser``
# shipped with — kept the same so the muscle memory transfers across
# widgets.
comptime _SEARCH_RESET_MS: Int = 800


struct TypeAhead(ImplicitlyCopyable, Movable):
    """Accumulated prefix + last-keystroke timestamp.

    ``buf`` is the public read-state (some callers display it as a
    HUD overlay). ``last_ms`` is internal — only ``append`` reads it.
    """
    var buf: String
    var last_ms: Int

    fn __init__(out self):
        self.buf = String("")
        self.last_ms = 0

    fn __copyinit__(out self, copy: Self):
        self.buf = copy.buf
        self.last_ms = copy.last_ms

    fn reset(mut self):
        """Drop the buffer immediately. Callers invoke this when the
        surrounding context shifts in a way that makes a continued
        prefix nonsensical (popup closed, directory changed)."""
        self.buf = String("")
        self.last_ms = 0

    fn append(mut self, ch: String) -> String:
        """Extend the buffer with ``ch`` (after the timeout reset)
        and return the current accumulated prefix. The returned value
        is a copy — callers can safely store it without sharing storage
        with ``self.buf``."""
        var now = monotonic_ms()
        if now - self.last_ms > _SEARCH_RESET_MS:
            self.buf = String("")
        self.last_ms = now
        self.buf = self.buf + ch
        return self.buf

    fn solo_fallback(mut self, ch: String) -> String:
        """Replace the buffer with just ``ch`` and return it. Used
        for the stale-prefix recovery path: if no entry matched the
        accumulated prefix, retry with a fresh single character."""
        self.buf = ch
        return self.buf


fn starts_with_ci(name: String, prefix: String) -> Bool:
    """ASCII-case-insensitive prefix test. UTF-8 case folding is
    non-trivial; restricting to ASCII keeps the comparison cheap and
    matches the way the rest of this codebase already sorts/compares
    names (see ``_sort_entries_ci`` in ``file_io``)."""
    var nb = name.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(nb):
        return False
    for i in range(len(pb)):
        var cn = Int(nb[i])
        var cp = Int(pb[i])
        if 0x41 <= cn and cn <= 0x5A:
            cn += 0x20
        if 0x41 <= cp and cp <= 0x5A:
            cp += 0x20
        if cn != cp:
            return False
    return True
