"""File-system helpers used by the editor: read text, stat for change detection.

Pure-Mojo via libc ``open``/``read``/``close`` and ``stat``. The ``stat`` struct
layout differs by platform; we only need the mtime + size, both at fixed
byte offsets within Darwin / Linux ``struct stat``. We allocate a generous
opaque buffer and read the right offsets.

If you find yourself needing more fields, look at ``man 2 stat`` for the
target platform — the offsets *will* differ.
"""

from std.collections.list import List
from std.collections.optional import Optional
from std.ffi import external_call
from std.sys.info import CompilationTarget

from .case_fold import fold_byte
from .posix import alloc_zero_buffer, realpath


comptime O_RDONLY: Int32 = 0
comptime O_WRONLY: Int32 = 1            # same value on Linux and macOS
comptime STAT_BUF_SIZE: Int = 256       # generous upper bound for any platform
# Platform-specific byte offsets into ``struct stat`` for the fields we read.
# Determined from /usr/include/sys/_types/_s_*.h on Darwin and from
# bits/struct_stat.h on glibc.


def _stat_size_offset() -> Int:
    comptime if CompilationTarget.is_macos():
        return 96    # off_t st_size on Darwin
    else:
        return 48    # off_t st_size on Linux/x86-64 + arm64


def _stat_mtime_offset() -> Int:
    """Byte offset of st_mtim.tv_sec (Linux) / st_mtimespec.tv_sec (Darwin)."""
    comptime if CompilationTarget.is_macos():
        return 48    # st_mtimespec.tv_sec (time_t = 8 bytes)
    else:
        return 88    # st_mtim.tv_sec on Linux 64-bit


comptime _S_IFMT  = UInt32(0o170000)
comptime _S_IFDIR = UInt32(0o040000)


@fieldwise_init
struct FileInfo(ImplicitlyCopyable, Movable):
    """Subset of ``struct stat`` we care about for change detection."""
    var size: Int64
    var mtime_sec: Int64
    var mode: UInt32
    var ok: Bool

    def is_dir(self) -> Bool:
        return (self.mode & _S_IFMT) == _S_IFDIR


def _stat_mode(buf: List[UInt8]) -> UInt32:
    """``st_mode`` is uint16 at offset 4 on Darwin, uint32 at offset 24 on Linux."""
    comptime if CompilationTarget.is_macos():
        return UInt32(buf.unsafe_ptr().unsafe_bitcast[UInt16]()[unsafe_offset=2])
    else:
        return buf.unsafe_ptr().unsafe_bitcast[UInt32]()[unsafe_offset=6]


def stat_file(path: String) -> FileInfo:
    """Best-effort stat. Returns ``ok=False`` on any error (missing file, etc.)."""
    var c_path = path + String("\0")
    var buf = alloc_zero_buffer(STAT_BUF_SIZE)
    var rc = external_call["stat", Int32](c_path.unsafe_ptr(), buf.unsafe_ptr())
    if Int(rc) != 0:
        return FileInfo(Int64(0), Int64(0), UInt32(0), False)
    var p64 = buf.unsafe_ptr().unsafe_bitcast[Int64]()
    var size = p64[unsafe_offset=_stat_size_offset() // 8]
    var mtime = p64[unsafe_offset=_stat_mtime_offset() // 8]
    var mode = _stat_mode(buf)
    return FileInfo(size, mtime, mode, True)


def read_file(path: String) raises -> String:
    """Read the entire file as a UTF-8 string. Empty string on error."""
    var c_path = path + String("\0")
    var fd = external_call["open", Int32](c_path.unsafe_ptr(), O_RDONLY)
    if fd < 0:
        return String("")
    var info = stat_file(path)
    var size = Int(info.size)
    if size <= 0:
        _ = external_call["close", Int32](fd)
        return String("")
    var buf = alloc_zero_buffer(size + 1)
    # ``read(2)`` may return fewer than ``size`` bytes for a regular file
    # (signal interruption, certain filesystems). A single read would
    # silently truncate the buffer — which then becomes the editor content
    # and the save baseline — so loop until the whole file is read or we
    # hit EOF.
    var total = 0
    var retries = 0
    while total < size:
        var got = external_call["read", Int](
            fd, buf.unsafe_ptr().unsafe_offset(total), size - total,
        )
        if got == 0:
            break  # true EOF — file shrank since stat; return what we have
        if got < 0:
            # Read error, most likely a transient EINTR (signal mid-read).
            # Retry a bounded number of times; a persistent error returns ""
            # rather than a partial buffer that would masquerade as the whole
            # file and become the save baseline.
            retries += 1
            if retries > 8:
                _ = external_call["close", Int32](fd)
                return String("")
            continue
        retries = 0
        total += got
    _ = external_call["close", Int32](fd)
    if total <= 0:
        return String("")
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=total)))


