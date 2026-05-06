"""Spell checker for code comments and string literals.

Loads a wordlist (defaults to ``/usr/share/dict/words`` on macOS;
falls back to common Linux paths) into a hash-bucketed set keyed by
lowercase word. Lookup is case-insensitive and strips a few common
suffixes (``'s``, ``s``, ``es``, ``ed``, ``ing``) so plurals and
conjugations don't trigger false positives even when only the base
form is in the dictionary.

Used by the editor to overlay ``STYLE_UNDERLINE`` on misspelled words
inside comment / string highlights — code identifiers paint untouched
because we only spell-check inside those scopes.

Filtering rules in ``find_misspelled_runs``:

* Tokens are runs of ASCII letters only (``[A-Za-z]+``).
* Less than 4 letters → skipped (too noisy: "ok", "to", "of").
* All uppercase → skipped (acronyms: ``URL``, ``HTTP``).
* Internal capitals (``flushHighlights``) → skipped (identifier
  fragment that leaked into a docstring).
* Inside a longer ``[A-Za-z0-9_]`` run → skipped (``foo_bar123``
  fragments shouldn't be queried as English).
"""

from std.collections.list import List
from std.ffi import external_call

from .file_io import join_path, list_directory, read_file, stat_file, write_file
from .posix import getenv_value
from .string_utils import split_lines_no_trailing


# 4096 buckets keyed by FNV-1a low bits. Bucketing keeps lookup at
# O(bucket_size) ≈ 60 string compares for the 235k-word macOS list,
# without pulling in a real hash map. Lookup is the dominant cost so
# it's worth the extra 32 KB of List headers.
comptime _N_BUCKETS = UInt32(4096)


fn user_dict_path() -> String:
    """``~/.config/turbokod/dictionary.txt``, or ``""`` when ``$HOME``
    is unset. One word per line; appended whenever the user picks
    "Add to user dictionary" on a misspelled word."""
    var home = getenv_value(String("HOME"))
    if len(home.as_bytes()) == 0:
        return String("")
    return home + String("/.config/turbokod/dictionary.txt")


