"""Spell checker.

Loads a wordlist (the bundled SCOWL English list plus, on macOS,
``/usr/share/dict/words``; common Linux paths otherwise) into a
hash-bucketed set keyed by lowercase word. Lookup is case-insensitive
and strips a few common suffixes (``'s``, ``s``, ``es``, ``ed``,
``ing``) so plurals and conjugations don't trigger false positives even
when only the base form is in the dictionary.

Checking is plain text processing, independent of syntax highlighting:
``find_misspelled_runs`` splits any text into words — identifiers
included, at underscores, digits and camelCase boundaries — so the
editor's squiggles and Project ▸ Spelling apply the same rules to
every file type. See ``find_misspelled_runs`` for the word rules.
"""

from std.collections.list import List

from .dictionary_install import user_dictionaries_root
from .file_io import (
    join_path, list_directory, make_parent_dirs, read_file, stat_file,
    write_file,
)
from .posix import debug_log, user_config_path
from .string_utils import (
    append_utf8,
    byte_slice, codepoint_at, is_ascii_digit, is_ascii_ident_byte,
    is_word_codepoint, split_lines_no_trailing, word_char_step,
)


# 8192 buckets keyed by FNV-1a low bits. Bucketing keeps lookup at
# O(bucket_size) ≈ 45 string compares for the ~350k words loaded on
# macOS (OS list + bundled SCOWL English + programmer lists), without
# pulling in a real hash map. Lookup is the dominant cost so it's
# worth the extra List headers.
comptime _N_BUCKETS = UInt32(8192)


def user_dict_path() -> String:
    """``~/.config/turbokod/dictionary.txt``, or ``""`` when ``$HOME``
    is unset. One word per line; appended whenever the user picks
    "Add to user dictionary" on a misspelled word."""
    return user_config_path(String("dictionary.txt"))


