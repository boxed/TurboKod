"""Spell checking a whole buffer, and a whole project.

``misspelled_spans`` runs ``find_misspelled_runs`` over every line,
minus rows an IntelliJ ``noinspection`` directive covers. It's what the
editor squiggles and what ``ProjectSpellScan`` counts, so Project ▸
Spelling lists exactly the words the editor underlines. Neither looks
at syntax highlighting: identifiers are checked like prose, split at
underscores, digits and camelCase boundaries.

``ProjectSpellScan`` does that for every project file behind Project ▸
Spelling, stepped from the frame loop against a time budget so the UI
thread is never held longer than one slice.

It is deliberately single-threaded. A ``TaskGroup`` version ran 6× faster
in a standalone binary and crashed the app: Mojo's async runtime is set
up by a Mojo ``main``, and the native app and ``tk-tui`` load the core as
a library from a host that has none, so the first task dereferenced an
uninitialized runtime. Without syntax highlighting the scan is cheap
enough not to need threads.
"""

from std.collections.list import List

from .case_fold import fold_ascii
from .file_io import read_file, stat_file
from .highlight import extension_of
from .posix import monotonic_ms
from .project import walk_project_files
from .spell import (
    Speller, find_misspelled_runs, has_spell_noinspection_directive,
    spell_key,
)
from std.collections.optional import Optional
from .string_utils import split_lines_no_trailing


comptime SPELL_SCAN_MAX_FILE_BYTES = 2_000_000
"""Files larger than this aren't scanned. Matches the editor's
big-buffer rule, under which such a file isn't spell-checked either."""

comptime SPELL_SCAN_MAX_LINE_BYTES = 5000
"""Same: a file with a line longer than this is a big buffer to the
editor (minified bundles, data dumps) and is never spell-checked."""

comptime _N_BUCKETS = UInt32(4096)



def misspelled_spans(
    lines: List[String], speller: Speller,
) -> List[Tuple[Int, Int, Int]]:
    """``(row, start, end)`` byte spans of every misspelled word in
    ``lines``.

    A line carrying a ``noinspection`` directive suppresses itself and
    the next line, mirroring IntelliJ's "applies to the next element"."""
    var out = List[Tuple[Int, Int, Int]]()
    if not speller.loaded:
        return out^
    var suppress_next = False
    for row in range(len(lines)):
        var suppressed = suppress_next
        suppress_next = False
        if has_spell_noinspection_directive(lines[row]):
            suppressed = True
            suppress_next = True
        if suppressed:
            continue
        var runs = find_misspelled_runs(speller, lines[row])
        for r in range(len(runs)):
            out.append((row, runs[r][0], runs[r][1]))
    return out^


@fieldwise_init
struct SpellScanWord(ImplicitlyCopyable, Movable):
    """One distinct flagged word and how often the scan saw it."""
    var word: String
    """The spelling first seen — what the list shows."""
    var key: String
    """``spell_key`` of ``word``: case-folded, so ``Hubspot`` and
    ``hubspot`` are one row. This is what gets added to a dictionary."""
    var count: Int
    var path: String
    """Where the word was first seen (1-based ``line``)."""
    var line: Int


def _grouping_word(word: String) -> String:
    """``word`` with a trailing possessive ``'s`` dropped. The speller
    strips it on lookup, so ``Hubspot's`` and ``Hubspot`` are fixed by
    the same dictionary entry and belong in the same row."""
    var b = word.as_bytes()
    var n = len(b)
    if n >= 4 and b[n - 2] == 0x27 and (b[n - 1] == 0x73 or b[n - 1] == 0x53):
        return String(StringSpan(unsafe_from_utf8=b[0:n - 2]))
    return word


def _bucket(key: String) -> Int:
    var b = key.as_bytes()
    var h = UInt32(2166136261)
    for i in range(len(b)):
        h = (h ^ UInt32(b[i])) * UInt32(16777619)
    return Int(h % _N_BUCKETS)


