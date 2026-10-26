"""The status bar's git summary (branch, dirty, unpushed), polled without
blocking the UI thread.

This used to be three synchronous spawns per window every two seconds —
``git status``, ``git rev-list --count @{upstream}..HEAD`` and ``git
rev-parse --abbrev-ref HEAD`` — run from inside ``Desktop.paint``. That
was ~30 ms of frozen main thread per window per poll on a small repo
(far more with a big untracked tree), and every window that had been
idle polled in the same frame the app came back to the front.

Now it's one ``git status --porcelain=v2 --branch`` child, read across
frames through ``LineStream``. Its ``# branch.*`` headers carry everything
the other two commands answered: ``branch.head`` is the branch name (or
``(detached)``), ``branch.oid`` the commit, and ``branch.ab +A -B`` the
ahead/behind counts — present only when an upstream is configured, which
is exactly the case ``rev-list`` failed on before.
"""

from std.collections.list import List
from std.collections.optional import Optional

from .git_changes import _git_argv
from .line_stream import LineStream
from .string_utils import byte_slice


@fieldwise_init
struct GitStatusSummary(ImplicitlyCopyable, Movable):
    var dirty: Bool
    """Anything to commit: staged, unstaged or untracked."""
    var unpushed: Int
    """Commits ahead of upstream; 0 with no upstream configured."""
    var branch: String
    """Branch name, ``(<short sha>)`` when detached, empty when unknown."""


struct GitStatusParser(Movable):
    """Accumulates ``git status --porcelain=v2 --branch`` lines. Headers
    come first, so the first entry line settles ``dirty`` and nothing
    after it can change the summary."""

    var head: String
    var oid: String
    var ahead: Int
    var dirty: Bool

    def __init__(out self):
        self.head = String("")
        self.oid = String("")
        self.ahead = 0
        self.dirty = False

    def feed(mut self, line: String):
        var b = line.as_bytes()
        if len(b) == 0:
            return
        if b[0] != 0x23:   # '#': anything else is a changed/untracked entry
            self.dirty = True
            return
        if line.startswith("# branch.head "):
            self.head = byte_slice(line, 14, len(b))
        elif line.startswith("# branch.oid "):
            self.oid = byte_slice(line, 13, len(b))
        elif line.startswith("# branch.ab +"):
            # ``# branch.ab +<ahead> -<behind>``
            var rest = byte_slice(line, 13, len(b))
            var sp = rest.find(" ")
            var num = byte_slice(rest, 0, sp) if sp >= 0 else rest
            try:
                self.ahead = Int(num)
            except:
                self.ahead = 0

    def summary(self) -> GitStatusSummary:
        var branch = self.head
        if branch == String("(detached)"):
            # Same rendering ``current_branch_name`` used: the short sha in
            # parentheses, since a detached HEAD has no name to show.
            var ob = self.oid.as_bytes()
            if len(ob) >= 7 and self.oid != String("(initial)"):
                branch = String("(") + byte_slice(self.oid, 0, 7) + String(")")
            else:
                branch = String("")
        return GitStatusSummary(self.dirty, self.ahead, branch^)


struct GitStatusPoller(Movable):
    """One in-flight ``git status`` at a time. ``start`` it on the poll
    cadence, ``tick`` it every frame; the summary comes back once."""

    var stream: LineStream
    var parser: GitStatusParser

    def __init__(out self):
        self.stream = LineStream()
        self.parser = GitStatusParser()

    def is_active(self) -> Bool:
        return self.stream.is_active()

    def start(mut self, root: String) -> Bool:
        """Spawn the status child for ``root``, cancelling any in flight.
        False when the spawn failed (git not on PATH)."""
        self.cancel()
        var args = List[String]()
        args.append(String("status"))
        args.append(String("--porcelain=v2"))
        args.append(String("--branch"))
        # Default untracked mode: a wholly untracked directory is one row
        # rather than one per file. We only need to know whether there is
        # *any* row, and ``-uall`` walks the whole untracked tree to list it.
        return self.stream.start(_git_argv(root, args^))

    def cancel(mut self):
        """Stop the child (SIGTERM + reap + pipe close). Idempotent."""
        self.stream.cancel()
        self.parser = GitStatusParser()

    def tick(mut self) -> Optional[GitStatusSummary]:
        """Read what's available. Returns the summary on the tick it's
        settled — EOF, or the first entry line (the headers are done by
        then, and the rest of a long listing can't change the answer, so
        the child is stopped rather than drained)."""
        if not self.stream.is_active():
            return None
        var got = self.stream.tick()
        for line in got[0]:
            self.parser.feed(line)
            if self.parser.dirty:
                break
        if not self.parser.dirty and not got[1]:
            return None
        var out = self.parser.summary()
        self.cancel()
        return out