def project_dict_path(project_root: String) -> String:
    """``<project>/.turbokod/dictionary.txt``, or ``""`` when no project
    is open. Sits beside ``targets.json`` (and the ``per_user/`` subtree
    that holds per-developer session/view/breakpoint state) so it gets
    picked up by the same ``.turbokod/`` directory the user already has
    in version control (or .gitignore)."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    return project_root + String("/.turbokod/dictionary.txt")


@fieldwise_init
struct SpellActionRequest(ImplicitlyCopyable, Movable):
    """Payload emitted by the editor when the user hits Alt+Enter on a
    misspelled word. Hosts can poll
    ``Editor.consume_spell_action_request()`` and use the row/col
    range to anchor a popup, the word to drive ``Speller.add_*``."""
    var row: Int
    var col_start: Int
    var col_end: Int
    var word: String


def _append_to_file(path: String, line: String) -> Bool:
    """Append ``line + \\n`` to ``path``, creating it (and any missing
    parent directories) if needed. Read-modify-write rather than
    ``O_APPEND`` because the rest of the codebase only knows how to
    truncate-write (``creat`` + ``write_bytes``); the dictionary file
    stays small enough that this is a non-issue.

    Returns False on write failure or empty path."""
    if len(path.as_bytes()) == 0:
        return False
    make_parent_dirs(path)
    var existing = String("")
    var info = stat_file(path)
    if info.ok:
        try:
            existing = read_file(path)
        except:
            existing = String("")
    if len(existing.as_bytes()) > 0:
        var eb = existing.as_bytes()
        if eb[len(eb) - 1] != 0x0A:
            existing = existing + String("\n")
    var content = existing + line + String("\n")
    return write_file(path, content)


struct Speller(Movable):
    """Lazy wordlist with case-insensitive + plural-tolerant lookup.

    Tracks three layered word sources in two bucket sets:
    * ``buckets`` — OS dictionary (large, immutable per session) and
      the per-user dictionary. Loaded once on the first ``load_default``
      call and never cleared.
    * ``project_buckets`` — per-project dictionary loaded from
      ``<project>/.turbokod/dictionary.txt``. Cleared and reloaded
      whenever the open project changes via ``set_project``.

    ``check_word`` consults both, so a project word that would be
    misspelled-by-default ends up green, and switching projects
    forgets the previous project's overrides without reloading the
    whole 235k-word OS list.
    """
    var buckets: List[List[String]]
    var project_buckets: List[List[String]]
    var loaded: Bool
    var version: Int
    """Bumps whenever the set of known words changes, so a caller that
    caches per-line results (``Editor._refresh_spell``) knows to drop
    them."""
    # Path of the project dictionary currently in ``project_buckets``;
    # empty means "no project loaded." Tracked so ``set_project`` can
    # short-circuit re-load when the project hasn't actually changed.
    var project_root: String

    def __init__(out self):
        self.buckets = List[List[String]]()
        for _ in range(Int(_N_BUCKETS)):
            self.buckets.append(List[String]())
        self.project_buckets = List[List[String]]()
        for _ in range(Int(_N_BUCKETS)):
            self.project_buckets.append(List[String]())
        self.loaded = False
        self.version = 0
        self.project_root = String("")

    def load_default(mut self):
        """Layer five word sources, in order, into ``buckets``:

        1. The OS-supplied wordlist (``/usr/share/dict/words`` and
           friends) — broad but archaic English vocabulary (on macOS
           it's Webster's 1934, with no inflected forms).
        2. The bundled wordlists under ``src/turbokod/data/wordlists/``:
           ``english.txt`` (SCOWL en_US size 60) for modern English
           with every inflection spelled out (``applies``, ``planned``,
           ``held``, ``downtime``), plus the programmer wordlists
           (vendored from ``streetsidesoftware/cspell-dicts``, MIT) —
           software terms
           that the OS list lacks (``bitwise``, ``hashable``,
           ``tokenizer``, ``regex``, ``bcrypt``, …) and per-language
           jargon for the most common languages we ship grammars for.
        3. User-installed extra-language dictionaries under
           ``~/.config/turbokod/dictionaries/`` (German, Swedish, …).
        4. The user dictionary — words the user has explicitly added.

        Each layer is best-effort; missing files are skipped silently.
        ``loaded`` flips True if *anything* loaded — when nothing did,
        ``check_word`` returns True for everything so the editor degrades
        to "no spell highlights" rather than spurious squiggles.

        The user dictionary loads last so additions reach ``buckets``
        even when the OS / bundled lists fail."""
        if self.loaded:
            return
        var candidates = List[String]()
        candidates.append(String("/usr/share/dict/words"))
        candidates.append(String("/usr/share/dict/american-english"))
        candidates.append(String("/usr/share/dict/british-english"))
        for i in range(len(candidates)):
            try:
                var content = read_file(candidates[i])
                if len(content.as_bytes()) == 0:
                    continue
                var lines = split_lines_no_trailing(content)
                self._load_words(lines)
                break
            except:
                continue
        self._load_bundled_wordlists()
        self._load_user_language_dictionaries()
        var udp = user_dict_path()
        if len(udp.as_bytes()) > 0:
            try:
                var content = read_file(udp)
                if len(content.as_bytes()) > 0:
                    var lines = split_lines_no_trailing(content)
                    self._load_words(lines)
            except e:
                # User dictionary is optional; a missing/unreadable
                # file is the common case. Log so a permission flap
                # is debuggable.
                print("spell: load user_dict_path", udp, ":", String(e))

    def reload(mut self):
        """Drop the in-memory main bucket set and re-run ``load_default``.
        Used after the user installs or removes a downloaded dictionary
        from Settings — the just-installed words show up on the next
        spell pass without restarting the editor.

        ``project_buckets`` is preserved (the project dictionary is
        independent of installed languages); the caller decides whether
        to additionally call ``set_project`` to refresh it."""
        for i in range(len(self.buckets)):
            self.buckets[i] = List[String]()
        self.loaded = False
        self.version += 1
        self.load_default()

    def _load_user_language_dictionaries(mut self):
        """Load every ``<lang>.txt`` under ``~/.config/turbokod/dictionaries/``.

        Each file is treated as a plain wordlist (one word per line,
        ``#``-prefixed comments skipped, lines containing whitespace
        rejected — the same shape as the bundled cspell-derived
        wordlists). Missing root dir is a silent no-op so a fresh
        machine without any installed extra languages still loads
        cleanly."""
        var dir = user_dictionaries_root()
        if len(dir.as_bytes()) == 0:
            return
        var entries = list_directory(dir)
        if len(entries) == 0:
            return
        for i in range(len(entries)):
            var name = entries[i]
            if not name.endswith(".txt"):
                continue
            var path = join_path(dir, name)
            try:
                var content = read_file(path)
                if len(content.as_bytes()) == 0:
                    continue
                var lines = split_lines_no_trailing(content)
                var filtered = List[String]()
                for j in range(len(lines)):
                    var w = _strip_word(lines[j])
                    if len(w.as_bytes()) == 0:
                        continue
                    filtered.append(w^)
                if len(filtered) > 0:
                    self._load_words(filtered)
            except:
                continue

    def _load_bundled_wordlists(mut self):
        """Load every ``.txt`` in ``src/turbokod/data/wordlists/``.

        Path is relative to cwd; ``run.sh`` cd's to the project root
        before exec, so this resolves whether the user invokes the
        editor via ``run.sh`` or ``pixi run``. When the directory is
        missing (e.g. running from an installed binary in a future
        packaging) the load is silently skipped — the OS list and user
        dict still work."""
        var dir = String("src/turbokod/data/wordlists")
        var entries = list_directory(dir)
        if len(entries) == 0:
            return
        for i in range(len(entries)):
            var name = entries[i]
            if not name.endswith(".txt"):
                continue
            var path = join_path(dir, name)
            try:
                var content = read_file(path)
                if len(content.as_bytes()) == 0:
                    continue
                var lines = split_lines_no_trailing(content)
                var filtered = List[String]()
                for j in range(len(lines)):
                    var w = _strip_word(lines[j])
                    if len(w.as_bytes()) == 0:
                        continue
                    filtered.append(w^)
                if len(filtered) > 0:
                    self._load_words(filtered)
            except:
                continue

    def set_project(mut self, project_root: String):
        """Swap ``project_buckets`` to the dictionary for ``project_root``.

        Loads two sources, in order, into the freshly cleared project
        buckets:

        1. ``<project>/.turbokod/dictionary.txt`` — our own per-project
           dictionary (one word per line).
        2. ``<project>/.idea/dictionaries/*.xml`` — JetBrains-style
           project dictionaries that the team likely already curates;
           we honor them so port projects don't get a screen full of
           red squiggles on the team's vocabulary.

        Empty ``project_root`` clears the project dictionary (used when
        the host closes the project). Re-calling with the same root is
        a no-op so paint-time invocations don't re-read the file each
        frame."""
        debug_log(String("[speller.set_project] ENTER root=") + project_root)
        if project_root == self.project_root:
            debug_log(String("[speller.set_project] unchanged, returning"))
            return
        debug_log(String("[speller.set_project] clearing project_buckets n=")
            + String(len(self.project_buckets)))
        for i in range(len(self.project_buckets)):
            self.project_buckets[i] = List[String]()
        self.project_root = project_root
        self.version += 1
        if len(project_root.as_bytes()) == 0:
            debug_log(String("[speller.set_project] empty root, returning"))
            return
        var path = project_dict_path(project_root)
        debug_log(String("[speller.set_project] dict path=") + path)
        if len(path.as_bytes()) > 0:
            try:
                var content = read_file(path)
                debug_log(String("[speller.set_project] read ")
                    + String(len(content.as_bytes())) + String(" bytes"))
                if len(content.as_bytes()) > 0:
                    var lines = split_lines_no_trailing(content)
                    debug_log(String("[speller.set_project] loading ")
                        + String(len(lines)) + String(" lines"))
                    self._load_project_words(lines)
                    debug_log(String("[speller.set_project] loaded project words"))
            except e:
                debug_log(String("[speller.set_project] read exc: ") + String(e))
        debug_log(String("[speller.set_project] before _load_idea_dictionaries"))
        self._load_idea_dictionaries(project_root)
        debug_log(String("[speller.set_project] EXIT"))

    def _load_idea_dictionaries(mut self, project_root: String):
        var dict_dir = join_path(
            join_path(project_root, String(".idea")), String("dictionaries"),
        )
        debug_log(String("[_load_idea_dictionaries] dir=") + dict_dir)
        var entries = list_directory(dict_dir)
        debug_log(String("[_load_idea_dictionaries] after list_directory call"))
        var n_entries = len(entries)
        debug_log(String("[_load_idea_dictionaries] entries=")
            + String(n_entries))
        if len(entries) == 0:
            return
        var words = List[String]()
        for i in range(len(entries)):
            var name = entries[i]
            if name == String(".") or name == String(".."):
                continue
            if not name.endswith(".xml"):
                continue
            var path = join_path(dict_dir, name)
            debug_log(String("[_load_idea_dictionaries] reading ") + path)
            try:
                var content = read_file(path)
                debug_log(String("[_load_idea_dictionaries] parsing ")
                    + String(len(content.as_bytes())) + String(" bytes"))
                _parse_idea_dict_words(content, words)
                debug_log(String("[_load_idea_dictionaries] parsed -> words=")
                    + String(len(words)))
            except e:
                debug_log(String("[_load_idea_dictionaries] read exc: ")
                    + String(e))
                continue
        if len(words) > 0:
            debug_log(String("[_load_idea_dictionaries] _load_project_words n=")
                + String(len(words)))
            self._load_project_words(words)
            debug_log(String("[_load_idea_dictionaries] _load_project_words done"))

    def _load_project_words(mut self, words: List[String]):
        for i in range(len(words)):
            var w = _normalize(words[i])
            if len(w.as_bytes()) == 0:
                continue
            var b = _bucket(w)
            self.project_buckets[b].append(w^)
        self.version += 1

    def add_user_word(mut self, word: String) -> Bool:
        """Add ``word`` to the user dictionary in memory and on disk.

        In-memory addition flips ``loaded`` to True even on systems
        without an OS wordlist — the user explicitly trained the
        speller, so subsequent ``check_word`` calls should consult the
        bucket they just put a word into instead of returning True for
        everything.
        Returns False when the word can't be persisted (e.g. ``$HOME``
        unset); the in-memory addition still happens so the underline
        goes away for the rest of the session."""
        var lw = _normalize(word)
        if len(lw.as_bytes()) == 0:
            return False
        self.loaded = True
        if self._has(lw):
            return True  # already known — don't grow the bucket / dup the file
        var b = _bucket(lw)
        self.buckets[b].append(lw)
        self.version += 1
        var path = user_dict_path()
        if len(path.as_bytes()) == 0:
            return False
        return _append_to_file(path, lw)

    def add_project_word(mut self, word: String) -> Bool:
        """Add ``word`` to the project dictionary in memory and on disk.

        No-op (returns False) when no project is open — the host should
        gate the menu item so this can't be reached. We don't fall back
        to the user dictionary because the two are semantically
        different ("everyone on this codebase considers this spelled
        right" vs "I, the user, consider this spelled right")."""
        if len(self.project_root.as_bytes()) == 0:
            return False
        var lw = _normalize(word)
        if len(lw.as_bytes()) == 0:
            return False
        if self._has(lw):
            return True  # already known — don't grow the bucket / dup the file
        var b = _bucket(lw)
        self.project_buckets[b].append(lw)
        self.version += 1
        var path = project_dict_path(self.project_root)
        if len(path.as_bytes()) == 0:
            return False
        return _append_to_file(path, lw)

    def load_words(mut self, words: List[String]):
        """Test seam: bypass the OS wordlist and load an explicit small
        dictionary. Tests use this so they don't depend on whichever
        ``/usr/share/dict/words`` happens to ship with the host."""
        self._load_words(words)

    def _load_words(mut self, words: List[String]):
        for i in range(len(words)):
            var w = _normalize(words[i])
            if len(w.as_bytes()) == 0:
                continue
            var b = _bucket(w)
            self.buckets[b].append(w^)
        self.loaded = True
        self.version += 1

    def check_word(self, word: String) -> Bool:
        """``True`` if ``word`` (or a stripped form) is in the dictionary.

        When the dictionary failed to load, returns ``True`` for
        everything — we'd rather show no underlines than mark every
        word as misspelled."""
        if not self.loaded:
            return True
        var lw = _normalize(word)
        if self._has(lw):
            return True
        var b = lw.as_bytes()
        var n = len(b)
        # Possessive / contracted "is": foo's -> foo (also covers it's, he's).
        if n >= 3 and b[n - 2] == 0x27 and b[n - 1] == 0x73:
            if self._has(byte_slice(lw, 0, n - 2)):
                return True
        # Negative contraction "n't": hasn't -> has, wouldn't -> would,
        # didn't -> did. Most English negative contractions follow this
        # pattern; the few that don't (won't, shan't, ain't) fall through
        # to the "'t" stripper below or to the user dictionary.
        if n >= 5 and b[n - 3] == 0x6E and b[n - 2] == 0x27 and b[n - 1] == 0x74:
            if self._has(byte_slice(lw, 0, n - 3)):
                return True
        # Bare "'t" contraction: can't -> can, won't -> won. Tighter
        # than n't because two-letter heads (ai't, sh't) are noise.
        if n >= 5 and b[n - 2] == 0x27 and b[n - 1] == 0x74:
            if self._has(byte_slice(lw, 0, n - 2)):
                return True
        # "'re": they're -> they, you're -> you.
        if n >= 5 and b[n - 3] == 0x27 and b[n - 2] == 0x72 and b[n - 1] == 0x65:
            if self._has(byte_slice(lw, 0, n - 3)):
                return True
        # "'ve": they've -> they, would've -> would.
        if n >= 5 and b[n - 3] == 0x27 and b[n - 2] == 0x76 and b[n - 1] == 0x65:
            if self._has(byte_slice(lw, 0, n - 3)):
                return True
        # "'ll": they'll -> they, you'll -> you.
        if n >= 5 and b[n - 3] == 0x27 and b[n - 2] == 0x6C and b[n - 1] == 0x6C:
            if self._has(byte_slice(lw, 0, n - 3)):
                return True
        # "'d": they'd -> they, would'd... rare but cheap to support.
        if n >= 5 and b[n - 2] == 0x27 and b[n - 1] == 0x64:
            if self._has(byte_slice(lw, 0, n - 2)):
                return True
        # Plural: foos -> foo, dishes -> dish
        if n >= 4 and b[n - 1] == 0x73:
            if self._has(byte_slice(lw, 0, n - 1)):
                return True
            if n >= 5 and b[n - 2] == 0x65:
                if self._has(byte_slice(lw, 0, n - 2)):
                    return True
        # Past tense: walked -> walk, loved -> love
        if n >= 5 and b[n - 2] == 0x65 and b[n - 1] == 0x64:
            if self._has(byte_slice(lw, 0, n - 2)):
                return True
            if self._has(byte_slice(lw, 0, n - 1)):
                return True
        # Gerund: walking -> walk, loving -> love
        if n >= 6 and b[n - 3] == 0x69 and b[n - 2] == 0x6E and b[n - 1] == 0x67:
            if self._has(byte_slice(lw, 0, n - 3)):
                return True
            if self._has(byte_slice(lw, 0, n - 3) + String("e")):
                return True
        return False

    def _has(self, w: String) -> Bool:
        var b = _bucket(w)
        var n = len(self.buckets[b])
        for i in range(n):
            if self.buckets[b][i] == w:
                return True
        var pn = len(self.project_buckets[b])
        for i in range(pn):
            if self.project_buckets[b][i] == w:
                return True
        return False


def find_misspelled_runs(
    self_speller: Speller, text: String,
) -> List[Tuple[Int, Int]]:
    """``(byte_start, byte_end)`` of every misspelled word in ``text``.

    Language-agnostic on purpose: there's no notion of comment, string
    or code here, so ``foo_bar``, ``fooBar`` and ``foo bar`` all check
    ``foo`` and ``bar`` whatever file they're in. Words are runs of
    letters (Unicode included, so ``Godkänn`` is one word); digits,
    underscores and punctuation separate them, and camelCase splits
    inside a run — ``fooBar`` → ``foo`` + ``Bar``, ``HTTPServer`` →
    ``HTTP`` + ``Server``. An apostrophe between two ASCII letters stays
    in the word so ``check_word``'s contraction strippers see ``hasn't``
    whole. Segments under 4 bytes and all-caps ones (acronyms,
    ``SCREAMING_CASE``) aren't checked."""
    var out = List[Tuple[Int, Int]]()
    if not self_speller.loaded:
        return out^
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var info = codepoint_at(text, i)
        if not _is_letter_cp(info[0]):
            i += info[1]
            continue
        var seg = i
        var j = i
        var prev_upper = False
        var prev2_upper = False
        var prev_start = -1
        while j < n:
            var c = codepoint_at(text, j)
            if _is_letter_cp(c[0]):
                var up = _is_upper_cp(c[0])
                if prev_start >= 0:
                    if up and not prev_upper:
                        # fooBar: a capital after a lowercase letter.
                        _check_segment(self_speller, text, seg, j, out)
                        seg = j
                    elif not up and prev_upper and prev2_upper \
                            and prev_start > seg:
                        # HTTPServer: the last capital of a run starts
                        # the next word.
                        _check_segment(self_speller, text, seg, prev_start, out)
                        seg = prev_start
                prev2_upper = prev_upper
                prev_upper = up
                prev_start = j
                j += c[1]
            elif b[j] == 0x27 and j > seg and _is_letter(b[j - 1]) \
                    and j + 1 < n and _is_letter(b[j + 1]):
                j += 1
            else:
                break
        _check_segment(self_speller, text, seg, j, out)
        i = j
    return out^


def _check_segment(
    speller: Speller, text: String, start: Int, end: Int,
    mut out: List[Tuple[Int, Int]],
):
    if end - start < 4:
        return
    var has_lower = False
    var k = start
    while k < end:
        var c = codepoint_at(text, k)
        if c[0] != 0x27 and not _is_upper_cp(c[0]):
            has_lower = True
            break
        k += c[1]
    if not has_lower:
        return
    if speller.check_word(byte_slice(text, start, end)):
        return
    # Not a word as a whole. An apostrophe inside it may be English
    # (``hasn't``, which ``check_word`` already handles) or a quote
    # character in code (``f'dryft``, ``'a'+b``): retry each side of every
    # apostrophe on its own and flag only the pieces that still fail.
    var has_apos = False
    k = start
    while k < end:
        if text.as_bytes()[k] == 0x27:
            has_apos = True
            break
        k += 1
    if not has_apos:
        out.append((start, end))
        return
    var piece = start
    k = start
    while k <= end:
        if k == end or text.as_bytes()[k] == 0x27:
            if k > piece:
                _check_segment_piece(speller, text, piece, k, out)
            piece = k + 1
        k += 1


def _check_segment_piece(
    speller: Speller, text: String, start: Int, end: Int,
    mut out: List[Tuple[Int, Int]],
):
    """One apostrophe-free side of a split segment: same length and
    all-caps rules as ``_check_segment``, no further splitting."""
    if end - start < 4:
        return
    var has_lower = False
    var k = start
    while k < end:
        var c = codepoint_at(text, k)
        if not _is_upper_cp(c[0]):
            has_lower = True
            break
        k += c[1]
    if not has_lower:
        return
    if not speller.check_word(byte_slice(text, start, end)):
        out.append((start, end))


def _is_letter_cp(cp: Int) -> Bool:
    """A word codepoint that is a letter: ``is_word_codepoint`` minus
    the ASCII digits and underscore it also accepts."""
    if cp < 0x80:
        return (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
    return is_word_codepoint(cp)


def _is_upper_cp(cp: Int) -> Bool:
    """Uppercase for camelCase splitting: ASCII, Latin-1, Greek and
    Cyrillic capitals. Letters outside those ranges count as lowercase,
    which only means a case change there doesn't split a word."""
    if cp >= 0x41 and cp <= 0x5A:
        return True
    if cp >= 0xC0 and cp <= 0xDE and cp != 0xD7:
        return True
    if cp >= 0x391 and cp <= 0x3A9:
        return True
    if cp >= 0x400 and cp <= 0x42F:
        return True
    return False


def has_spell_noinspection_directive(text: String) -> Bool:
    """True if ``text`` contains an IntelliJ-style directive that
    disables the spell-check inspection. Recognized forms:

      ``# noinspection SpellCheckingInspection``
      ``// noinspection SpellCheckingInspection``
      ``<!-- noinspection SpellCheckingInspection -->``
      ``noinspection SpellCheckingInspection,OtherInspection``
      ``noinspection All``  (catch-all — disables every inspection)

    The comment marker is irrelevant: callers pass already-extracted
    comment text. The match is on the literal ``noinspection`` keyword
    (word-bounded) followed by a comma-separated token list that must
    contain ``SpellCheckingInspection`` or ``All``."""
    var b = text.as_bytes()
    var n = len(b)
    var key = String("noinspection")
    var kb = key.as_bytes()
    var kn = len(kb)
    if kn > n:
        return False
    var i = 0
    while i + kn <= n:
        var hit = True
        for j in range(kn):
            if b[i + j] != kb[j]:
                hit = False
                break
        if not hit:
            i += 1
            continue
        # Word boundary on the left and a whitespace separator on the
        # right — ``noinspections`` (sic) or ``xnoinspection`` don't
        # count.
        var ok_left = i == 0 or not is_ascii_ident_byte(b[i - 1])
        var after = i + kn
        var ok_right = (
            after < n and (b[after] == 0x20 or b[after] == 0x09)
        )
        if not (ok_left and ok_right):
            i += 1
            continue
        var p = after
        while p < n and (b[p] == 0x20 or b[p] == 0x09):
            p += 1
        while p < n:
            var t_start = p
            while p < n:
                var c = b[p]
                if c == 0x20 or c == 0x09 or c == 0x2C:
                    break
                p += 1
            if p > t_start:
                var token = byte_slice(text, t_start, p)
                if (
                    token == String("SpellCheckingInspection")
                    or token == String("All")
                ):
                    return True
            while p < n and (b[p] == 0x20 or b[p] == 0x09):
                p += 1
            if p < n and b[p] == 0x2C:
                p += 1
                while p < n and (b[p] == 0x20 or b[p] == 0x09):
                    p += 1
                continue
            break
        i = p if p > i else i + 1
    return False


def spell_key(word: String) -> String:
    """The case-folded, NFC-composed form the speller stores and looks
    words up by — what two spellings of "the same word" share. Public
    so callers that group flagged words (the project spell scan) agree
    with the dictionary about what counts as one word."""
    return _normalize(word)


def _bucket(w: String) -> Int:
    var b = w.as_bytes()
    var h = UInt32(2166136261)
    for i in range(len(b)):
        h = (h ^ UInt32(b[i])) * UInt32(16777619)
    return Int(h % _N_BUCKETS)


def _normalize(s: String) -> String:
    """Bucket-lookup key: lowercase + Latin-1 case fold + NFD→NFC compose.

    Three things happen here, all driven by examples that bit us in
    practice:

    * **Case fold** ASCII A-Z and the Latin-1 supplement (À-Ö, Ø-Þ).
      Without the second range, ``Övrigt`` (Ö = ``0xC3 0x96``) hashed
      to a different bucket than the on-disk lowercase ``övrigt``
      (ö = ``0xC3 0xB6``) and was flagged as a misspelling.
    * **NFD → NFC compose** the Latin-1 letters. macOS-sourced text
      sometimes ships in NFD form: ``Ö`` arrives as ``O`` + combining
      diaeresis (``U+004F U+0308``) instead of the precomposed
      ``U+00D6``. Both forms fold to the same key here so the lookup
      doesn't depend on which path the bytes took into the editor.
    * **UTF-8 in/out** so the key works for any input the user types
      or pastes. Non-Latin scripts pass through unchanged (they already
      have only one form), and 4-byte codepoints (CJK, emoji) are
      preserved untouched.

    Used both at load time (when populating buckets) and at lookup
    time, so producer and consumer agree on the canonical form."""
    var n_bytes = len(s.as_bytes())
    if n_bytes == 0:
        return String("")
    var out = List[UInt8]()
    var i = 0
    while i < n_bytes:
        var step = codepoint_at(s, i)
        var cp = step[0]
        var sz = step[1]
        var lower_cp = _lower_codepoint(cp)
        # Peek the next codepoint — if it's a combining diacritic that
        # composes with this base letter, emit the precomposed form
        # instead and skip past both. Falls through when the next
        # codepoint isn't a known mark or doesn't combine.
        var next_i = i + sz
        if next_i < n_bytes:
            var next_step = codepoint_at(s, next_i)
            var combined = _compose_diacritic(lower_cp, next_step[0])
            if combined > 0:
                append_utf8(out, combined)
                i = next_i + next_step[1]
                continue
        append_utf8(out, lower_cp)
        i += sz
    if len(out) == 0:
        return String("")
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out))))


def _lower_codepoint(cp: Int) -> Int:
    """Lowercase ``cp`` if it's an upper-case ASCII or Latin-1 letter.

    Skips ``×`` (U+00D7) — it shares its slot with the multiplication
    sign in the Latin-1 supplement and isn't a letter. ``ß`` (U+00DF)
    has no precomposed Latin-1 uppercase form, so we leave it alone
    (the modern uppercase ``ẞ`` at U+1E9E is rare in everyday text)."""
    if 0x41 <= cp and cp <= 0x5A:
        return cp + 0x20
    if 0xC0 <= cp and cp <= 0xDE and cp != 0xD7:
        return cp + 0x20
    return cp


def _compose_diacritic(base: Int, mark: Int) -> Int:
    """Compose ``base`` (an ASCII or Latin-1 lowercase letter) with
    ``mark`` (a combining diacritic) into a precomposed Latin-1
    supplement codepoint, or return 0 when no composition is known.

    Covers the diacritics European languages we ship dictionaries
    for actually use: grave, acute, circumflex, tilde, diaeresis,
    ring above, cedilla. Letters outside this list (e.g. composed
    Latin Extended-A like ``ē`` U+0113) aren't folded — the spell
    bucket just stores them in their decomposed form, which is fine
    as long as both producer and consumer agree (and they do, since
    both go through this normalizer)."""
    if mark == 0x300:
        if base == 0x61: return 0xE0    # à
        if base == 0x65: return 0xE8    # è
        if base == 0x69: return 0xEC    # ì
        if base == 0x6F: return 0xF2    # ò
        if base == 0x75: return 0xF9    # ù
    elif mark == 0x301:
        if base == 0x61: return 0xE1    # á
        if base == 0x65: return 0xE9    # é
        if base == 0x69: return 0xED    # í
        if base == 0x6F: return 0xF3    # ó
        if base == 0x75: return 0xFA    # ú
        if base == 0x79: return 0xFD    # ý
    elif mark == 0x302:
        if base == 0x61: return 0xE2    # â
        if base == 0x65: return 0xEA    # ê
        if base == 0x69: return 0xEE    # î
        if base == 0x6F: return 0xF4    # ô
        if base == 0x75: return 0xFB    # û
    elif mark == 0x303:
        if base == 0x61: return 0xE3    # ã
        if base == 0x6E: return 0xF1    # ñ
        if base == 0x6F: return 0xF5    # õ
    elif mark == 0x308:
        if base == 0x61: return 0xE4    # ä
        if base == 0x65: return 0xEB    # ë
        if base == 0x69: return 0xEF    # ï
        if base == 0x6F: return 0xF6    # ö
        if base == 0x75: return 0xFC    # ü
        if base == 0x79: return 0xFF    # ÿ
    elif mark == 0x30A:
        if base == 0x61: return 0xE5    # å
    elif mark == 0x327:
        if base == 0x63: return 0xE7    # ç
    return 0


def _is_letter(c: UInt8) -> Bool:
    return (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)


def _strip_word(line: String) -> String:
    """Strip a wordlist line: trim ASCII whitespace, drop comment-only
    (``#``-prefixed) lines, and reject anything containing whitespace
    after trimming (entries from cspell are sometimes weird shapes —
    e.g. ``en cspell-tools: keep-case`` headers — that we don't want
    polluting the buckets)."""
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and (b[i] == 0x20 or b[i] == 0x09):
        i += 1
    var j = n
    while j > i and (b[j - 1] == 0x20 or b[j - 1] == 0x09 or b[j - 1] == 0x0D):
        j -= 1
    if j <= i:
        return String("")
    if b[i] == 0x23:    # '#'
        return String("")
    for k in range(i, j):
        var c = b[k]
        if c == 0x20 or c == 0x09:
            return String("")
    return String(StringSpan(unsafe_from_utf8=b[i:j]))


def _parse_idea_dict_words(content: String, mut out: List[String]):
    """Pull text inside ``<w>...</w>`` elements out of an IntelliJ
    project dictionary XML file and append to ``out``. Byte-level scan
    rather than a real XML parse — IDEA always emits the same simple
    shape (``<w>foo</w>``, no attributes), so we don't need to handle
    anything fancier."""
    var b = content.as_bytes()
    var n = len(b)
    var i = 0
    while i + 2 < n:
        # Open tag: ``<w>``.
        if b[i] == 0x3C and b[i + 1] == 0x77 and b[i + 2] == 0x3E:
            i += 3
            var start = i
            var found = False
            # Scan to ``</w>``.
            while i + 3 < n:
                if (
                    b[i] == 0x3C and b[i + 1] == 0x2F
                    and b[i + 2] == 0x77 and b[i + 3] == 0x3E
                ):
                    found = True
                    break
                i += 1
            if not found:
                return
            if i > start:
                out.append(String(StringSpan(unsafe_from_utf8=b[start:i])))
            i += 4    # past </w>
        else:
            i += 1
