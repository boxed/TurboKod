"""Open a URL in the user's default browser via the platform opener.

popen-spawns ``open`` (macOS) / ``xdg-open`` (Linux) the same FFI-friendly
way ``clipboard.mojo`` shells out to ``pbcopy``. Best-effort: a failure (no
opener installed, no display) silently no-ops. The URL is single-quote
escaped before reaching ``/bin/sh -c`` so output containing shell
metacharacters can't break out of the argument, and only ``http(s)://``
targets are honored so a stray click can't run an arbitrary command.
"""

from std.ffi import external_call
from std.sys.info import CompilationTarget

from .posix import getenv_value


def _starts_with_http(url: String) -> Bool:
    """True iff ``url`` begins with ``http://`` or ``https://``."""
    var b = url.as_bytes()
    var n = len(b)
    if n < 7 or b[0] != 0x68 or b[1] != 0x74 or b[2] != 0x74 or b[3] != 0x70:
        return False
    if b[4] == 0x3A and b[5] == 0x2F and b[6] == 0x2F:
        return True   # http://
    if n >= 8 and b[4] == 0x73 and b[5] == 0x3A and b[6] == 0x2F \
            and b[7] == 0x2F:
        return True   # https://
    return False


def _shell_single_quote(s: String) -> String:
    """Wrap ``s`` in single quotes for ``/bin/sh``, turning each embedded
    ``'`` into the standard ``'\\''`` close/escape/reopen sequence. Copies
    quote-free runs as byte slices so multibyte UTF-8 passes through intact.
    """
    var b = s.as_bytes()
    var n = len(b)
    var out = String("'")
    var start = 0
    var i = 0
    while i < n:
        if b[i] == 0x27:  # '
            if i > start:
                out += String(StringSlice(
                    ptr=b.unsafe_ptr() + start, length=i - start,
                ))
            out += String("'\\''")
            start = i + 1
        i += 1
    if start < n:
        out += String(StringSlice(
            ptr=b.unsafe_ptr() + start, length=n - start,
        ))
    out += String("'")
    return out^


def _strip_macos_malloc_debug_env():
    """Drop the macOS malloc-debug env vars before ``popen`` forks a shell
    so its libmalloc init can't print scribble diagnostics onto the raw-mode
    TTY. Same defense as ``clipboard.mojo``; see its note for the why."""
    var s = String("MallocScribble\0")
    var ps = String("MallocPreScribble\0")
    var ge = String("MallocGuardEdges\0")
    _ = external_call["unsetenv", Int32](s.unsafe_ptr())
    _ = external_call["unsetenv", Int32](ps.unsafe_ptr())
    _ = external_call["unsetenv", Int32](ge.unsafe_ptr())


def open_url(url: String):
    """Open ``url`` in the system default browser. Best-effort, silent on
    failure. Only ``http(s)://`` URLs are launched.

    Bypassed when ``TURBOKOD_FAKE_BROWSER`` is set so the test suite doesn't
    pop a browser window during a run.
    """
    if not _starts_with_http(url):
        return
    if len(getenv_value(String("TURBOKOD_FAKE_BROWSER")).as_bytes()) > 0:
        return
    _strip_macos_malloc_debug_env()
    var opener: String
    comptime if CompilationTarget.is_macos():
        opener = String("open")
    else:
        opener = String("xdg-open")
    # Background + redirect so a slow opener can't stall the UI loop.
    var cmd = opener + String(" ") + _shell_single_quote(url) \
        + String(" >/dev/null 2>&1 &\0")
    var mode = String("r\0")
    var fp = external_call["popen", Int](cmd.unsafe_ptr(), mode.unsafe_ptr())
    if fp == 0:
        return
    _ = external_call["pclose", Int32](fp)
