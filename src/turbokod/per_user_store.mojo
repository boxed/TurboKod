"""Shared plumbing for the per-user on-disk stores.

``session_store``, ``view_state_store`` and ``breakpoint_store`` all persist
into ``<project>/.turbokod/per_user/<username>/<file>`` — the
``per_user/<username>`` segment keeps an accidental ``git add .turbokod``
from clobbering a teammate's state. This module owns the username lookup,
the path computation, and the nested ``mkdir`` so the three stores don't
each carry their own copy.
"""

from std.ffi import external_call

from .file_io import join_path
from .posix import getenv_value


comptime _DIR_PROJECT = String(".turbokod")
comptime _DIR_PER_USER = String("per_user")


def current_username() -> String:
    """Best-effort username for the per-user directory. Tries ``$USER``
    then ``$LOGNAME`` — both POSIX-standard. Falls back to ``"default"``
    so we still produce a valid path on a machine with an empty
    environment."""
    var user = getenv_value(String("USER"))
    if len(user.as_bytes()) > 0:
        return user^
    var logname = getenv_value(String("LOGNAME"))
    if len(logname.as_bytes()) > 0:
        return logname^
    return String("default")


def per_user_dir(project_root: String) -> String:
    """``<project_root>/.turbokod/per_user/<username>``, or ``""`` for an
    empty root."""
    if len(project_root.as_bytes()) == 0:
        return String("")
    var d = join_path(project_root, _DIR_PROJECT)
    d = join_path(d, _DIR_PER_USER)
    return join_path(d, current_username())


def per_user_path(project_root: String, file_name: String) -> String:
    """Full path to ``file_name`` inside the per-user dir, or ``""`` for an
    empty root."""
    var dir = per_user_dir(project_root)
    if len(dir.as_bytes()) == 0:
        return String("")
    return join_path(dir, file_name)


def _mkdir(path: String):
    if len(path.as_bytes()) == 0:
        return
    var c_path = path + String("\0")
    _ = external_call["mkdir", Int32](c_path.unsafe_ptr(), Int32(0o755))


def ensure_per_user_dir(project_root: String):
    """``mkdir`` only creates one level, so walk the parents top-down to
    create the ``per_user/<username>`` nesting on first use."""
    if len(project_root.as_bytes()) == 0:
        return
    var top = join_path(project_root, _DIR_PROJECT)
    _mkdir(top)
    var per_user = join_path(top, _DIR_PER_USER)
    _mkdir(per_user)
    _mkdir(join_path(per_user, current_username()))
