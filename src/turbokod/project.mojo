"""Project-wide file walking, searching, and replacement.

Operates on the directory returned by ``find_git_project``; consumers don't
need to know whether it's a Git checkout or just a parent of ``.git``. We
always skip the ``.git`` directory and any file whose first 4 KB contains a
NUL byte (treated as binary). Everything else — including dotfiles like
``.gitignore`` — is included unless ``.gitignore`` excludes it.
"""

from std.collections.list import List

from std.collections.optional import Optional

from .file_io import (
    join_path, list_directory, read_file, stat_file, write_file,
)
from .lsp import LspProcess, capture_command
from .onig import OnigRegex
from .posix import (
    SIGTERM, alloc_zero_buffer, kill_pid, poll_stdin, read_into, waitpid_nohang,
)
from .search_options import (
    SearchOptions, build_search_regex, default_search_options,
)
from .string_utils import split_lines_no_trailing


@fieldwise_init
struct ProjectMatch(ImplicitlyCopyable, Movable):
    var path: String        # absolute path to the file
    var rel: String         # path relative to project root, for display
    var line_no: Int        # 1-based line number of the match
    var line_text: String


# --- .gitignore matching ---------------------------------------------------


@fieldwise_init
struct GitignorePattern(ImplicitlyCopyable, Movable):
    """A single gitignore line broken into its semantic parts.

    ``glob`` carries the body of the pattern minus any leading ``!`` (kept as
    ``negate``), leading ``/`` (kept as ``anchored``), and trailing ``/``
    (kept as ``dir_only``). Glob characters supported: ``*`` (any non-slash
    run, including empty) and ``?`` (any single non-slash byte). Character
    classes (``[abc]``) and ``**`` aren't recognized — that's a deliberate
    practical subset, not the full git semantics.
    """
    var glob: String
    var dir_only: Bool
    var anchored: Bool
    var negate: Bool


struct GitignoreMatcher(Copyable, Movable):
    """Compiled set of gitignore patterns from a single ``.gitignore`` file.

    Match order follows git: later patterns override earlier ones, and a
    leading ``!`` re-includes a path that an earlier pattern excluded.
    """
    var patterns: List[GitignorePattern]

    def __init__(out self):
        self.patterns = List[GitignorePattern]()

    def __copyinit__(mut self, copy: Self):
        self.patterns = copy.patterns.copy()

    @staticmethod
    def from_text(text: String) -> Self:
        var m = GitignoreMatcher()
        var lines = split_lines_no_trailing(text)
        for li in range(len(lines)):
            var line = _strip(lines[li])
            var lb = line.as_bytes()
            if len(lb) == 0:
                continue
            if lb[0] == 0x23:  # '#'
                continue
            var negate = False
            var start = 0
            if lb[0] == 0x21:  # '!'
                negate = True
                start = 1
            var anchored = False
            if start < len(lb) and lb[start] == 0x2F:  # '/'
                anchored = True
                start += 1
            var end = len(lb)
            var dir_only = False
            if end > start and lb[end - 1] == 0x2F:
                dir_only = True
                end -= 1
            if end <= start:
                continue
            var glob = String(StringSlice(unsafe_from_utf8=lb[start:end]))
            m.patterns.append(GitignorePattern(glob, dir_only, anchored, negate))
        return m^

    def ignored(self, rel_path: String, is_dir: Bool) -> Bool:
        """Is ``rel_path`` (relative to the gitignore's directory) ignored?

        ``rel_path`` should use ``/`` separators and not start with ``/``.
        """
        var result = False
        for i in range(len(self.patterns)):
            var p = self.patterns[i]
            if p.dir_only and not is_dir:
                continue
            if _gitignore_path_match(p, rel_path):
                result = not p.negate
        return result


def _strip(s: String) -> String:
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n and (b[i] == 0x20 or b[i] == 0x09 or b[i] == 0x0D):
        i += 1
    var j = n
    while j > i and (b[j - 1] == 0x20 or b[j - 1] == 0x09 or b[j - 1] == 0x0D):
        j -= 1
    if i == 0 and j == n:
        return s
    return String(StringSlice(unsafe_from_utf8=b[i:j]))


