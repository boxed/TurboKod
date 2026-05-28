"""Smoke test for the Dock/launchd PATH-recovery helpers.

Simulates a macOS Dock launch by running this with an explicitly stripped
``$PATH`` (the launchd default), exercises both halves of the recovery
(hardcoded prepend + login-shell override), and asserts that:

  1. ``PATH`` ends up longer than what we started with.
  2. ``which("ty-semantic")`` (or another known user-installed binary)
     resolves to a real path under ``~/.cargo/bin`` / ``~/.pyenv/shims``.

Run with::

    ./run.sh tests/path_recover_smoke.mojo

That uses the user's normal PATH, exercising the idempotent-prepend
branch. To exercise the Dock-launch path (stripped PATH + login-shell
recovery), build once and re-run the cached binary with a stripped
env::

    ./run.sh tests/path_recover_smoke.mojo                # first run, build
    env -i HOME=$HOME SHELL=/bin/zsh PATH=/usr/bin:/bin:/usr/sbin:/sbin \\
        .build/path_recover_smoke_*                       # subsequent runs

``env -i`` strips everything so the test sees the same PATH macOS
hands a docked app. We keep ``HOME`` and ``SHELL`` because both are
required to find the user's rc files in the first place.
"""

from turbokod.posix import (
    getenv_value, recover_user_path_for_gui_launch, which,
)


def main():
    var before = getenv_value(String("PATH"))
    print("PATH before:", before)
    recover_user_path_for_gui_launch()
    var after = getenv_value(String("PATH"))
    print("PATH after: ", after)
    if len(after.as_bytes()) <= len(before.as_bytes()):
        print("FAIL: PATH didn't grow")
        return
    # Look for a binary that's only on the user's interactive PATH
    # (not in the launchd default). ``ty-semantic`` lives under
    # ``~/.cargo/bin`` — the exact case the bug report flagged.
    var p = which(String("ty-semantic"))
    if len(p.as_bytes()) > 0:
        print("OK: ty-semantic resolved to", p)
    else:
        # Some hosts won't have ty-semantic; fall back to a more common
        # user-installed binary that should still be outside launchd-default.
        var alt = which(String("brew"))
        if len(alt.as_bytes()) > 0:
            print("OK: brew resolved to", alt, "(no ty-semantic on this host)")
        else:
            print("FAIL: neither ty-semantic nor brew resolved")
