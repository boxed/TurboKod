"""Is this git command's output the boring one, or is it worth reading?

A completed git operation in the Local-changes view has three possible
fates, and this module decides which:

* **Routine success** — every line of the output is one git always prints
  when nothing interesting happened (``To github.com:…`` /
  ``abc1234..def5678  main -> main`` / ``Fast-forward`` / a diffstat).
  The panels have already refreshed to show the result, so the right UI
  is *nothing*: the spinner closes and the user carries on.
* **Something else** — a ``pre-push`` hook talking, a Dokku or Heroku
  remote streaming a whole deploy log back over ``remote:``, a merge
  narrating a rename detection. The user wants to read that, so it goes
  full screen.
* **Failure** — decided by the exit code, not here.

The test is deliberately "**every** line matched an expected pattern",
not "some line looked alarming". Enumerating what boring looks like is a
closed problem — git's own success messages are a finite, stable set —
whereas enumerating what interesting looks like is open-ended and would
mean guessing at every build tool anyone might have on the far end of a
push. Getting it wrong in this direction shows output the user didn't
need; getting it wrong in the other hides a deploy failure behind a
spinner that quietly vanished.

The one genuinely hard case is ``remote:``. It carries both Dokku's build
log *and* GitHub's "Create a pull request" hint, so the prefix alone
decides nothing — the benign forge hints are enumerated line by line in
``_forge_hint_patterns`` and anything else a remote says is treated as
worth showing.
"""

from std.collections.list import List

from .onig import OnigRegex


# Output shapes. These name git *subcommands*, not the caller's
# operations — ``local_changes`` maps its ``_GITOP_*`` values onto these,
# so the two enums stay independent.
comptime GIT_OUT_OTHER: Int = 0
comptime GIT_OUT_COMMIT: Int = 1
comptime GIT_OUT_PUSH: Int = 2
comptime GIT_OUT_PULL: Int = 3
comptime GIT_OUT_CHECKOUT: Int = 4
comptime GIT_OUT_MERGE: Int = 5
comptime GIT_OUT_BRANCH_DELETE: Int = 6
comptime GIT_OUT_RESTORE: Int = 7
comptime GIT_OUT_REBASE: Int = 8


def _transport_patterns() -> List[String]:
    """Progress and ref-update chatter shared by push / pull / fetch."""
    var p = List[String]()
    p.append(String("^To [^ ]+$"))
    p.append(String("^From [^ ]+$"))
    p.append(String("^Enumerating objects: .*$"))
    p.append(String("^Counting objects: .*$"))
    p.append(String("^Delta compression uses up to .*$"))
    p.append(String("^Compressing objects: .*$"))
    p.append(String("^Writing objects: .*$"))
    p.append(String("^Receiving objects: .*$"))
    p.append(String("^Resolving deltas: .*$"))
    p.append(String("^Unpacking objects: .*$"))
    p.append(String("^Total [0-9]+ .*$"))
    p.append(String("^Everything up-to-date$"))
    p.append(String("^Already up[ -]to[ -]date\\.$"))
    # Ref updates, as printed in the summary block. The spacing around
    # ``->`` has to stay loose: push prints ``main -> main``, but fetch
    # pads the local-ref column out to a fixed width, so the same update
    # arrives as ``main       -> origin/main``.
    p.append(String("^ *[0-9a-f]+\\.\\.[0-9a-f]+ +\\S+ +-> +\\S+$"))
    p.append(String(
        "^ *\\+ [0-9a-f]+\\.\\.\\.[0-9a-f]+ +\\S+ +-> +\\S+ +"
        "\\(forced update\\)$"
    ))
    p.append(String("^ *\\* \\[new branch\\] +\\S+ +-> +\\S+$"))
    p.append(String("^ *\\* \\[new tag\\] +\\S+ +-> +\\S+$"))
    p.append(String("^ *- \\[deleted\\] +.*-> +\\S+$"))
    p.append(String("^ *\\* branch +\\S+ +-> FETCH_HEAD$"))
    p.append(String("^branch '.*' set up to track .*$"))
    return p^


