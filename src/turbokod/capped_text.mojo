"""A text capture with a byte cap and an explicit rule for what it keeps.

Language servers and debug adapters can write without end to stderr and
their log channels, and the info windows show what they wrote. Each capture
used to carry its own cap with its own rule (one kept the head, one dropped
whole chunks past the cap, one overshot by a line); this is the one rule:

* ``keep_tail=False`` keeps the *start*: once full, further text is dropped
  (a server's first lines say why it failed to come up). The last piece in
  is cut at a codepoint boundary so the capture never exceeds the cap.
* ``keep_tail=True`` keeps the *end*: the oldest text goes (an adapter's
  last lines say why a session died).

Callers check ``full()`` before formatting what they would append, so a
capped capture costs nothing per message.
"""

from .string_utils import utf8_prefix, utf8_suffix


struct CappedText(Copyable, Movable):
    var text: String
    var cap: Int
    var keep_tail: Bool
    # Head-keeping and something was cut: full even if the cut, on a
    # codepoint boundary, left a few bytes of room.
    var _cut: Bool

    def __init__(out self, cap: Int, keep_tail: Bool):
        self.text = String("")
        self.cap = cap
        self.keep_tail = keep_tail
        self._cut = False

    def full(self) -> Bool:
        """True when appending would add nothing (head-keeping and at the
        cap). A tail-keeping capture is never full."""
        return not self.keep_tail and (
            self._cut or len(self.text.as_bytes()) >= self.cap
        )

    def append(mut self, s: String):
        var n = len(s.as_bytes())
        if n == 0:
            return
        if self.keep_tail:
            self.text += s
            if len(self.text.as_bytes()) > self.cap:
                # Built before the assignment: the suffix borrows ``text``.
                var tail = utf8_suffix(self.text, self.cap)
                self.text = tail^
            return
        if self.full():
            return
        var room = self.cap - len(self.text.as_bytes())
        if n <= room:
            self.text += s
        else:
            self.text += utf8_prefix(s, room)
            self._cut = True

    def append_line(mut self, s: String):
        """``s`` plus a newline."""
        self.append(s + String("\n"))

    def clear(mut self):
        self.text = String("")
        self._cut = False
