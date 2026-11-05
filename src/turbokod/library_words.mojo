"""Words the language server has ruled out as library identifiers.

The positive half — identifiers that resolved to a library — is a plain
word list loaded by the speller (``spell.library_words_path``). This is
the negative half: flagged words whose definition was the project's own,
or that no probed occurrence resolved at all, so neither the editor nor
Project ▸ Spelling asks about them again.

Per project (``<project>/.turbokod/per_user/<user>/library_negatives.txt``)
because the answer depends on what the project has installed, and with a
day stamp per word so an entry expires after ``NEGATIVE_TTL_DAYS``:
installing a package can turn a project's "no" into a library's "yes".
One ``key<TAB>day`` line per word.

A window's set is in memory and written (merged with what's on disk, so
two windows on one project don't drop each other's entries) at most every
``_FLUSH_MS`` and at teardown — a Project ▸ Spelling run settles
thousands of words, and rewriting the file per word would be quadratic.
"""

from std.collections.dict import Dict
from std.collections.list import List

from .file_io import make_parent_dirs, read_file, stat_file, write_file
from .per_user_store import per_user_path
from .posix import monotonic_ms, wall_clock_ms
from .string_utils import parse_int_prefix, split_lines_no_trailing


comptime NEGATIVE_TTL_DAYS = 30
comptime _FLUSH_MS = 2000


def _today() -> Int:
    return wall_clock_ms() // 86_400_000


def library_negatives_path(project_root: String) -> String:
    return per_user_path(project_root, String("library_negatives.txt"))


def _parse_into(content: String, mut out: Dict[String, Int]):
    """Merge ``key<TAB>day`` lines into ``out``, keeping the later day."""
    var lines = split_lines_no_trailing(content)
    for i in range(len(lines)):
        var parts = lines[i].split("\t")
        if len(parts) != 2 or len(parts[0].as_bytes()) == 0:
            continue
        var key = String(parts[0])
        var ds = String(parts[1])
        var day = parse_int_prefix(ds, 0, len(ds.as_bytes()))
        if day < 0:
            continue
        if day < out.get(key, -1):
            continue
        out[key] = day


struct LibraryNegatives(Movable):
    var project_root: String
    var _days: Dict[String, Int]
    var _dirty: Bool
    var _flushed_ms: Int

    def __init__(out self):
        self.project_root = String("")
        self._days = Dict[String, Int]()
        self._dirty = False
        self._flushed_ms = 0

    def set_project(mut self, project_root: String):
        """Write out the current project's set and load ``project_root``'s
        (none for ``""``)."""
        if project_root == self.project_root:
            return
        self.flush()
        self.project_root = project_root
        self._days = Dict[String, Int]()
        self._dirty = False
        var path = library_negatives_path(project_root)
        if len(path.as_bytes()) == 0 or not stat_file(path).ok:
            return
        try:
            _parse_into(read_file(path), self._days)
        except e:
            print("library_words: load", path, ":", String(e))

    def contains(self, key: String) -> Bool:
        """``key`` was ruled out within the last ``NEGATIVE_TTL_DAYS``."""
        var day = self._days.get(key, -1)
        return day >= 0 and _today() - day < NEGATIVE_TTL_DAYS

    def add(mut self, key: String):
        if len(self.project_root.as_bytes()) == 0 or len(key.as_bytes()) == 0:
            return
        self._days[key] = _today()
        self._dirty = True

    def tick(mut self):
        """Write pending entries if the last write was a while ago."""
        if self._dirty and monotonic_ms() - self._flushed_ms >= _FLUSH_MS:
            self.flush()

    def flush(mut self):
        """Write pending entries now, merged with the file's."""
        if not self._dirty:
            return
        self._dirty = False
        self._flushed_ms = monotonic_ms()
        var path = library_negatives_path(self.project_root)
        if len(path.as_bytes()) == 0:
            return
        var merged = Dict[String, Int]()
        if stat_file(path).ok:
            try:
                _parse_into(read_file(path), merged)
            except:
                pass
        for e in self._days.items():
            if e.value >= merged.get(e.key, -1):
                merged[e.key] = e.value
        var today = _today()
        var out = String("")
        for e in merged.items():
            if today - e.value < NEGATIVE_TTL_DAYS:
                out += e.key + String("\t") + String(e.value) + String("\n")
        make_parent_dirs(path)
        _ = write_file(path, out)