def _forge_hint_patterns() -> List[String]:
    """The ``remote:`` lines an ordinary forge push prints — progress
    echoed back, and the "open a pull request" nudge GitHub / GitLab add
    when you push a new branch.

    Enumerated rather than allowing ``remote:`` wholesale, because that
    prefix is also how a Dokku / Heroku remote streams a deploy log, and
    the deploy log is the thing we exist to show."""
    var p = List[String]()
    p.append(String("^remote: *$"))
    p.append(String("^remote: Enumerating objects: .*$"))
    p.append(String("^remote: Counting objects: .*$"))
    p.append(String("^remote: Compressing objects: .*$"))
    p.append(String("^remote: Resolving deltas: .*$"))
    p.append(String("^remote: Total [0-9]+ .*$"))
    p.append(String("^remote: Create a pull request for .* by visiting:$"))
    p.append(String("^remote: To create a merge request for .*, visit:$"))
    p.append(String("^remote: View merge request for .*:$"))
    p.append(String("^remote: *https?://\\S+$"))
    return p^


def _diffstat_patterns() -> List[String]:
    """``--stat`` output: the per-file bar chart plus the summary and
    mode-change lines. Printed by commit, merge, and pull."""
    var p = List[String]()
    p.append(String("^ *[0-9]+ files? changed.*$"))
    p.append(String("^ .* \\| +[0-9]+ [+-]*$"))
    p.append(String("^ .* \\| +Bin .*$"))
    p.append(String("^ .* \\| +[0-9]+ [+-]* *$"))
    p.append(String("^ create mode [0-7]+ .*$"))
    p.append(String("^ delete mode [0-7]+ .*$"))
    p.append(String("^ mode change [0-7]+ => [0-7]+ .*$"))
    p.append(String("^ rename .* \\([0-9]+%\\)$"))
    p.append(String("^ copy .* \\([0-9]+%\\)$"))
    return p^


def _autostash_patterns() -> List[String]:
    """The two lines ``--autostash`` adds around an operation that had to
    park dirty worktree changes for the duration. Both narrate a stash
    that has already been put back, so a pull that autostashed is just a
    pull that succeeded.

    ``Applied autostash.`` carries the rebase progress-redraw prefix
    because rebase prints it *into* the redraw line with no newline
    first — what actually arrives is one line reading
    ``Rebasing (1/3)\\rRebasing (2/3)\\rApplied autostash.``

    The failure wording (``Applying autostash resulted in conflicts.``)
    deliberately isn't here: that's the one autostash outcome where the
    user's changes are still sitting in the stash and they have to act."""
    var p = List[String]()
    p.append(String("^Created autostash: [0-9a-f]+$"))
    p.append(String(
        "^(?:Rebasing \\([0-9]+/[0-9]+\\)\\r)*Applied autostash\\.$"
    ))
    return p^


def _rebase_patterns() -> List[String]:
    """A rebase that ran to completion. Shared with pull, because
    ``pull.rebase`` makes these a plain pull's output."""
    var p = List[String]()
    # A successful rebase redraws its progress counter with ``\r`` and
    # then prints the verdict *on the same line*, so what arrives is
    # one line of "Rebasing (1/3)\rRebasing (2/3)\r…Successfully
    # rebased…". ``is_routine`` splits on ``\n`` only, so the pattern
    # has to swallow the whole redraw train rather than expecting the
    # verdict at the start of a line.
    p.append(String(
        "^(?:Rebasing \\([0-9]+/[0-9]+\\)\\r)*"
        "Successfully rebased and updated \\S+\\.$"
    ))
    # Progress that lands in its own chunk (a rebase slow enough that
    # we classify mid-flight, before the verdict arrives).
    p.append(String("^(?:Rebasing \\([0-9]+/[0-9]+\\)\\r?)+$"))
    p.append(String("^Current branch .* is up to date\\.$"))
    # The ``am``-backend wording, still what older git prints.
    p.append(String(
        "^First, rewinding head to replay your work on top of it\\.\\.\\.$"
    ))
    p.append(String("^Applying: .*$"))
    return p^