fn project_dict_path(project_root: String) -> String:
    """``<project>/.turbokod/dictionary.txt``, or ``""`` when no project
    is open. Sits beside ``targets.json`` / ``session.json`` so it gets
    picked up by the same ``.turbokod/`` directory the user already has
    in version control (or .gitignore)."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    return project_root + String("/.turbokod/dictionary.txt")


fn _ensure_parent_dir(path: String):
    """Best-effort ``mkdir`` of every prefix of ``path`` up to (but not
    including) the file. Mirrors ``config._ensure_dir`` but walks each
    slash so a fresh ``~/.config/turbokod`` or ``<project>/.turbokod``
    gets created before the first write."""
    var b = path.as_bytes()
    var n = len(b)
    if n == 0:
        return
    var i = 1
    while i < n:
        if b[i] == 0x2F:  # '/'
            var prefix = String(StringSlice(unsafe_from_utf8=b[0:i]))
            if len(prefix.as_bytes()) > 0:
                var c_path = prefix + String("\0")
                _ = external_call["mkdir", Int32](
                    c_path.unsafe_ptr(), Int32(0o755),
                )
        i += 1


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


fn _append_to_file(path: String, line: String) -> Bool:
    """Append ``line + \\n`` to ``path``, creating it (and any missing
    parent directories) if needed. Read-modify-write rather than
    ``O_APPEND`` because the rest of the codebase only knows how to
    truncate-write (``creat`` + ``write_bytes``); the dictionary file
    stays small enough that this is a non-issue.

    Returns False on write failure or empty path."""
    if len(path.as_bytes()) == 0:
        return False
    _ensure_parent_dir(path)
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
    # Path of the project dictionary currently in ``project_buckets``;
    # empty means "no project loaded." Tracked so ``set_project`` can
    # short-circuit re-load when the project hasn't actually changed.
    var project_root: String

    fn __init__(out self):
        self.buckets = List[List[String]]()
        for _ in range(Int(_N_BUCKETS)):
            self.buckets.append(List[String]())
        self.project_buckets = List[List[String]]()
        for _ in range(Int(_N_BUCKETS)):
            self.project_buckets.append(List[String]())
        self.loaded = False
        self.project_root = String("")

    fn load_default(mut self):
        """Try the OS-supplied wordlist locations in order, then layer
        the user dictionary on top. Silently becomes a no-op
        (``loaded == False``) when no OS list is found, so the editor
        degrades to "no spell highlights" rather than spurious red
        squiggles on every word.

        The user dictionary is loaded *after* the OS list so additions
        reach ``buckets`` even when the OS list fails. In that case
        ``loaded`` flips to True iff the user dict had at least one
        entry; lookup will then flag everything else as misspelled,
        which is the right behavior — the user explicitly chose what
        was correct."""
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
        var udp = user_dict_path()
        if len(udp.as_bytes()) > 0:
            try:
                var content = read_file(udp)
                if len(content.as_bytes()) > 0:
                    var lines = split_lines_no_trailing(content)
                    self._load_words(lines)
            except:
                pass

    fn set_project(mut self, project_root: String):
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
        if project_root == self.project_root:
            return
        for i in range(len(self.project_buckets)):
            self.project_buckets[i] = List[String]()
        self.project_root = project_root
        if len(project_root.as_bytes()) == 0:
            return
        var path = project_dict_path(project_root)
        if len(path.as_bytes()) > 0:
            try:
                var content = read_file(path)
                if len(content.as_bytes()) > 0:
                    var lines = split_lines_no_trailing(content)
                    self._load_project_words(lines)
            except:
                pass
        self._load_idea_dictionaries(project_root)

    fn _load_idea_dictionaries(mut self, project_root: String):
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
            if not _has_xml_suffix(name):
                continue
            var path = join_path(dict_dir, name)
            try:
                var content = read_file(path)
                _parse_idea_dict_words(content, words)
            except:
                continue
        if len(words) > 0:
            self._load_project_words(words)

    fn _load_project_words(mut self, words: List[String]):
        for i in range(len(words)):
            var w = _lower(words[i])
            if len(w.as_bytes()) == 0:
                continue
            var b = _bucket(w)
            self.project_buckets[b].append(w^)

    fn add_user_word(mut self, word: String) -> Bool:
        """Add ``word`` to the user dictionary in memory and on disk.

        In-memory addition flips ``loaded`` to True even on systems
        without an OS wordlist — the user explicitly trained the
        speller, so subsequent ``check_word`` calls should consult the
        bucket they just put a word into instead of returning True for
        everything.
        Returns False when the word can't be persisted (e.g. ``$HOME``
        unset); the in-memory addition still happens so the underline
        goes away for the rest of the session."""
        var lw = _lower(word)
        if len(lw.as_bytes()) == 0:
            return False
        var b = _bucket(lw)
        self.buckets[b].append(lw)
        self.loaded = True
        var path = user_dict_path()
        if len(path.as_bytes()) == 0:
            return False
        return _append_to_file(path, lw)

    fn add_project_word(mut self, word: String) -> Bool:
        """Add ``word`` to the project dictionary in memory and on disk.

        No-op (returns False) when no project is open — the host should
        gate the menu item so this can't be reached. We don't fall back
        to the user dictionary because the two are semantically
        different ("everyone on this codebase considers this spelled
        right" vs "I, the user, consider this spelled right")."""
        if len(self.project_root.as_bytes()) == 0:
            return False
        var lw = _lower(word)
        if len(lw.as_bytes()) == 0:
            return False
        var b = _bucket(lw)
        self.project_buckets[b].append(lw)
        var path = project_dict_path(self.project_root)
        if len(path.as_bytes()) == 0:
            return False
        return _append_to_file(path, lw)

    fn load_words(mut self, words: List[String]):
        """Test seam: bypass the OS wordlist and load an explicit small
        dictionary. Tests use this so they don't depend on whichever
        ``/usr/share/dict/words`` happens to ship with the host."""
        self._load_words(words)

    fn _load_words(mut self, words: List[String]):
        for i in range(len(words)):
            var w = _lower(words[i])
            if len(w.as_bytes()) == 0:
                continue
            var b = _bucket(w)
            self.buckets[b].append(w^)
        self.loaded = True

    fn check_word(self, word: String) -> Bool:
        """``True`` if ``word`` (or a stripped form) is in the dictionary.

        When the dictionary failed to load, returns ``True`` for
        everything — we'd rather show no underlines than mark every
        word as misspelled."""
        if not self.loaded:
            return True
        var lw = _lower(word)
        if self._has(lw):
            return True
        var b = lw.as_bytes()
        var n = len(b)
        # Possessive: foo's -> foo
        if n >= 3 and b[n - 2] == 0x27 and b[n - 1] == 0x73:
            if self._has(_slice(lw, 0, n - 2)):
                return True
        # Plural: foos -> foo, dishes -> dish
        if n >= 4 and b[n - 1] == 0x73:
            if self._has(_slice(lw, 0, n - 1)):
                return True
            if n >= 5 and b[n - 2] == 0x65:
                if self._has(_slice(lw, 0, n - 2)):
                    return True
        # Past tense: walked -> walk, loved -> love
        if n >= 5 and b[n - 2] == 0x65 and b[n - 1] == 0x64:
            if self._has(_slice(lw, 0, n - 2)):
                return True
            if self._has(_slice(lw, 0, n - 1)):
                return True
        # Gerund: walking -> walk, loving -> love
        if n >= 6 and b[n - 3] == 0x69 and b[n - 2] == 0x6E and b[n - 1] == 0x67:
            if self._has(_slice(lw, 0, n - 3)):
                return True
            if self._has(_slice(lw, 0, n - 3) + String("e")):
                return True
        return False

    fn _has(self, w: String) -> Bool:
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


fn find_misspelled_runs(
    self_speller: Speller, text: String,
) -> List[Tuple[Int, Int]]:
    """Return ``(byte_start, byte_end)`` pairs for misspelled words in
    ``text``. Filtering rules are described in the module docstring.

    Operates on a single text region (one comment / string highlight)
    rather than the whole buffer, so byte offsets are local to the
    given slice; the caller adds the region's row + col_start to
    place the underline.
    """
    var out = List[Tuple[Int, Int]]()
    if not self_speller.loaded:
        return out^
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        # Identifier-ish run: letters with embedded digits / underscores.
        # We swallow the whole run so a word like ``foo123`` doesn't
        # produce a clean ``foo`` lookup (it's part of a token, not
        # English prose).
        if _is_letter(c) or _is_digit(c) or c == 0x5F:
            var run_start = i
            var letters_only = True
            while i < n:
                var d = b[i]
                if _is_letter(d):
                    pass
                elif _is_digit(d) or d == 0x5F:
                    letters_only = False
                else:
                    break
                i += 1
            if not letters_only:
                continue
            # Pure-letter run. Apply word-shape filters.
            var word_end = i
            var word_len = word_end - run_start
            if word_len < 4:
                continue
            var has_lower = False
            var has_internal_upper = False
            for j in range(run_start, word_end):
                var ch = b[j]
                if ch >= 0x61 and ch <= 0x7A:
                    has_lower = True
                elif ch >= 0x41 and ch <= 0x5A:
                    if j > run_start:
                        has_internal_upper = True
            if not has_lower:
                continue
            if has_internal_upper:
                continue
            var word = _slice(text, run_start, word_end)
            if not self_speller.check_word(word):
                out.append((run_start, word_end))
        else:
            i += 1
    return out^


fn _bucket(w: String) -> Int:
    var b = w.as_bytes()
    var h = UInt32(2166136261)
    for i in range(len(b)):
        h = (h ^ UInt32(b[i])) * UInt32(16777619)
    return Int(h % _N_BUCKETS)


fn _lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        var c = b[i]
        if c >= 0x41 and c <= 0x5A:
            out.append(c + 0x20)
        else:
            out.append(c)
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))


fn _slice(s: String, start: Int, end: Int) -> String:
    var b = s.as_bytes()
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


fn _is_letter(c: UInt8) -> Bool:
    return (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)


fn _is_digit(c: UInt8) -> Bool:
    return c >= 0x30 and c <= 0x39


fn _has_xml_suffix(name: String) -> Bool:
    var b = name.as_bytes()
    var n = len(b)
    if n < 4:
        return False
    return (
        b[n - 4] == 0x2E and b[n - 3] == 0x78
        and b[n - 2] == 0x6D and b[n - 1] == 0x6C
    )


fn _parse_idea_dict_words(content: String, mut out: List[String]):
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
                out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            i += 4    # past </w>
        else:
            i += 1