def write_file(path: String, content: String) -> Bool:
    """Write ``content`` to ``path`` atomically. Returns True on success.

    Writes to a sibling temp file, fsyncs, then ``rename(2)`` over the
    target — so a crash, full disk, or partial write can never leave the
    original truncated or empty (the old content stays intact until the
    rename succeeds). The write itself loops to handle short writes and
    reports failure: previously the ``write_bytes`` result was discarded, so
    an ``ENOSPC``/short write returned success and let ``Editor.save`` clear
    the dirty flag over an incomplete file.

    ``creat(2)`` is used (not ``open``) for the temp file because it's
    non-variadic and so works through Mojo's ``external_call``. If the
    directory isn't writable but the file itself is, the temp create fails
    and we fall back to an in-place (non-atomic) overwrite so saving still
    works in that rare case. That fallback deliberately does **not** use
    ``creat`` on the real path: ``creat`` implies ``O_TRUNC``, which would
    empty the file *before* the write, so a mid-write ``ENOSPC`` would
    destroy the original. Instead it opens ``O_WRONLY`` (no truncate),
    writes the full content, and only ``ftruncate``s down to the new length
    on success — a short write then leaves a corrupt-but-non-empty file
    (which the config/session loaders move aside) rather than a blank one.
    """
    var bytes = content.as_bytes()
    var total = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var c_path = path + String("\0")

    var c_tmp = path + String(".tk-tmp") + String("\0")
    var fd = external_call["creat", Int32](c_tmp.unsafe_ptr(), Int32(0o644))
    var atomic = fd >= 0
    if not atomic:
        # No sibling temp possible (read-only dir). Overwrite in place
        # without truncating up front — see the docstring.
        fd = external_call["open", Int32](c_path.unsafe_ptr(), O_WRONLY)
        if fd < 0:
            return False

    var written = 0
    var ok = True
    while written < total:
        var n = external_call["write", Int](
            Int(fd), ptr.unsafe_offset(written), UInt(total - written),
        )
        if n <= 0:
            ok = False
            break
        written += n

    if not atomic:
        # Drop any stale tail (old file longer than the new content) only
        # after a complete write; on a short write we leave the file as-is
        # and report failure rather than shrinking to a truncated prefix.
        if ok:
            _ = external_call["ftruncate", Int32](Int(fd), Int(total))
        _ = external_call["fsync", Int32](fd)
        _ = external_call["close", Int32](fd)
        return ok

    _ = external_call["fsync", Int32](fd)
    _ = external_call["close", Int32](fd)
    if ok and external_call["rename", Int32](
        c_tmp.unsafe_ptr(), c_path.unsafe_ptr()
    ) == Int32(0):
        return True
    _ = external_call["unlink", Int32](c_tmp.unsafe_ptr())
    return False


def rename_path(src: String, dst: String) -> Bool:
    """``rename(2)`` ``src`` onto ``dst``. Returns True on success.

    A plain rename within the same filesystem — used by the tab/title
    context-menu "Rename" action. The caller is responsible for refusing
    to clobber an existing target (``rename(2)`` would silently replace
    it); see ``Desktop._do_rename_file``."""
    var c_src = src + String("\0")
    var c_dst = dst + String("\0")
    return external_call["rename", Int32](
        c_src.unsafe_ptr(), c_dst.unsafe_ptr(),
    ) == Int32(0)


def delete_path(path: String) -> Bool:
    """``unlink(2)`` ``path``. Returns True on success — used by the
    tab/title context-menu "Delete" action."""
    var c_path = path + String("\0")
    return external_call["unlink", Int32](c_path.unsafe_ptr()) == Int32(0)


def delete_tree(path: String, is_dir: Bool) -> Bool:
    """Delete ``path``. A plain file is ``unlink``ed; a directory is
    emptied recursively (children first) and then ``rmdir``ed. Returns
    True only when everything was removed. Used by the file-tree
    context-menu "Delete" action, which can target directories."""
    if not is_dir:
        return delete_path(path)
    var children = list_directory_typed(path)
    var ok = True
    for i in range(len(children)):
        var name = children[i][0]
        if name == String(".") or name == String(".."):
            continue
        if not delete_tree(join_path(path, name), children[i][1]):
            ok = False
    if not ok:
        return False
    var c_path = path + String("\0")
    return external_call["rmdir", Int32](c_path.unsafe_ptr()) == Int32(0)


# --- Directory listing -----------------------------------------------------