def _branch_state_patterns() -> List[String]:
    """The "where does this branch stand" block git prints after a
    checkout, and the parenthesised hint that follows it."""
    var p = List[String]()
    p.append(String("^Your branch is up to date with '.*'\\.$"))
    p.append(String("^Your branch is ahead of '.*' by [0-9]+ commits?\\.$"))
    p.append(String("^Your branch is behind '.*' by [0-9]+ commits?.*$"))
    p.append(String("^Your branch and '.*' have diverged,$"))
    p.append(String(
        "^and have [0-9]+ and [0-9]+ different commits each, respectively\\.$"
    ))
    p.append(String("^ *\\(use \"git .*\"\\)$"))
    return p^


def routine_patterns(kind: Int) -> List[String]:
    """Every line pattern that counts as "nothing to see here" for
    ``kind``. An empty list means nothing is routine, so all output shows
    — which is what ``GIT_OUT_OTHER`` deliberately gets."""
    var p = List[String]()
    if kind == GIT_OUT_COMMIT:
        # "[main 3fdfe00] subject" — also covers "[detached HEAD abc1234]".
        p.append(String("^\\[[^]]+ [0-9a-f]+\\] .*$"))
        for x in _diffstat_patterns():
            p.append(x)
    elif kind == GIT_OUT_PUSH:
        for x in _transport_patterns():
            p.append(x)
        for x in _forge_hint_patterns():
            p.append(x)
    elif kind == GIT_OUT_PULL:
        for x in _transport_patterns():
            p.append(x)
        for x in _forge_hint_patterns():
            p.append(x)
        for x in _diffstat_patterns():
            p.append(x)
        # A pull is a fetch plus whichever integration the repo is
        # configured for, so the rebase verdicts are pull output too.
        for x in _rebase_patterns():
            p.append(x)
        for x in _autostash_patterns():
            p.append(x)
        p.append(String("^Updating [0-9a-f]+\\.\\.[0-9a-f]+$"))
        p.append(String("^Fast-forward$"))
        p.append(String("^Merge made by the '.*' strategy\\.$"))
    elif kind == GIT_OUT_CHECKOUT:
        p.append(String("^Switched to branch '.*'$"))
        p.append(String("^Switched to a new branch '.*'$"))
        p.append(String("^Already on '.*'$"))
        # Local modifications carried across the switch.
        p.append(String("^[MADRCU]\t.*$"))
        for x in _branch_state_patterns():
            p.append(x)
    elif kind == GIT_OUT_MERGE:
        p.append(String("^Updating [0-9a-f]+\\.\\.[0-9a-f]+$"))
        p.append(String("^Fast-forward$"))
        p.append(String("^Merge made by the '.*' strategy\\.$"))
        p.append(String("^Already up[ -]to[ -]date\\.$"))
        for x in _diffstat_patterns():
            p.append(x)
        for x in _autostash_patterns():
            p.append(x)
    elif kind == GIT_OUT_REBASE:
        for x in _rebase_patterns():
            p.append(x)
        for x in _autostash_patterns():
            p.append(x)
    elif kind == GIT_OUT_BRANCH_DELETE:
        p.append(String("^Deleted branch .* \\(was [0-9a-f]+\\)\\.$"))
    elif kind == GIT_OUT_RESTORE:
        p.append(String("^Removing .*$"))
        p.append(String("^Updated [0-9]+ paths? from .*$"))
    return p^


def complete_lines(output: String) -> String:
    """``output`` truncated at its last newline.

    Used when classifying a *live* capture: the final line is probably
    half-read, and half a line can fail to match a pattern it would have
    matched a moment later. Trailing-newline-only input comes back
    unchanged."""
    var b = output.as_bytes()
    var i = len(b)
    while i > 0:
        if b[i - 1] == 0x0A:
            return String(StringSpan(unsafe_from_utf8=b[0:i]))
        i -= 1
    return String("")