def _split_path_components(path: String) -> List[String]:
    var out = List[String]()
    var b = path.as_bytes()
    var start = 0
    var i = 0
    while i < len(b):
        if b[i] == 0x2F:
            if i > start:
                out.append(String(StringSlice(unsafe_from_utf8=b[start:i])))
            start = i + 1
        i += 1
    if start < len(b):
        out.append(String(StringSlice(unsafe_from_utf8=b[start:])))
    return out^


def _glob_match(pattern: String, text: String) -> Bool:
    return _glob_match_at(pattern, 0, text, 0)


def _glob_match_at(pattern: String, pi: Int, text: String, ti: Int) -> Bool:
    var pb = pattern.as_bytes()
    var tb = text.as_bytes()
    var p = pi
    var t = ti
    while p < len(pb):
        var c = pb[p]
        if c == 0x2A:  # '*' — any (possibly empty) run of non-slash bytes.
            while p < len(pb) and pb[p] == 0x2A:
                p += 1
            if p >= len(pb):
                while t < len(tb):
                    if tb[t] == 0x2F:
                        return False
                    t += 1
                return True
            while t <= len(tb):
                if _glob_match_at(pattern, p, text, t):
                    return True
                if t == len(tb):
                    return False
                if tb[t] == 0x2F:
                    return False
                t += 1
            return False
        if c == 0x3F:  # '?'
            if t >= len(tb) or tb[t] == 0x2F:
                return False
            p += 1
            t += 1
            continue
        if t >= len(tb) or tb[t] != c:
            return False
        p += 1
        t += 1
    return t == len(tb)


def _has_byte(s: String, b: UInt8) -> Bool:
    var bs = s.as_bytes()
    for i in range(len(bs)):
        if bs[i] == b:
            return True
    return False


def _gitignore_path_match(p: GitignorePattern, rel: String) -> Bool:
    if p.anchored:
        return _glob_match(p.glob, rel)
    var glob_has_slash = _has_byte(p.glob, 0x2F)
    if not glob_has_slash:
        # Match any single path component.
        var comps = _split_path_components(rel)
        for i in range(len(comps)):
            if _glob_match(p.glob, comps[i]):
                return True
        return False
    # Pattern with internal slash, not anchored: match any suffix that
    # starts at a path-component boundary.
    var comps2 = _split_path_components(rel)
    for s in range(len(comps2)):
        var suffix = comps2[s]
        for j in range(s + 1, len(comps2)):
            suffix = suffix + String("/") + comps2[j]
        if _glob_match(p.glob, suffix):
            return True
    return False


def load_project_gitignore(root: String) -> GitignoreMatcher:
    var path = join_path(root, String(".gitignore"))
    var info = stat_file(path)
    if not info.ok:
        return GitignoreMatcher()
    var text: String
    try:
        text = read_file(path)
    except:
        return GitignoreMatcher()
    return GitignoreMatcher.from_text(text)


# Directory names we never descend into for the picker, regardless of
# what ``.gitignore`` says. These are universally tool-generated caches /
# dependency stores whose contents drown out real source files and bog
# down the walk by orders of magnitude. A project that legitimately
# wants to expose one of these (e.g. for some weird tooling) needs a
# different code path — this list is for the quick-open picker only.
def _picker_skip_dirs() -> List[String]:
    var s = List[String]()
    s.append(String("__pycache__"))
    s.append(String("node_modules"))
    s.append(String(".venv"))
    s.append(String("venv"))
    s.append(String(".tox"))
    s.append(String(".mypy_cache"))
    s.append(String(".pytest_cache"))
    s.append(String(".ruff_cache"))
    s.append(String(".next"))
    s.append(String(".svelte-kit"))
    return s^


