"""Spell checker.

Loads a wordlist (the bundled SCOWL English list plus, on macOS,
``/usr/share/dict/words``; common Linux paths otherwise) into a
compact set (``WordSet``) keyed by lowercase word. Lookup is case-insensitive
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
from std.ffi import external_call
from std.sys import size_of

from .dictionary_install import user_dictionaries_root
from .file_io import (
    join_path, list_directory, make_parent_dirs, read_existing_file,
    read_file, stat_file, write_file,
)
from .posix import debug_log, user_config_path
from .word_set import WordSet
from .string_utils import (
    append_utf8,
    byte_slice, codepoint_at, is_ascii_digit, is_ascii_ident_byte,
    is_word_codepoint, split_lines_no_trailing, word_char_step,
)


def user_dict_path() -> String:
    """``~/.config/turbokod/dictionary.txt``, or ``""`` when ``$HOME``
    is unset. One word per line; appended whenever the user picks
    "Add to user dictionary" on a misspelled word."""
    return user_config_path(String("dictionary.txt"))


def library_words_path() -> String:
    """``~/.config/turbokod/library_words.txt``, or ``""`` when ``$HOME``
    is unset. Identifiers the language server resolved to a definition in
    a library or the standard library (``shutil``, ``rmtree``), learned
    automatically so they aren't flagged; see
    ``Desktop._maybe_probe_library_word``. Same format as the user
    dictionary, and like it shared by every project."""
    return user_config_path(String("library_words.txt"))


def is_library_location(path: String, project_root: String) -> Bool:
    """Whether a definition at ``path`` belongs to a library rather than
    to the project: outside ``project_root``, or inside it under a
    dependency directory (a virtualenv, ``node_modules``, a pixi
    environment). False with no project, where there's no telling."""
    if len(project_root.as_bytes()) == 0 or len(path.as_bytes()) == 0:
        return False
    var prefix = project_root
    if not prefix.endswith("/"):
        prefix = prefix + String("/")
    if not path.startswith(prefix):
        return True
    var rel = byte_slice(path, len(prefix.as_bytes()), len(path.as_bytes()))
    var parts = rel.split("/")
    for i in range(len(parts) - 1):
        var part = String(parts[i])
        if part == "site-packages" or part == "dist-packages" \
                or part == "node_modules" or part == ".venv" \
                or part == "venv" or part == ".pixi" or part == ".tox" \
                or part == "typeshed":
            return True
    return False


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
        # Taken as empty, every word already in it would be written over.
        try:
            existing = read_existing_file(path)
        except:
            return False
    if len(existing.as_bytes()) > 0:
        var eb = existing.as_bytes()
        if eb[len(eb) - 1] != 0x0A:
            existing = existing + String("\n")
    var content = existing + line + String("\n")
    return write_file(path, content)


struct SpellBase(Movable):
    """The main word set — OS dictionary, bundled wordlists, user and
    library words — which is the same for every window of a process.
    A ``Speller`` owns one, or reads a shared one (``Speller.shared``)."""
    var words: WordSet
    var loaded: Bool
    var version: Int

    def __init__(out self):
        self.words = WordSet()
        self.loaded = False
        self.version = 0

    def add(mut self, w: String):
        """Add the already-normalized ``w`` unless it's already there: the
        wordlists overlap (~57k of ~349k words are repeats)."""
        _ = self.words.add(w.as_bytes())

    def word_count(self) -> Int:
        return self.words.count

    def touch(mut self, loaded: Bool):
        self.loaded = loaded
        self.version += 1

    def clear(mut self):
        self.words.clear()
        self.touch(False)

    def has(self, w: String) -> Bool:
        return self.words.has(w.as_bytes())


@fieldwise_init
struct _WordSource(Copyable, Movable):
    """One wordlist file ``Speller.load_default`` reads."""
    var path: String
    var strip: Bool
    """A cspell-style list: trim each line, skip ``#`` comments and
    anything with whitespace in it. False takes each line as a word."""
    var report: Bool
    """Print a failed read (the user's own lists) instead of skipping it
    silently."""


def spell_base_at(addr: Int) -> Pointer[SpellBase, MutUntrackedOrigin]:
    return Pointer[SpellBase, MutUntrackedOrigin](unsafe_from_address=addr)