def spell_scan_files(root: String) -> List[String]:
    """The files Project ▸ Spelling should read: the project's files
    (gitignored ones excluded, as everywhere) minus binaries recognized
    by extension, without opening them.

    Deliberately not ``git ls-files --eol``: git decides "binary" by
    looking for a NUL in the first 8000 bytes — the same test ``_load``
    applies — so it has to read every file, which took 3.4 s on a 7k-file
    checkout, while the extension list already caught 99% of what git
    flagged there. The sniff in ``_load`` covers the rest."""
    var files = walk_project_files(root)
    var out = List[String]()
    for i in range(len(files)):
        if not _in_binary_path(files[i], len(root.as_bytes())):
            out.append(files[i])
    return out^


def _in_binary_path(path: String, root_len: Int) -> Bool:
    """True when ``path`` — or a directory on it below the project root
    (the first ``root_len`` bytes), as with document bundles like
    ``Design.pxd/data/…`` — has a binary file extension."""
    var b = path.as_bytes()
    var seg = min(root_len, len(b))
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == 0x2F:
            if i > seg and _is_binary_name(
                String(StringSpan(unsafe_from_utf8=b[seg:i])),
            ):
                return True
            seg = i + 1
    return False


def _is_binary_name(name: String) -> Bool:
    var ext = fold_ascii(extension_of(name))
    if len(ext.as_bytes()) == 0:
        return False
    for e in [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp", "tif",
        "tiff", "heic", "avif", "psd", "pxd", "sketch", "fig", "dng", "raw",
        "cr2", "nef", "arw",
        "pdf", "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar",
        "jar", "war", "whl", "egg", "dmg", "iso", "pkg", "deb", "rpm",
        "exe", "dll", "so", "dylib", "a", "o", "obj", "lib", "bin", "class",
        "pyc", "pyo", "wasm", "mojopkg",
        "mp3", "mp4", "m4a", "m4v", "mov", "avi", "mkv", "webm", "wav",
        "flac", "ogg", "aac",
        "ttf", "otf", "woff", "woff2", "eot",
        "sqlite", "sqlite3", "db", "dump", "pickle", "pkl", "npy", "npz",
        "parquet", "xls", "xlsx", "doc", "docx", "ppt", "pptx", "key",
        "numbers", "pages",
    ]:
        if ext == e:
            return True
    return False


def _load_lines(path: String) -> Optional[List[String]]:
    """``path``'s lines, or ``None`` for a file the editor wouldn't
    spell-check either: unreadable, binary, or a big buffer."""
    var text: String
    try:
        text = read_file(path)
    except:
        return Optional[List[String]]()
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > SPELL_SCAN_MAX_FILE_BYTES:
        return Optional[List[String]]()
    for i in range(min(len(b), 8192)):
        if b[i] == 0:
            return Optional[List[String]]()
    var lines = split_lines_no_trailing(text)
    for i in range(len(lines)):
        if len(lines[i].as_bytes()) > SPELL_SCAN_MAX_LINE_BYTES:
            return Optional[List[String]]()
    return Optional[List[String]](lines^)