def list_directory(path: String) -> List[String]:
    """Names in ``path``. Returns an empty list on error.

    Uses a thin C wrapper around ``opendir``/``readdir`` (declared in
    ``process_shim.c``). The previous implementation routed through
    ``std.os.listdir`` which has been observed to segfault in certain
    launch-from-bundle environments where Python interop init differs
    from the developer setup. The C path allocates its own buffer
    (``tk_listdir`` mallocs, returns a pointer through ``out_buf``; we
    copy the entries out and free)."""
    from .posix import debug_log
    debug_log(String("[list_directory] ENTER path=") + path)
    var out = List[String]()
    var c_path = path + String("\0")
    debug_log(String("[list_directory] calling tk_listdir"))
    var n_entries = Int(external_call["tk_listdir", Int32](
        c_path.unsafe_ptr(),
    ))
    debug_log(String("[list_directory] tk_listdir n_entries=")
        + String(n_entries))
    if n_entries < 0:
        return out^
    # Pull entries one at a time into a small fixed buffer. 4096 bytes
    # is the maximum filename length on every filesystem we care about
    # (HFS+/APFS: 255 codepoints, ext4: 255 bytes, NTFS: 255 chars).
    var name_buf = List[UInt8]()
    for _ in range(4096):
        name_buf.append(0)
    for i in range(n_entries):
        var got = Int(external_call["tk_listdir_get_name", Int32](
            Int32(i),
            name_buf.unsafe_ptr(),
            Int32(4096),
        ))
        if got > 0:
            out.append(String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=name_buf.unsafe_ptr(), length=got))))
    _ = external_call["tk_listdir_done", NoneType]()
    debug_log(String("[list_directory] EXIT n=") + String(len(out)))
    return out^


def list_directory_typed(path: String) -> List[Tuple[String, Bool]]:
    """Names in ``path`` paired with ``is_dir``. Empty list on error.

    Same ``tk_listdir`` / ``tk_listdir_get_name`` / ``tk_listdir_done``
    dance as ``list_directory``, but also pulls each entry's raw dirent
    ``d_type`` via ``tk_listdir_get_type`` so we avoid a per-entry
    ``stat`` syscall. ``DT_DIR`` answers ``is_dir`` directly;
    ``DT_UNKNOWN`` / ``DT_LNK`` (and anything else ambiguous) fall back
    to ``stat_file`` so a symlink-to-dir still counts as a dir."""
    var out = List[Tuple[String, Bool]]()
    var c_path = path + String("\0")
    var n_entries = Int(external_call["tk_listdir", Int32](
        c_path.unsafe_ptr(),
    ))
    if n_entries < 0:
        return out^
    var name_buf = List[UInt8]()
    for _ in range(4096):
        name_buf.append(0)
    for i in range(n_entries):
        var got = Int(external_call["tk_listdir_get_name", Int32](
            Int32(i),
            name_buf.unsafe_ptr(),
            Int32(4096),
        ))
        if got > 0:
            var name = String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=name_buf.unsafe_ptr(), length=got)))
            var dtype = Int(external_call["tk_listdir_get_type", Int32](
                Int32(i),
            ))
            var is_dir: Bool
            if dtype == 4:                    # DT_DIR
                is_dir = True
            elif dtype == 0 or dtype == 10:   # DT_UNKNOWN / DT_LNK
                var info = stat_file(join_path(path, name))
                is_dir = info.is_dir() if info.ok else False
            else:
                is_dir = False
            out.append((name^, is_dir))
    _ = external_call["tk_listdir_done", NoneType]()
    return out^


def join_path(dir: String, name: String) -> String:
    """Join ``dir`` and ``name`` with a single ``/`` separator."""
    var d = dir
    var dbytes = d.as_bytes()
    if len(dbytes) == 0:
        return name
    if dbytes[len(dbytes) - 1] == 0x2F:    # already ends in '/'
        return d + name
    return d + String("/") + name


def project_relative(
    root: String,
    full: String,
    canonicalize: Bool = False,
    empty_on_exact: Bool = False,
) -> String:
    """Strip a leading ``<root>/`` from ``full`` to get a project-relative
    path. Returns ``full`` unchanged when it lies outside ``root`` (or
    ``root`` is empty). When ``full`` equals ``root`` exactly, returns
    ``""`` if ``empty_on_exact`` else ``full``.

    With ``empty_on_exact=False`` a path that is merely ``root`` plus one
    trailing byte (e.g. ``root + "/"``) is treated as non-strippable and
    echoed back — matching the historic session/project/view-state guard.

    With ``canonicalize=True`` both sides are ``realpath``-resolved before
    the byte compare (needed when ``root`` is canonical but ``full`` may not
    be, e.g. on case-insensitive APFS or a symlinked root); the original
    ``full`` is still what's returned on a non-match.

    Single source for what used to be ``_session_relative`` /
    ``_project_relative`` / ``_vs_relative`` / ``_strip_root`` /
    ``_strip_root_prefix`` / ``_relative_to_root``."""
    var cmp_root = root
    var cmp_full = full
    if canonicalize:
        var rr = realpath(root)
        if len(rr.as_bytes()) > 0:
            cmp_root = rr
        var rp = realpath(full)
        if len(rp.as_bytes()) > 0:
            cmp_full = rp
    var rb = cmp_root.as_bytes()
    var fb = cmp_full.as_bytes()
    if len(rb) == 0 or len(fb) < len(rb):
        return full
    for k in range(len(rb)):
        if fb[k] != rb[k]:
            return full
    if len(fb) == len(rb):
        return String("") if empty_on_exact else full
    if not empty_on_exact and len(fb) == len(rb) + 1:
        return full
    if fb[len(rb)] != 0x2F:
        return full
    return String(StringSpan(unsafe_from_utf8=fb[len(rb) + 1:]))