struct GitOutputMatcher(Movable):
    """Compiled ``routine_patterns`` for one output kind.

    Built once per kind and kept for the session by ``GitOutputMatchers``,
    not per classification: the live path re-checks on every frame that
    the capture grows, and recompiling thirty regexes per frame to answer
    "still boring?" would be silly.

    A pattern libonig refuses to compile is dropped rather than fatal —
    the cost is that one shape of boring output stops being recognized
    and the user sees a log they didn't need, which is the safe way to be
    wrong here."""

    var regexes: List[OnigRegex]

    def __init__(out self, kind: Int):
        self.regexes = List[OnigRegex]()
        var pats = routine_patterns(kind)
        for i in range(len(pats)):
            try:
                self.regexes.append(OnigRegex(pats[i]))
            except:
                continue

    def __init__(out self):
        """Matcher that recognizes nothing — every output is worth
        showing. The state an idle ``LocalChanges`` holds."""
        self.regexes = List[OnigRegex]()

    def release(mut self):
        """Free this kind's compiled patterns. Teardown only — nothing
        may call ``is_routine`` afterwards."""
        for i in range(len(self.regexes)):
            self.regexes[i].release()
        self.regexes = List[OnigRegex]()

    def is_routine(self, output: String) -> Bool:
        """True when every non-blank line of ``output`` matches one of the
        compiled patterns. Empty output is routine (git said nothing, so
        there is nothing to read)."""
        if len(self.regexes) == 0:
            return len(_trimmed(output).as_bytes()) == 0
        var b = output.as_bytes()
        var start = 0
        var i = 0
        while i <= len(b):
            var at_end = i == len(b)
            if at_end or b[i] == 0x0A:
                if i > start:
                    var line = String(StringSpan(
                        unsafe_from_utf8=b[start:i],
                    ))
                    if not self._line_is_routine(line):
                        return False
                start = i + 1
            if at_end:
                break
            i += 1
        return True

    def _line_is_routine(self, line: String) -> Bool:
        var trimmed = _trimmed(line)
        if len(trimmed.as_bytes()) == 0:
            return True
        for r in range(len(self.regexes)):
            var m = self.regexes[r].search(line)
            if m and m.value().start >= 0:
                return True
        return False


struct GitOutputMatchers(Movable):
    """One ``GitOutputMatcher`` per output kind, compiled on first use and
    kept for the rest of the session.

    The owner (``LocalChanges``) holds one of these and names a *kind*
    per operation instead of building a matcher per operation. That's not
    just about avoiding ~15 regex compiles per ``git push``: an
    ``OnigRegex`` never frees its libonig handles (see the ``OnigRegex``
    doc comment), so a matcher per operation leaked ~25 KB on every
    commit, push, pull, checkout, merge and rebase, for the life of the
    process. Compiling once per kind bounds it at ~200 KB total.

    Storage is parallel ``kinds`` / ``matchers`` arrays — there are nine
    kinds, so a linear scan is the whole lookup.
    """

    var kinds: List[Int]
    var matchers: List[GitOutputMatcher]

    def __init__(out self):
        self.kinds = List[Int]()
        self.matchers = List[GitOutputMatcher]()

    def is_routine(mut self, kind: Int, output: String) -> Bool:
        """``GitOutputMatcher.is_routine`` for ``kind``, compiling that
        kind's patterns if this is their first use."""
        var idx = self._ensure(kind)
        return self.matchers[idx].is_routine(output)

    def _ensure(mut self, kind: Int) -> Int:
        for i in range(len(self.kinds)):
            if self.kinds[i] == kind:
                return i
        self.kinds.append(kind)
        self.matchers.append(GitOutputMatcher(kind))
        return len(self.kinds) - 1

    def release(mut self):
        """Free every compiled kind and empty the table.

        One of these lives per window (on ``LocalChanges``), and its ~200 KB
        of handles isn't reachable from the ``GrammarRegistry``, so window
        teardown has to release it separately. Idempotent; a later
        ``is_routine`` recompiles the kind it needs."""
        for i in range(len(self.matchers)):
            self.matchers[i].release()
        self.kinds = List[Int]()
        self.matchers = List[GitOutputMatcher]()


def _trimmed(s: String) -> String:
    """``s`` without leading/trailing ASCII whitespace (including ``\\r``,
    which git emits when it redraws a progress line)."""
    var b = s.as_bytes()
    var start = 0
    var end = len(b)
    while start < end and (b[start] == 0x20 or b[start] == 0x09
            or b[start] == 0x0D or b[start] == 0x0A):
        start += 1
    while end > start and (b[end - 1] == 0x20 or b[end - 1] == 0x09
            or b[end - 1] == 0x0D or b[end - 1] == 0x0A):
        end -= 1
    if start >= end:
        return String("")
    return String(StringSpan(unsafe_from_utf8=b[start:end]))
