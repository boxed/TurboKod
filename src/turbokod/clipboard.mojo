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

from .events import Event, EVENT_KEY, MOD_CTRL, MOD_META
from .posix import getenv_value, strip_macos_malloc_debug_env


# Result tags for ``clipboard_chord``. Plain ``UInt8`` constants in the
# Event-discriminant style — we don't get enums, and a returned struct
# would force every caller through a copy.
comptime CLIP_NONE       = UInt8(0)
comptime CLIP_COPY       = UInt8(1)
comptime CLIP_CUT        = UInt8(2)
comptime CLIP_PASTE      = UInt8(3)
comptime CLIP_SELECT_ALL = UInt8(4)


def clipboard_chord(event: Event) -> UInt8:
    """Classify a key event as a clipboard hotkey: Ctrl/Cmd + A / C / X / V.

    Either Ctrl or Cmd (``MOD_META``) counts as the chord modifier —
    Ctrl is the Linux/Windows convention; Cmd is the macOS one. Both
    map to the same select-all / copy / cut / paste actions so a text
    field behaves the way the user's muscle memory expects regardless
    of platform.

    Everything else (non-key events, neither modifier, other letters)
    maps to ``CLIP_NONE``. Centralizing this here keeps the Editor and
    TextField handlers from each re-spelling the same modifier check.
    """
    if event.kind != EVENT_KEY:
        return CLIP_NONE
    if (event.mods & (MOD_CTRL | MOD_META)) == 0:
        return CLIP_NONE
    var k = event.key
    if k == UInt32(ord("a")):
        return CLIP_SELECT_ALL
    if k == UInt32(ord("c")):
        return CLIP_COPY
    if k == UInt32(ord("x")):
        return CLIP_CUT
    if k == UInt32(ord("v")):
        return CLIP_PASTE
    return CLIP_NONE


def _copy_command() -> String:
    comptime if CompilationTarget.is_macos():
        # ``LC_CTYPE=UTF-8`` is load-bearing: ``pbcopy`` interprets its stdin
        # using the locale's text encoding, and a GUI app launched from
        # Finder/Dock inherits no ``LANG``/``LC_*`` — so ``pbcopy`` falls back
        # to Mac OS Roman and silently mis-decodes our UTF-8 bytes. ``m³``
        # (U+00B3 → ``C2 B3``) then lands on the pasteboard as ``m¬≥`` (the
        # Mac-Roman reading of those two bytes). Forcing UTF-8 here keeps the
        # pasteboard string byte-faithful regardless of the app's environment.
        return String("LC_CTYPE=UTF-8 pbcopy")
    else:
        return String("xclip -selection clipboard 2>/dev/null")


def _paste_command() -> String:
    comptime if CompilationTarget.is_macos():
        # Same as ``_copy_command``: ``pbpaste`` *emits* in the locale encoding,
        # so without UTF-8 it would re-encode a real Unicode pasteboard string
        # (e.g. copied from another app) as Mac Roman on the way out.
        return String("LC_CTYPE=UTF-8 pbpaste")
    else:
        return String("xclip -selection clipboard -o 2>/dev/null")


def clipboard_copy(text: String):
    """Push ``text`` to the system clipboard. Silent failure on error.

    Bypassed when ``TURBOKOD_FAKE_CLIPBOARD`` is set so the test suite
    doesn't shell out to ``pbcopy`` and clobber the developer's real
    system clipboard with test fixtures.
    """
    if len(getenv_value(String("TURBOKOD_FAKE_CLIPBOARD")).as_bytes()) > 0:
        return
    strip_macos_malloc_debug_env()
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


def clipboard_paste() -> String:
    """Read the system clipboard. Returns empty string on error."""
    if len(getenv_value(String("TURBOKOD_FAKE_CLIPBOARD")).as_bytes()) > 0:
        return String("")
    strip_macos_malloc_debug_env()
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
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=out.unsafe_ptr(), length=len(out))))