def parent_path(path: String) -> String:
    """Return the parent directory of ``path`` (or ``"/"`` at the root)."""
    var bytes = path.as_bytes()
    var n = len(bytes)
    if n == 0:
        return String("/")
    # Strip trailing slashes (but leave at least one byte).
    while n > 1 and bytes[n - 1] == 0x2F:
        n -= 1
    var i = n - 1
    while i >= 0 and bytes[i] != 0x2F:
        i -= 1
    if i < 0:
        return String(".")
    if i == 0:
        return String("/")
    return String(StringSpan(unsafe_from_utf8=bytes[:i]))


def ci_less(a: String, b: String) -> Bool:
    """``True`` iff ``a < b`` lexicographically, ignoring ASCII case.

    Non-ASCII bytes compare via raw byte value (no Unicode case folding) —
    fine for the typical mix of English filenames; if the user has Cyrillic
    / CJK names they'll cluster but stay grouped. Shared by every UI that
    lists directory contents so the file dialog and the project file tree
    agree on order.
    """
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = len(ab) if len(ab) < len(bb) else len(bb)
    for i in range(n):
        var ca = fold_byte(ab[i])
        var cb = fold_byte(bb[i])
        if ca != cb:
            return ca < cb
    return len(ab) < len(bb)


def sort_directory_listing(
    mut names: List[String], mut is_dirs: List[Bool],
):
    """Reorder the parallel ``names`` / ``is_dirs`` lists so directories
    come first, then files, each group sorted case-insensitively by name.

    Operates in-place on both lists in lockstep via a two-key insertion
    sort: primary key is ``is_dir`` (true before false, so dirs lead),
    secondary key is ``ci_less(name)``. Both lists must be the same
    length on entry. Used by both the project file tree and the
    open-file dialog so the two views show identical ordering.
    """
    var n = len(names)
    for i in range(1, n):
        var j = i
        while j > 0:
            var swap: Bool
            if is_dirs[j] and not is_dirs[j - 1]:
                swap = True
            elif is_dirs[j] == is_dirs[j - 1] \
                    and ci_less(names[j], names[j - 1]):
                swap = True
            else:
                swap = False
            if not swap:
                break
            var tn = names[j]
            names[j] = names[j - 1]
            names[j - 1] = tn
            var td = is_dirs[j]
            is_dirs[j] = is_dirs[j - 1]
            is_dirs[j - 1] = td
            j -= 1


def basename(path: String) -> String:
    """Return the last path component of ``path`` (no trailing slash).

    ``"/foo/bar"`` → ``"bar"``; ``"foo"`` → ``"foo"``; ``"/"`` → ``"/"``.
    """
    var bytes = path.as_bytes()
    var n = len(bytes)
    if n == 0:
        return path
    while n > 1 and bytes[n - 1] == 0x2F:
        n -= 1
    var i = n - 1
    while i >= 0 and bytes[i] != 0x2F:
        i -= 1
    if i < 0:
        return String(StringSpan(unsafe_from_utf8=bytes[:n]))
    if i == 0 and n == 1:
        return String("/")
    return String(StringSpan(unsafe_from_utf8=bytes[i + 1:n]))


def find_git_project(start_path: String) -> Optional[String]:
    """Walk up from ``start_path`` looking for a ``.git`` entry.

    Returns the directory that contains ``.git`` (the project root) on
    success, or empty if none is found before reaching ``/``. The result
    is always an absolute path (we resolve via ``realpath`` first), so the
    caller can take ``basename`` of it to get a project name. ``.git`` may
    be a directory or a file (submodule pointer).
    """
    # Resolve to an absolute path so a relative input like "examples/foo.txt"
    # walks up past the current working directory rather than getting stuck
    # at "." (whose parent is itself).
    var resolved = realpath(start_path)
    var path = resolved if len(resolved.as_bytes()) > 0 else start_path
    var info = stat_file(path)
    if info.ok and not info.is_dir():
        path = parent_path(path)
    while True:
        var git_path = join_path(path, String(".git"))
        if stat_file(git_path).ok:
            return Optional[String](path)
        var parent = parent_path(path)
        if parent == path:
            return Optional[String]()
        path = parent