def _name_in(name: String, names: List[String]) -> Bool:
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def _git_ls_files_argv(root: String, ignored_only: Bool) -> List[String]:
    """Argv for the two ``git ls-files`` enumerations the picker uses.

    ``ignored_only=False`` → ``-co --exclude-standard``: every tracked +
    untracked-not-ignored file. ``ignored_only=True`` → ``-oi
    --exclude-standard --directory``: untracked files that the ignore
    rules exclude — and crucially, ``--directory`` collapses a
    fully-ignored directory to a single ``dir/`` entry instead of
    enumerating its contents, so ``node_modules`` / ``venv`` don't flood
    the output while an individually-ignored file like
    ``settings_local.py`` or ``.env`` still appears as a plain path.
    Callers drop the trailing-slash directory entries.
    """
    var argv = List[String]()
    argv.append(String("git"))
    argv.append(String("-C"))
    argv.append(root)
    argv.append(String("ls-files"))
    if ignored_only:
        argv.append(String("-o"))
        argv.append(String("-i"))
        argv.append(String("--exclude-standard"))
        argv.append(String("--directory"))
    else:
        argv.append(String("-c"))
        argv.append(String("-o"))
        argv.append(String("--exclude-standard"))
    argv.append(String("-z"))
    return argv^


def _git_ls_project_files(
    root: String, ignored_only: Bool = False,
) -> Optional[List[String]]:
    """Run ``git ls-files -co --exclude-standard -z`` in ``root`` and return
    absolute paths of every tracked + untracked-not-ignored file.

    The canonical "files in this project" list — respects ``.gitignore``,
    ``.git/info/exclude``, and the user's global ``core.excludesfile``,
    which the hand-rolled matcher doesn't (the hand-rolled one only sees
    the project's own ``.gitignore``, so it misses big universal caches
    like ``.venv`` / ``__pycache__`` when those aren't in the project's
    own file). Returns ``None`` if ``root`` isn't a git checkout, ``git``
    is unavailable, or the command failed for any reason — callers fall
    back to the manual walk.

    With ``ignored_only=True`` the enumeration flips to gitignored
    untracked files instead (see ``_git_ls_files_argv``); the ``dir/``
    entries that ``--directory`` emits for wholly-ignored directories
    are dropped here, so the result is exactly the individually-ignored
    files outside those directories.

    ``-z`` uses NUL separators so paths with newlines or other oddities
    round-trip safely. Each NUL-terminated entry is appended to the
    project root (with a ``/`` separator) to produce the absolute path.
    """
    if len(root.as_bytes()) == 0:
        return Optional[List[String]]()
    var argv = _git_ls_files_argv(root, ignored_only)
    try:
        var cap = capture_command(argv)
        if Int(cap.status) != 0:
            return Optional[List[String]]()
        var out = List[String]()
        var bytes = cap.stdout.as_bytes()
        var n = len(bytes)
        var start = 0
        for i in range(n):
            if bytes[i] == 0:
                # Skip ``dir/`` entries (``--directory`` output for a
                # wholly-ignored directory) — only plain file paths pass.
                if i > start and bytes[i - 1] != 0x2F:
                    var rel = String(StringSlice(unsafe_from_utf8=bytes[start:i]))
                    out.append(join_path(root, rel))
                start = i + 1
        # No trailing NUL? Treat the tail as a final entry too.
        if start < n and bytes[n - 1] != 0x2F:
            var rel_tail = String(StringSlice(unsafe_from_utf8=bytes[start:n]))
            out.append(join_path(root, rel_tail))
        return Optional[List[String]](out^)
    except:
        return Optional[List[String]]()


# --- Async incremental file indexer ----------------------------------------


# Hard ceiling on entries we'll load into the picker. Beyond this the
# user is plausibly inside a node_modules or a monorepo with millions of
# files; the picker isn't useful at that size anyway, and showing what's
# loaded so far + an explicit "truncated" marker is more honest than a
# UI freeze trying to load everything.
comptime QUICK_OPEN_FILE_CAP = 100000


