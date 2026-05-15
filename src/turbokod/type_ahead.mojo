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

Two consumption surfaces:

* ``TypeAhead.append`` / ``solo_fallback`` for widgets whose match
  logic needs custom skip rules (DirBrowser, Dropdown), or whose
  options aren't already in a flat ``List[String]``.

* ``type_ahead_pick`` (this module) for widgets that already paint
  one row per ``List[String]`` entry — the common case for Settings
  panes, candidate lists, and any new list widget. One call,
  current-index in / new-index out, no per-site reimplementation
  of the prefix walk.

Standard usage of the helper::

    if is_printable_ascii(event.key) and self.focus == _FOCUS_LIST:
        var hit = type_ahead_pick(
            self._type_ahead, self._row_labels(),
            chr(Int(event.key)),
        )
        if hit >= 0:
            self.selected = hit
        return True

The helper returns ``-1`` on a no-match keystroke so the caller's
selection survives accidental Shift-letter / AltGr presses that
fall through to no row.
"""

from std.collections.list import List

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

    def __init__(out self):
        self.buf = String("")
        self.last_ms = 0

    def __copyinit__(mut self, copy: Self):
        self.buf = copy.buf
        self.last_ms = copy.last_ms

    def reset(mut self):
        """Drop the buffer immediately. Callers invoke this when the
        surrounding context shifts in a way that makes a continued
        prefix nonsensical (popup closed, directory changed)."""
        self.buf = String("")
        self.last_ms = 0

    def append(mut self, ch: String) -> String:
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

    def solo_fallback(mut self, ch: String) -> String:
        """Replace the buffer with just ``ch`` and return it. Used
        for the stale-prefix recovery path: if no entry matched the
        accumulated prefix, retry with a fresh single character."""
        self.buf = ch
        return self.buf


def is_printable_ascii(key: UInt32) -> Bool:
    """True for ``key`` codes a list widget should treat as "user is
    typing a search prefix". Matches the dropdown/dir-browser gate so
    every list widget agrees on what counts as a search keystroke."""
    return UInt32(0x20) <= key and key < UInt32(0x7F)


def _find_prefix_in(options: List[String], prefix: String) -> Int:
    """First index in ``options`` whose entry starts with ``prefix``
    (case-insensitive), or -1 on no match. Empty entries are skipped
    so a stray printable key doesn't snap to the leading sentinel
    rows that some lists prepend (e.g. dropdown's ``""`` "any"
    option)."""
    var pb = prefix.as_bytes()
    if len(pb) == 0:
        return -1
    for i in range(len(options)):
        if len(options[i].as_bytes()) == 0:
            continue
        if starts_with_ci(options[i], prefix):
            return i
    return -1


def type_ahead_pick(
    mut type_ahead: TypeAhead, options: List[String], ch: String,
) -> Int:
    """Append ``ch`` to ``type_ahead`` and return the index of the
    first option whose label starts with the accumulated prefix
    (case-insensitive). On no match, fall back to a solo-letter
    retry — typing a fresh letter after a stale chain still lands
    somewhere useful. Returns ``-1`` if neither attempt matches so
    the caller can preserve its existing selection.

    This is the framework feature: any list widget that owns a
    ``TypeAhead`` field and can produce a ``List[String]`` of its
    visible row labels gets type-to-jump in one call.
    """
    var prefix = type_ahead.append(ch)
    var idx = _find_prefix_in(options, prefix)
    if idx >= 0:
        return idx
    if len(type_ahead.buf.as_bytes()) > 1:
        var solo = type_ahead.solo_fallback(ch)
        return _find_prefix_in(options, solo)
    return -1


def starts_with_ci(name: String, prefix: String) -> Bool:
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
