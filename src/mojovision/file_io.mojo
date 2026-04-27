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
from std.io.file_descriptor import FileDescriptor
from std.memory.span import Span
from std.os import listdir
from std.sys.info import CompilationTarget

from .posix import alloc_zero_buffer, realpath


comptime O_RDONLY: Int32 = 0
comptime STAT_BUF_SIZE: Int = 256       # generous upper bound for any platform
# Platform-specific byte offsets into ``struct stat`` for the fields we read.
# Determined from /usr/include/sys/_types/_s_*.h on Darwin and from
# bits/struct_stat.h on glibc.


fn _stat_size_offset() -> Int:
    comptime if CompilationTarget.is_macos():
        return 96    # off_t st_size on Darwin
    else:
        return 48    # off_t st_size on Linux/x86-64 + arm64


fn _stat_mtime_offset() -> Int:
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

    fn is_dir(self) -> Bool:
        return (self.mode & _S_IFMT) == _S_IFDIR


fn _stat_mode(buf: List[UInt8]) -> UInt32:
    """``st_mode`` is uint16 at offset 4 on Darwin, uint32 at offset 24 on Linux."""
    comptime if CompilationTarget.is_macos():
        return UInt32(buf.unsafe_ptr().bitcast[UInt16]()[2])
    else:
        return buf.unsafe_ptr().bitcast[UInt32]()[6]


fn stat_file(path: String) -> FileInfo:
    """Best-effort stat. Returns ``ok=False`` on any error (missing file, etc.)."""
    var c_path = path + String("\0")
    var buf = alloc_zero_buffer(STAT_BUF_SIZE)
    var rc = external_call["stat", Int32](c_path.unsafe_ptr(), buf.unsafe_ptr())
    if Int(rc) != 0:
        return FileInfo(Int64(0), Int64(0), UInt32(0), False)
    var p64 = buf.unsafe_ptr().bitcast[Int64]()
    var size = p64[_stat_size_offset() // 8]
    var mtime = p64[_stat_mtime_offset() // 8]
    var mode = _stat_mode(buf)
    return FileInfo(size, mtime, mode, True)


fn read_file(path: String) raises -> String:
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
    var got = external_call["read", Int](fd, buf.unsafe_ptr(), size)
    _ = external_call["close", Int32](fd)
    if got <= 0:
        return String("")
    return String(StringSlice(ptr=buf.unsafe_ptr(), length=got))


fn write_file(path: String, content: String) -> Bool:
    """Write ``content`` to ``path``, replacing any existing file. Returns
    True on success.

    Uses ``creat(2)`` — equivalent to ``open(O_WRONLY|O_CREAT|O_TRUNC, 0644)``
    but non-variadic, so it works through Mojo's ``external_call``. We then
    write via ``FileDescriptor.write_bytes`` because ``external_call["write"]``
    collides with a stdlib registration of the same symbol.
    """
    var c_path = path + String("\0")
    var fd = external_call["creat", Int32](c_path.unsafe_ptr(), Int32(0o644))
    if fd < 0:
        return False
    var bytes = content.as_bytes()
    if len(bytes) > 0:
        var f = FileDescriptor(Int(fd))
        f.write_bytes(bytes)
    _ = external_call["close", Int32](fd)
    return True


# --- Directory listing -----------------------------------------------------


fn list_directory(path: String) -> List[String]:
    """Names in ``path``. Returns an empty list on error.

    Uses ``std.os.listdir`` under the hood. Filters out the empty string but
    keeps "." and ".." so callers can render them.
    """
    var out = List[String]()
    try:
        var raw = listdir(path)
        for i in range(len(raw)):
            out.append(raw[i])
    except:
        pass
    return out^


fn join_path(dir: String, name: String) -> String:
    """Join ``dir`` and ``name`` with a single ``/`` separator."""
    var d = dir
    var dbytes = d.as_bytes()
    if len(dbytes) == 0:
        return name
    if dbytes[len(dbytes) - 1] == 0x2F:    # already ends in '/'
        return d + name
    return d + String("/") + name


fn parent_path(path: String) -> String:
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
    return String(StringSlice(unsafe_from_utf8=bytes[:i]))


fn basename(path: String) -> String:
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
        return String(StringSlice(unsafe_from_utf8=bytes[:n]))
    if i == 0 and n == 1:
        return String("/")
    return String(StringSlice(unsafe_from_utf8=bytes[i + 1:n]))


fn find_git_project(start_path: String) -> Optional[String]:
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