struct FileIndexer(Movable):
    """Background file enumerator for the quick-open picker.

    Spawns ``git ls-files -co --exclude-standard -z`` as a child process
    and exposes its stdout through a non-blocking pipe — the caller polls
    via ``poll()`` each frame and pops newly-discovered paths from the
    returned list. The host main thread never blocks on the walk: even
    on a giant monorepo, opening the picker is constant-time, then
    entries trickle in as git produces them. Stops at
    ``QUICK_OPEN_FILE_CAP``, signals the child to terminate, and sets
    ``truncated`` so the UI can advertise that the picker isn't seeing
    everything.

    Only works for git checkouts. ``QuickOpen.open`` falls back to the
    synchronous ``walk_project_files`` for non-git projects (which are
    typically small enough that the sync walk is fine).
    """
    var proc: LspProcess
    var alive: Bool
    var truncated: Bool
    var buf: List[UInt8]   # tail bytes from the last partial NUL chunk
    var produced: Int

    def __init__(out self, var process: LspProcess):
        self.proc = process^
        self.alive = True
        self.truncated = False
        self.buf = List[UInt8]()
        self.produced = 0

    @staticmethod
    def start(root: String, ignored_only: Bool = False) -> Optional[Self]:
        """Spawn ``git ls-files`` in ``root``. Returns ``None`` if the
        spawn failed (no ``git``, not a checkout, or any other error).

        ``ignored_only=True`` enumerates gitignored files instead of the
        tracked + untracked set (see ``_git_ls_files_argv``) — QuickOpen
        runs both in parallel so individually-ignored files like
        ``.env`` are openable without flooding the list with the
        contents of ignored directories.
        """
        if len(root.as_bytes()) == 0:
            return Optional[Self]()
        var argv = _git_ls_files_argv(root, ignored_only)
        try:
            var proc = LspProcess.spawn(argv, String(""))
            var idx = Self(proc^)
            return Optional[Self](take=idx^)
        except:
            return Optional[Self]()

    def poll(mut self, root: String) -> List[String]:
        """Read whatever the child has produced since the last call,
        parse complete NUL-terminated paths, and return them as absolute
        paths under ``root``. A partial trailing entry (no NUL yet) is
        held in ``buf`` for the next call.

        Side effects: when the count reaches ``QUICK_OPEN_FILE_CAP`` we
        signal the child with ``SIGTERM`` and set ``truncated``; when
        the child has exited and the buffer is drained, ``alive`` flips
        to False so the caller knows indexing is done.
        """
        var new_paths = List[String]()
        if not self.alive:
            return new_paths^
        # Drain everything currently in the pipe into ``self.buf``.
        # Non-blocking: ``poll_stdin(.., 0)`` returns immediately, and a
        # single ``read`` consumes up to 64 KiB. Cap at 1 MiB per tick
        # so a fast producer can't starve the main loop. We use a
        # pre-allocated scratch buffer (``alloc_zero_buffer`` gives us a
        # ``List[UInt8]`` of the requested capacity that ``read(2)`` can
        # write into directly) and copy the first ``n`` bytes into
        # ``self.buf`` — ``List.append`` only updates length, not the
        # backing capacity, so reading into an empty list overwrites
        # whatever happened to be at offset 0 of its unallocated buffer.
        var scratch = alloc_zero_buffer(65536)
        var total = 0
        var saw_eof = False
        while total < 1024 * 1024:
            if not poll_stdin(self.proc.stdout_fd, Int32(0)):
                break
            var grew = read_into(self.proc.stdout_fd, scratch, 65536)
            if grew <= 0:
                # ``read`` returning 0 is EOF: the child closed its stdout,
                # which only happens once it has written everything and is
                # exiting. That — not ``waitpid`` reporting the child gone —
                # is the real "no more data" signal: a process can write its
                # final batch into the pipe buffer and exit before we read
                # it, so keying "done" off the exit would drop whatever is
                # still buffered (the *tail* of ``git ls-files`` output —
                # e.g. ``pyproject.toml`` / ``settings.py`` near the end).
                # A negative ``grew`` is an unrecoverable read error; treat
                # it as end-of-stream too.
                saw_eof = True
                break
            for i in range(grew):
                self.buf.append(scratch[i])
            total += grew
        var start = 0
        for i in range(len(self.buf)):
            if self.buf[i] == 0:
                # ``dir/`` entries (``--directory`` output in
                # ignored-only mode) are dropped — see ``start``.
                if i > start and self.buf[i - 1] != 0x2F:
                    var rel = String(StringSlice(
                        unsafe_from_utf8=self.buf[start:i],
                    ))
                    new_paths.append(join_path(root, rel))
                    self.produced += 1
                    if self.produced >= QUICK_OPEN_FILE_CAP:
                        self.truncated = True
                        self._terminate()
                        # Trim buf so we don't keep it around.
                        self.buf = List[UInt8]()
                        return new_paths^
                start = i + 1
        # Drop consumed prefix from buf.
        if start > 0:
            var tail = List[UInt8]()
            for i in range(start, len(self.buf)):
                tail.append(self.buf[i])
            self.buf = tail^
        # Reap the child if it has already exited (best-effort, avoids a
        # lingering zombie); the shim's atexit reaper catches it otherwise.
        # Crucially this does NOT decide doneness — only EOF on the pipe
        # does. Keying "done" off ``waitpid`` here used to race: the child
        # could exit with its last NUL-terminated paths still unread in the
        # pipe, we'd flip ``alive`` to False, and the next ``poll`` would
        # early-return without ever draining them — silently dropping the
        # tail of the file list.
        var ws = waitpid_nohang(self.proc.pid)
        if Int(ws[0]) != 0:
            self.proc.alive = False
        if saw_eof:
            self.alive = False
            self.proc.alive = False
        return new_paths^

    def _terminate(mut self):
        """Best-effort SIGTERM + clear alive. The shim's atexit handler
        will SIGKILL anything still alive at process exit."""
        if self.proc.alive:
            _ = kill_pid(self.proc.pid, SIGTERM)
            self.proc.alive = False
        self.alive = False
        # Close fds so the kernel reclaims them; the LspProcess fields
        # are now defunct and shouldn't be reused.
        _ = self.proc.stdin_fd
        # Reap. waitpid_nohang in a short loop in case SIGTERM hasn't
        # delivered yet; if not done after a few tries, leave it to the
        # shim's atexit reaper.
        for _ in range(8):
            var ws = waitpid_nohang(self.proc.pid)
            if Int(ws[0]) != 0:
                return