struct ProjectSpellScan(Movable):
    """Spell-check every file of a project, a time slice per ``step``.

    ``words`` accumulates one entry per distinct flagged word; ``version``
    bumps whenever it changes so a view can re-sort only when needed.
    The scan reads files from disk — unsaved buffer text isn't seen."""
    var files: List[String]
    """Largest first — see ``start``."""
    var sizes: List[Int]
    var files_done: Int
    """Files finished, checked or skipped."""
    var bytes_done: Int
    var bytes_total: Int
    var files_checked: Int
    """Files actually spell-checked (skipped binaries / big files excluded)."""
    var active: Bool
    var words: List[SpellScanWord]
    var version: Int
    var _buckets: List[List[Int]]

    def __init__(out self):
        self.files = List[String]()
        self.sizes = List[Int]()
        self.files_done = 0
        self.bytes_done = 0
        self.bytes_total = 0
        self.files_checked = 0
        self.active = False
        self.words = List[SpellScanWord]()
        self.version = 0
        self._buckets = List[List[Int]]()
        for _ in range(Int(_N_BUCKETS)):
            self._buckets.append(List[Int]())

    def start(mut self, var files: List[String]):
        """Forget any previous result and begin scanning ``files``.

        Files are scanned largest first and progress is counted in
        bytes, so the bar moves in step with the work rather than
        crawling through the big files and then jumping."""
        var sizes = List[Int](capacity=len(files))
        for i in range(len(files)):
            var info = stat_file(files[i])
            sizes.append(Int(info.size) if info.ok else 0)
        _sort_by_size_desc(files, sizes)
        self.bytes_total = 0
        for i in range(len(sizes)):
            self.bytes_total += sizes[i]
        self.bytes_done = 0
        self.files = files^
        self.sizes = sizes^
        self.files_done = 0
        self.files_checked = 0
        self.active = True
        self.words = List[SpellScanWord]()
        self.version += 1
        for i in range(len(self._buckets)):
            self._buckets[i] = List[Int]()

    def cancel(mut self):
        """Stop. Idempotent."""
        self.active = False

    def progress(self) -> Float64:
        """Fraction of the project's bytes finished, 0..1."""
        if self.bytes_total <= 0:
            return 1.0 if not self.active else 0.0
        return min(Float64(self.bytes_done) / Float64(self.bytes_total), 1.0)

    def step(mut self, budget_ms: Int, speller: Speller) -> Bool:
        """Check files until ``budget_ms`` from now. True while work
        remains. A file is checked whole — at most 2 MB, a few ms."""
        if not self.active:
            return False
        var deadline = monotonic_ms() + budget_ms
        # Check the clock after each file, not before, so every step
        # makes progress however small the budget.
        while self.files_done < len(self.files):
            var f = self.files_done
            self.files_done += 1
            self.bytes_done += self.sizes[f]
            var path = self.files[f]
            var lines = _load_lines(path)
            if not lines:
                if monotonic_ms() >= deadline:
                    break
                continue
            ref ls = lines.value()
            var spans = misspelled_spans(ls, speller)
            for i in range(len(spans)):
                var lb = ls[spans[i][0]].as_bytes()
                self._record(
                    String(StringSpan(
                        unsafe_from_utf8=lb[spans[i][1]:spans[i][2]],
                    )),
                    path, spans[i][0] + 1,
                )
            self.files_checked += 1
            if monotonic_ms() >= deadline:
                break
        if self.files_done >= len(self.files):
            self.active = False
            return False
        return True

    def remove_keys(mut self, keys: List[String]):
        """Drop the rows for ``keys`` — they were just added to a
        dictionary, so they no longer misspell. Later occurrences are
        already filtered by the speller itself."""
        var kept = List[SpellScanWord]()
        for i in range(len(self.words)):
            var drop = False
            for k in range(len(keys)):
                if self.words[i].key == keys[k]:
                    drop = True
                    break
            if not drop:
                kept.append(self.words[i])
        self.words = kept^
        for i in range(len(self._buckets)):
            self._buckets[i] = List[Int]()
        for i in range(len(self.words)):
            self._buckets[_bucket(self.words[i].key)].append(i)
        self.version += 1

    def _record(mut self, word: String, path: String, line: Int):
        var shown = _grouping_word(word)
        var key = spell_key(shown)
        var b = _bucket(key)
        for i in range(len(self._buckets[b])):
            var idx = self._buckets[b][i]
            if self.words[idx].key == key:
                self.words[idx].count += 1
                self.version += 1
                return
        self._buckets[b].append(len(self.words))
        self.words.append(SpellScanWord(shown, key, 1, path, line))
        self.version += 1


def _sort_by_size_desc(mut files: List[String], mut sizes: List[Int]):
    """Reorder ``files`` / ``sizes`` (parallel lists) largest first.
    Bottom-up merge sort over an index permutation."""
    var n = len(files)
    if n < 2:
        return
    var idx = List[Int](capacity=n)
    var buf = List[Int](capacity=n)
    for i in range(n):
        idx.append(i)
        buf.append(i)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if sizes[idx[j]] > sizes[idx[i]]:
                    buf[k] = idx[j]
                    j += 1
                else:
                    buf[k] = idx[i]
                    i += 1
                k += 1
            while i < mid:
                buf[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                buf[k] = idx[j]
                j += 1
                k += 1
            lo += 2 * width
        for t in range(n):
            idx[t] = buf[t]
        width *= 2
    var f2 = List[String](capacity=n)
    var s2 = List[Int](capacity=n)
    for t in range(n):
        f2.append(files[idx[t]])
        s2.append(sizes[idx[t]])
    files = f2^
    sizes = s2^
