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

from .dictionary_install import user_dictionaries_root
from .file_io import join_path, list_directory, read_file, stat_file, write_file
from .posix import getenv_value
from .string_utils import (
    codepoint_at, is_word_codepoint, split_lines_no_trailing, word_char_step,
)


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
        """Layer five word sources, in order, into ``buckets``:

        1. The OS-supplied wordlist (``/usr/share/dict/words`` and
           friends) — broad English vocabulary.
        2. The bundled programmer wordlists under
           ``src/turbokod/data/wordlists/`` (vendored from
           ``streetsidesoftware/cspell-dicts``, MIT) — software terms
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
            except:
                pass

    fn reload(mut self):
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
        self.load_default()

    fn _load_user_language_dictionaries(mut self):
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
            if not _has_txt_suffix(name):
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

    fn _load_bundled_wordlists(mut self):
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
            if not _has_txt_suffix(name):
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
            var w = _normalize(words[i])
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
        var lw = _normalize(word)
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
        var lw = _normalize(word)
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
            var w = _normalize(words[i])
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
        var lw = _normalize(word)
        if self._has(lw):
            return True
        var b = lw.as_bytes()
        var n = len(b)
        # Possessive / contracted "is": foo's -> foo (also covers it's, he's).
        if n >= 3 and b[n - 2] == 0x27 and b[n - 1] == 0x73:
            if self._has(_slice(lw, 0, n - 2)):
                return True
        # Negative contraction "n't": hasn't -> has, wouldn't -> would,
        # didn't -> did. Most English negative contractions follow this
        # pattern; the few that don't (won't, shan't, ain't) fall through
        # to the "'t" stripper below or to the user dictionary.
        if n >= 5 and b[n - 3] == 0x6E and b[n - 2] == 0x27 and b[n - 1] == 0x74:
            if self._has(_slice(lw, 0, n - 3)):
                return True
        # Bare "'t" contraction: can't -> can, won't -> won. Tighter
        # than n't because two-letter heads (ai't, sh't) are noise.
        if n >= 5 and b[n - 2] == 0x27 and b[n - 1] == 0x74:
            if self._has(_slice(lw, 0, n - 2)):
                return True
        # "'re": they're -> they, you're -> you.
        if n >= 5 and b[n - 3] == 0x27 and b[n - 2] == 0x72 and b[n - 1] == 0x65:
            if self._has(_slice(lw, 0, n - 3)):
                return True
        # "'ve": they've -> they, would've -> would.
        if n >= 5 and b[n - 3] == 0x27 and b[n - 2] == 0x76 and b[n - 1] == 0x65:
            if self._has(_slice(lw, 0, n - 3)):
                return True
        # "'ll": they'll -> they, you'll -> you.
        if n >= 5 and b[n - 3] == 0x27 and b[n - 2] == 0x6C and b[n - 1] == 0x6C:
            if self._has(_slice(lw, 0, n - 3)):
                return True
        # "'d": they'd -> they, would'd... rare but cheap to support.
        if n >= 5 and b[n - 2] == 0x27 and b[n - 1] == 0x64:
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
        var step = word_char_step(text, i)
        if step[0] or _is_digit(c) or c == 0x5F:
            var run_start = i
            var letters_only = True
            while i < n:
                var d = b[i]
                if _is_digit(d) or d == 0x5F:
                    letters_only = False
                    i += 1
                elif (
                    d == 0x27
                    and i > run_start and _is_letter(b[i - 1])
                    and i + 1 < n and _is_letter(b[i + 1])
                ):
                    # Apostrophe between two ASCII letters — part of a
                    # contraction or possessive (it's, hasn't, Bob's).
                    # Keep it in the run so check_word's contraction
                    # strippers can fire; without this, "hasn't"
                    # tokenizes as ["hasn", "t"] and the head ("hasn")
                    # is flagged as a misspelling.
                    i += 1
                else:
                    var s = word_char_step(text, i)
                    if s[0]:
                        # Letter (ASCII or Unicode). Walks by UTF-8
                        # codepoint so non-ASCII letters (``ä``, Cyrillic,
                        # CJK) join the run instead of breaking it.
                        i += s[1]
                    else:
                        break
            if not letters_only:
                continue
            # Pure-letter run (possibly with internal apostrophes). Apply
            # word-shape filters. Counts use the raw byte length, which
            # includes the apostrophe — fine because apostrophe-containing
            # words (it's, hasn't) are at least 4 chars by construction.
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


fn has_spell_noinspection_directive(text: String) -> Bool:
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
        var ok_left = i == 0 or not _is_ident_byte(b[i - 1])
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
                var token = _slice(text, t_start, p)
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


fn _is_ident_byte(c: UInt8) -> Bool:
    return (
        (c >= 0x41 and c <= 0x5A)
        or (c >= 0x61 and c <= 0x7A)
        or (c >= 0x30 and c <= 0x39)
        or c == 0x5F
    )


fn _bucket(w: String) -> Int:
    var b = w.as_bytes()
    var h = UInt32(2166136261)
    for i in range(len(b)):
        h = (h ^ UInt32(b[i])) * UInt32(16777619)
    return Int(h % _N_BUCKETS)


fn _normalize(s: String) -> String:
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
                _emit_utf8(out, combined)
                i = next_i + next_step[1]
                continue
        _emit_utf8(out, lower_cp)
        i += sz
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))


fn _lower_codepoint(cp: Int) -> Int:
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


fn _compose_diacritic(base: Int, mark: Int) -> Int:
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


fn _emit_utf8(mut out: List[UInt8], cp: Int):
    """Append ``cp``'s UTF-8 encoding to ``out``. Handles the full
    1- to 4-byte range so any normalized codepoint round-trips
    cleanly. Negative / oversized inputs are clamped to ``?``
    rather than emitted as malformed UTF-8."""
    if cp < 0 or cp > 0x10FFFF:
        out.append(UInt8(0x3F))
        return
    if cp < 0x80:
        out.append(UInt8(cp))
        return
    if cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
        return
    if cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
        return
    out.append(UInt8(0xF0 | (cp >> 18)))
    out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
    out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
    out.append(UInt8(0x80 | (cp & 0x3F)))


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


fn _has_txt_suffix(name: String) -> Bool:
    var b = name.as_bytes()
    var n = len(b)
    if n < 4:
        return False
    return (
        b[n - 4] == 0x2E and b[n - 3] == 0x74
        and b[n - 2] == 0x78 and b[n - 1] == 0x74
    )


fn _strip_word(line: String) -> String:
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
    return String(StringSlice(unsafe_from_utf8=b[i:j]))


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