def walk_project_files(
    root: String,
    respect_gitignore: Bool = True,
    include_ignored_files: Bool = False,
) -> List[String]:
    """Iterative DFS — absolute paths of every regular file under ``root``.

    The ``.git`` directory is always skipped (git never tracks its own
    metadata, and walking it would balloon the result by orders of
    magnitude). Other dotfiles — ``.gitignore``, ``.editorconfig``, etc. —
    are included. With ``respect_gitignore=True`` (the default) the
    project's ``.gitignore`` is parsed and any path that matches is
    excluded; an ignored *directory* skips its entire subtree.

    ``include_ignored_files=True`` keeps the directory-pruning behavior
    but stops filtering individual files — useful for the file picker,
    where user-customized configs like ``settings_local.py`` or ``.env``
    are exactly the files you want to be able to open. Ignored *dirs*
    are still pruned so the result doesn't balloon with ``node_modules``
    / ``__pycache__`` / ``venv`` content.

    Fast path: when ``respect_gitignore=True`` and ``root`` is a git
    checkout, we shell out to ``git ls-files`` instead of walking. The
    hand-rolled matcher only sees the project's own ``.gitignore`` and
    can't tell that e.g. ``.venv`` should be skipped if the file
    doesn't list it explicitly; git applies the user's global excludes
    too, so it gets pruning right on projects that rely on those. On a
    real-world Python project this dropped quick-open from ~48 s
    (169 k files) to <100 ms (~2 k files). Falls back to the manual
    walk if ``git`` isn't available or the call failed. With
    ``include_ignored_files=True`` the fast path runs a second
    ``ls-files`` pass for individually-ignored files, mirroring the
    manual walk's keep-files / prune-dirs behavior.
    """
    if respect_gitignore:
        var via_git = _git_ls_project_files(root)
        if via_git:
            var files = via_git.value().copy()
            if include_ignored_files:
                # Second enumeration for individually-ignored files
                # (``settings_local.py``, ``.env``, …). Wholly-ignored
                # directories stay pruned — see ``_git_ls_files_argv``.
                var ignored = _git_ls_project_files(root, ignored_only=True)
                if ignored:
                    for i in range(len(ignored.value())):
                        files.append(ignored.value()[i])
            return files^
    var matcher = load_project_gitignore(root) if respect_gitignore \
        else GitignoreMatcher()
    # Belt-and-suspenders for non-git projects (or git failures): never
    # descend into tool-generated caches no matter what ``.gitignore``
    # says. See ``_picker_skip_dirs`` for the rationale.
    var skip = _picker_skip_dirs() if respect_gitignore else List[String]()
    var out = List[String]()
    var rel_dirs = List[String]()
    rel_dirs.append(String(""))
    while len(rel_dirs) > 0:
        var rel_dir = rel_dirs.pop()
        var dir = root if len(rel_dir.as_bytes()) == 0 \
            else join_path(root, rel_dir)
        var raw = list_directory(dir)
        for i in range(len(raw)):
            var name = raw[i]
            if name == String(".") or name == String("..") \
                    or name == String(".git"):
                continue
            var rel = name if len(rel_dir.as_bytes()) == 0 \
                else join_path(rel_dir, name)
            var full = join_path(root, rel)
            var info = stat_file(full)
            if not info.ok:
                continue
            if info.is_dir():
                if _name_in(name, skip):
                    continue
                if matcher.ignored(rel, True):
                    continue
                rel_dirs.append(rel)
            else:
                if not include_ignored_files \
                        and matcher.ignored(rel, False):
                    continue
                out.append(full)
    return out^