def new_spell_base() -> Int:
    """A heap ``SpellBase`` for the whole process (the host makes one and
    gives it to every window); 0 on allocation failure. Never freed."""
    var addr = external_call["malloc", Int](size_of[SpellBase]())
    if addr == 0:
        return 0
    spell_base_at(addr).unsafe_write(SpellBase())
    return addr


def free_spell_base(addr: Int):
    """Free a ``new_spell_base`` nothing reads any more (tests)."""
    if addr == 0:
        return
    spell_base_at(addr).unsafe_deinit_pointee()
    _ = external_call["free", Int](addr)


struct Speller(Movable):
    """Lazy wordlist with case-insensitive + plural-tolerant lookup.

    Tracks three layered word sources in two sets:
    * the main set (``SpellBase``) — OS dictionary (large, immutable per
      session) and the per-user dictionary. Loaded once on the first ``load_default``
      call and never cleared.
    * ``project_words`` — per-project dictionary loaded from
      ``<project>/.turbokod/dictionary.txt``. Cleared and reloaded
      whenever the open project changes via ``set_project``.

    ``check_word`` consults both, so a project word that would be
    misspelled-by-default ends up green, and switching projects
    forgets the previous project's overrides without reloading the
    whole 235k-word OS list.
    """
    var _own: SpellBase
    var shared: Int
    """Address of the process-wide ``SpellBase`` (``new_spell_base``) this
    speller reads its main word set from, or 0 to use its own. The native
    host hands one to every window, so the 350k-word dictionary is held
    once per process rather than once per window; a word added to it in
    one window is known in all of them."""
    var project_words: WordSet
    var _project_version: Int
    # Path of the project dictionary currently in ``project_words``;
    # empty means "no project loaded." Tracked so ``set_project`` can
    # short-circuit re-load when the project hasn't actually changed.
    var project_root: String

    def __init__(out self):
        self._own = SpellBase()
        self.shared = 0
        self.project_words = WordSet()
        self._project_version = 0
        self.project_root = String("")

    # --- the main word set: this speller's own, or the shared one ---------

    def is_loaded(self) -> Bool:
        if self.shared != 0:
            return spell_base_at(self.shared)[].loaded
        return self._own.loaded

    def word_version(self) -> Int:
        """Changes whenever the set of known words does — here, or in the
        shared set from another window — so a caller that caches per-line
        results (``Editor._refresh_spell``) knows to drop them."""
        if self.shared != 0:
            return self._project_version + spell_base_at(self.shared)[].version
        return self._project_version + self._own.version

    def _base_add(mut self, w: String):
        if self.shared != 0:
            spell_base_at(self.shared)[].add(w)
        else:
            self._own.add(w)

    def _base_add_bytes(mut self, w: Span[UInt8, _]):
        """``_base_add`` for normalized bytes that aren't a ``String`` yet."""
        if self.shared != 0:
            _ = spell_base_at(self.shared)[].words.add(w)
        else:
            _ = self._own.words.add(w)

    def _base_reserve(mut self, bytes: Int, words: Int):
        if self.shared != 0:
            spell_base_at(self.shared)[].words.reserve(bytes, words)
        else:
            self._own.words.reserve(bytes, words)

    def _base_touch(mut self, loaded: Bool):
        """Record a change to the main set: its ``loaded`` flag and a
        version bump."""
        if self.shared != 0:
            spell_base_at(self.shared)[].touch(loaded)
        else:
            self._own.touch(loaded)

    def _base_clear(mut self):
        if self.shared != 0:
            spell_base_at(self.shared)[].clear()
        else:
            self._own.clear()

    def _base_has(self, w: String) -> Bool:
        if self.shared != 0:
            return spell_base_at(self.shared)[].has(w)
        return self._own.has(w)

    def load_default(mut self):
        """Layer five word sources, in order, into the main set:

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
        5. Library words — identifiers learned from the language
           servers (``library_words_path``).

        Each layer is best-effort; missing files are skipped silently.
        ``loaded`` flips True if *anything* loaded — when nothing did,
        ``check_word`` returns True for everything so the editor degrades
        to "no spell highlights" rather than spurious squiggles.

        The user dictionary loads last so additions reach the set
        even when the OS / bundled lists fail."""
        if self.is_loaded():
            return
        var sources = List[_WordSource]()
        var candidates = List[String]()
        candidates.append(String("/usr/share/dict/words"))
        candidates.append(String("/usr/share/dict/american-english"))
        candidates.append(String("/usr/share/dict/british-english"))
        for i in range(len(candidates)):
            var info = stat_file(candidates[i])
            if info.ok and info.size > 0:
                sources.append(_WordSource(candidates[i], False, False))
                break
        # Path is relative to cwd; ``run.sh`` cd's to the project root
        # before exec, and the app bundle chdirs to its resources.
        _wordlists_in(String("src/turbokod/data/wordlists"), sources)
        var user_dir = user_dictionaries_root()
        if len(user_dir.as_bytes()) > 0:
            _wordlists_in(user_dir, sources)
        var own = List[String]()
        own.append(user_dict_path())
        own.append(library_words_path())
        for i in range(len(own)):
            if len(own[i].as_bytes()) > 0 and stat_file(own[i]).ok:
                sources.append(_WordSource(own[i], False, True))
        # Size the set once, from the files' sizes: grown word by word it
        # leaves every outgrown blob and table behind as garbage. A word
        # per line makes the bytes exact; the word count is a low guess
        # (12 bytes a word, where English averages 10) because the table
        # doubles, and one doubling too many is megabytes.
        var total = 0
        for i in range(len(sources)):
            total += Int(stat_file(sources[i].path).size)
        self._base_reserve(total, total // 12)
        var scratch = List[UInt8]()
        for i in range(len(sources)):
            try:
                var content = read_file(sources[i].path)
                if self._load_text(content, sources[i].strip, scratch):
                    self._base_touch(True)
            except e:
                # Log the user's own lists so a permission flap is
                # debuggable; a missing bundled one is skipped.
                if sources[i].report:
                    print("spell: load", sources[i].path, ":", String(e))

    def _load_text(
        mut self, content: String, strip: Bool, mut scratch: List[UInt8],
    ) -> Bool:
        """Add every line of ``content`` as a word, normalized; whether
        there were any. Straight from the file's bytes: splitting 235k
        lines into a ``List[String]`` first and building a ``String`` per
        normalized word was most of the load's time and garbage."""
        var b = content.as_bytes()
        var n = len(b)
        var any = False
        var start = 0
        for i in range(n + 1):
            if i < n and b[i] != 0x0A:
                continue
            var lo = start
            var hi = i
            start = i + 1
            if strip:
                while lo < hi and (b[lo] == 0x20 or b[lo] == 0x09):
                    lo += 1
                while hi > lo and (
                    b[hi - 1] == 0x20 or b[hi - 1] == 0x09
                    or b[hi - 1] == 0x0D
                ):
                    hi -= 1
                if lo < hi and b[lo] == 0x23:    # '#'
                    continue
                var spaced = False
                for k in range(lo, hi):
                    if b[k] == 0x20 or b[k] == 0x09:
                        spaced = True
                        break
                if spaced:
                    continue
            if hi <= lo:
                continue
            # ASCII (nearly every word) only needs lowercasing; the rest
            # goes through ``_normalize``.
            scratch.clear()
            var ascii = True
            for k in range(lo, hi):
                var c = b[k]
                if c >= 0x80:
                    ascii = False
                    break
                if c >= 0x41 and c <= 0x5A:
                    c += 0x20
                scratch.append(c)
            if ascii:
                self._base_add_bytes(Span(scratch))
            else:
                self._base_add(
                    _normalize(String(StringSpan(unsafe_from_utf8=b[lo:hi]))),
                )
            any = True
        return any

    def reload(mut self):
        """Drop the in-memory main word set and re-run ``load_default``.
        Used after the user installs or removes a downloaded dictionary
        from Settings — the just-installed words show up on the next
        spell pass without restarting the editor.

        ``project_words`` is preserved (the project dictionary is
        independent of installed languages); the caller decides whether
        to additionally call ``set_project`` to refresh it."""
        self._base_clear()
        self.load_default()

    def set_project(mut self, project_root: String):
        """Swap ``project_words`` to the dictionary for ``project_root``.

        Loads two sources, in order, into the freshly cleared project
        set:

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
        if project_root == self.project_root:
            return
        self.project_words.clear()
        self.project_root = project_root
        self._project_version += 1
        if len(project_root.as_bytes()) == 0:
            return
        var path = project_dict_path(project_root)
        if len(path.as_bytes()) > 0:
            try:
                var content = read_file(path)
                if len(content.as_bytes()) > 0:
                    var lines = split_lines_no_trailing(content)
                    self._load_project_words(lines)
            except e:
                debug_log(String("[speller.set_project] read exc: ") + String(e))
        self._load_idea_dictionaries(project_root)

    def _load_idea_dictionaries(mut self, project_root: String):
        var dict_dir = join_path(
            join_path(project_root, String(".idea")), String("dictionaries"),
        )
        var entries = list_directory(dict_dir)
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
            try:
                var content = read_file(path)
                _parse_idea_dict_words(content, words)
            except e:
                debug_log(String("[_load_idea_dictionaries] read exc: ")
                    + String(e))
                continue
        if len(words) > 0:
            self._load_project_words(words)

    def _load_project_words(mut self, words: List[String]):
        for i in range(len(words)):
            var w = _normalize(words[i])
            if len(w.as_bytes()) == 0:
                continue
            _ = self.project_words.add(w.as_bytes())
        self._project_version += 1

    def add_user_word(mut self, word: String) -> Bool:
        """Add ``word`` to the user dictionary in memory and on disk.

        In-memory addition flips ``loaded`` to True even on systems
        without an OS wordlist — the user explicitly trained the
        speller, so subsequent ``check_word`` calls should consult the
        set they just put a word into instead of returning True for
        everything.
        Returns False when the word can't be persisted (e.g. ``$HOME``
        unset); the in-memory addition still happens so the underline
        goes away for the rest of the session."""
        return self._add_global_word(word, user_dict_path())

    def add_library_word(mut self, word: String) -> Bool:
        """Learn ``word`` as a library identifier: in memory and appended
        to ``library_words_path()``. Same contract as ``add_user_word``."""
        return self._add_global_word(word, library_words_path())

    def _add_global_word(mut self, word: String, path: String) -> Bool:
        var lw = _normalize(word)
        if len(lw.as_bytes()) == 0:
            return False
        if self._has(lw):
            if not self.is_loaded():
                self._base_touch(True)
            return True  # already known — don't dup the file
        self._base_add(lw)
        self._base_touch(True)
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
            return True  # already known — don't dup the file
        _ = self.project_words.add(lw.as_bytes())
        self._project_version += 1
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
            self._base_add(w)
        self._base_touch(True)

    def check_word(self, word: String) -> Bool:
        """``True`` if ``word`` (or a stripped form) is in the dictionary.

        When the dictionary failed to load, returns ``True`` for
        everything — we'd rather show no underlines than mark every
        word as misspelled."""
        if not self.is_loaded():
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
        if self._base_has(w):
            return True
        return self.project_words.has(w.as_bytes())


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
    if not self_speller.is_loaded():
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


def _normalize(s: String) -> String:
    """Bucket-lookup key: lowercase + Latin-1 case fold + NFD→NFC compose.

    Three things happen here, all driven by examples that bit us in
    practice:

    * **Case fold** ASCII A-Z and the Latin-1 supplement (À-Ö, Ø-Þ).
      Without the second range, ``Övrigt`` (Ö = ``0xC3 0x96``) hashed
      differently from the on-disk lowercase ``övrigt``
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

    Used both at load time (when populating the sets) and at lookup
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
    set just stores them in their decomposed form, which is fine
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


def _wordlists_in(dir: String, mut out: List[_WordSource]):
    """Append every ``.txt`` wordlist in ``dir`` (one word per line, the
    shape of the bundled cspell-derived lists). A missing or empty
    directory adds nothing."""
    var entries = list_directory(dir)
    for i in range(len(entries)):
        if entries[i].endswith(".txt"):
            out.append(_WordSource(join_path(dir, entries[i]), True, False))


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
