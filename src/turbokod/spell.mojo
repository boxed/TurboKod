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

from .file_io import read_file
from .string_utils import split_lines_no_trailing


# 4096 buckets keyed by FNV-1a low bits. Bucketing keeps lookup at
# O(bucket_size) ≈ 60 string compares for the 235k-word macOS list,
# without pulling in a real hash map. Lookup is the dominant cost so
# it's worth the extra 32 KB of List headers.
comptime _N_BUCKETS = UInt32(4096)


struct Speller(Movable):
    """Lazy wordlist with case-insensitive + plural-tolerant lookup."""
    var buckets: List[List[String]]
    var loaded: Bool

    fn __init__(out self):
        self.buckets = List[List[String]]()
        for _ in range(Int(_N_BUCKETS)):
            self.buckets.append(List[String]())
        self.loaded = False

    fn load_default(mut self):
        """Try the OS-supplied wordlist locations in order. Silently
        becomes a no-op (``loaded == False``) when no list is found,
        so the editor degrades to "no spell highlights" rather than
        spurious red squiggles on every word."""
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
                return
            except:
                continue

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