def _looks_binary(text: String) -> Bool:
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > 4096:
        n = 4096
    for i in range(n):
        if bytes[i] == 0:
            return True
    return False


def _project_relative(root: String, full: String) -> String:
    var rb = root.as_bytes()
    var fb = full.as_bytes()
    if len(fb) <= len(rb) + 1:
        return full
    for k in range(len(rb)):
        if fb[k] != rb[k]:
            return full
    if fb[len(rb)] != 0x2F:
        return full
    return String(StringSlice(unsafe_from_utf8=fb[len(rb) + 1:]))


def _replace_all_in_string(
    haystack: String, needle: String, replacement: String,
) -> String:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    var n = len(nb)
    var h = len(hb)
    if n == 0 or n > h:
        return haystack
    var out = String("")
    var i = 0
    var seg_start = 0
    while i + n <= h:
        var hit = True
        for k in range(n):
            if hb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            if i > seg_start:
                out = out + String(StringSlice(
                    unsafe_from_utf8=hb[seg_start:i]
                ))
            out = out + replacement
            i += n
            seg_start = i
        else:
            i += 1
    if seg_start < h:
        out = out + String(StringSlice(unsafe_from_utf8=hb[seg_start:h]))
    return out


def _contains_bytes(line: String, needle: String) -> Bool:
    var lb = line.as_bytes()
    var nb = needle.as_bytes()
    var n = len(nb)
    var h = len(lb)
    if n == 0:
        return True
    if n > h:
        return False
    for i in range(h - n + 1):
        var hit = True
        for k in range(n):
            if lb[i + k] != nb[k]:
                hit = False
                break
        if hit:
            return True
    return False


