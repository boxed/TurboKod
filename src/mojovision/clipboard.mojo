"""Native clipboard via the platform's standard CLI helpers.

Uses libc ``popen``/``pclose`` (non-variadic, FFI-friendly) to spawn:
- ``pbcopy`` / ``pbpaste`` on macOS
- ``xclip`` (or ``wl-copy``/``wl-paste``) on Linux

We don't try to detect *which* Linux helper is installed; ``xclip`` is the
de-facto default on X11. Wayland users may need to point at ``wl-copy``
manually (one-line edit at the bottom of this file).

If a copy/paste command fails (helper not installed, no display, etc.), the
copy silently no-ops and the paste returns an empty string — clipboard
operations are best-effort.
"""

from std.collections.list import List
from std.ffi import external_call
from std.sys.info import CompilationTarget


fn _copy_command() -> String:
    comptime if CompilationTarget.is_macos():
        return String("pbcopy")
    else:
        return String("xclip -selection clipboard 2>/dev/null")


fn _paste_command() -> String:
    comptime if CompilationTarget.is_macos():
        return String("pbpaste")
    else:
        return String("xclip -selection clipboard -o 2>/dev/null")


fn clipboard_copy(text: String):
    """Push ``text`` to the system clipboard. Silent failure on error."""
    var cmd = _copy_command() + String("\0")
    var mode = String("w\0")
    var fp = external_call["popen", Int](cmd.unsafe_ptr(), mode.unsafe_ptr())
    if fp == 0:
        return
    var bytes = text.as_bytes()
    if len(bytes) > 0:
        _ = external_call["fwrite", UInt](
            text.unsafe_ptr(), UInt(1), UInt(len(bytes)), fp,
        )
    _ = external_call["pclose", Int32](fp)


fn clipboard_paste() -> String:
    """Read the system clipboard. Returns empty string on error."""
    var cmd = _paste_command() + String("\0")
    var mode = String("r\0")
    var fp = external_call["popen", Int](cmd.unsafe_ptr(), mode.unsafe_ptr())
    if fp == 0:
        return String("")
    var out = List[UInt8]()
    var chunk = List[UInt8]()
    for _ in range(1024):
        chunk.append(0)
    while True:
        var n = Int(external_call["fread", UInt](
            chunk.unsafe_ptr(), UInt(1), UInt(1024), fp,
        ))
        if n <= 0:
            break
        for i in range(n):
            out.append(chunk[i])
    _ = external_call["pclose", Int32](fp)
    if len(out) == 0:
        return String("")
    return String(StringSlice(ptr=out.unsafe_ptr(), length=len(out)))