def find_in_project(
    root: String, needle: String,
    opts: SearchOptions = default_search_options(),
) raises -> List[ProjectMatch]:
    """Return every line in every project file that contains ``needle``.

    ``opts`` honors the Cc / W / .* search-mode flags. Default-set
    options (no flags) take the byte-match fast path that pre-existed
    options support; any flag set switches to libonig per line."""
    var out = List[ProjectMatch]()
    if len(needle.as_bytes()) == 0:
        return out^
    var rx_opt = build_search_regex(needle, opts)
    var paths = walk_project_files(root)
    for p in range(len(paths)):
        var full = paths[p]
        var text: String
        try:
            text = read_file(full)
        except:
            continue
        if _looks_binary(text):
            continue
        var lines = split_lines_no_trailing(text)
        var rel = _project_relative(root, full)
        for ln in range(len(lines)):
            var hit: Bool
            if rx_opt:
                var m = rx_opt.value().search(lines[ln])
                hit = Bool(m) and m.value().start >= 0
            else:
                hit = _contains_bytes(lines[ln], needle)
            if hit:
                out.append(ProjectMatch(full, rel, ln + 1, lines[ln]))
    return out^


def replace_in_project(
    root: String, needle: String, replacement: String,
    opts: SearchOptions = default_search_options(),
) raises -> Tuple[Int, Int]:
    """Replace ``needle`` with ``replacement`` across all project files.

    Returns ``(files_changed, total_replacements)``. Files that look binary
    or where the write fails are silently skipped.

    With ``opts`` flags set the per-line replace runs through libonig
    so case-folding, whole-word, and regex modes share one path with
    the in-file ``Editor.replace_all``."""
    var files_changed = 0
    var total = 0
    var nbytes = needle.as_bytes()
    var n = len(nbytes)
    if n == 0:
        return (0, 0)
    var rx_opt = build_search_regex(needle, opts)
    var paths = walk_project_files(root)
    for p in range(len(paths)):
        var full = paths[p]
        var text: String
        try:
            text = read_file(full)
        except:
            continue
        if _looks_binary(text):
            continue
        var count = 0
        var new_text: String
        if rx_opt:
            var pair = _regex_replace_count(
                text, rx_opt.value(), replacement,
            )
            new_text = pair[0]
            count = pair[1]
        else:
            var hb = text.as_bytes()
            var h = len(hb)
            if h < n:
                continue
            var i = 0
            while i + n <= h:
                var hit = True
                for k in range(n):
                    if hb[i + k] != nbytes[k]:
                        hit = False
                        break
                if hit:
                    count += 1
                    i += n
                else:
                    i += 1
            if count == 0:
                continue
            new_text = _replace_all_in_string(text, needle, replacement)
        if count == 0:
            continue
        if write_file(full, new_text):
            files_changed += 1
            total += count
    return (files_changed, total)


def _regex_replace_count(
    text: String, rx: OnigRegex, replacement: String,
) -> Tuple[String, Int]:
    """Walk libonig matches across ``text`` rebuilding the file with
    every hit swapped for ``replacement``. Replacement is literal —
    no ``$1`` backreferences, matching the in-file path. Returns
    ``(new_text, replacement_count)``."""
    var hb = text.as_bytes()
    var h = len(hb)
    var out = String("")
    var pos = 0
    var seg_start = 0
    var count = 0
    while pos <= h:
        var m = rx.search_at(text, pos)
        if not m:
            break
        var mv = m.value().copy()
        if mv.start < 0 or mv.end < mv.start:
            break
        if mv.start > seg_start:
            out = out + String(StringSlice(
                unsafe_from_utf8=hb[seg_start:mv.start]
            ))
        out = out + replacement
        count += 1
        if mv.end == mv.start:
            seg_start = mv.start
            pos = mv.start + 1
        else:
            seg_start = mv.end
            pos = mv.end
    if count == 0:
        return (text, 0)
    if seg_start < h:
        out = out + String(StringSlice(unsafe_from_utf8=hb[seg_start:h]))
    return (out, count)
