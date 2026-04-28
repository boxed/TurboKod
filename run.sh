#!/usr/bin/env bash
# Convenience wrapper: `./run.sh examples/hello.mojo` or `./run.sh tests/test_basic.mojo`.
# Runs through pixi so the project's pinned Mojo toolchain is used; -I src makes
# `from mojovision import ...` resolve.
#
# Restores the terminal on EXIT / INT / TERM so a hung process killed with
# ``kill <pid>`` (or even ``Ctrl+C`` while the app is in raw mode) doesn't
# leave you with a wedged shell that prints escape sequences for every
# keystroke. ``stty sane`` re-enables canonical mode + echo, the printf
# unrolls alt-screen / mouse-tracking / SGR / hidden-cursor — the mirror
# of what ``Terminal.stop()`` would have done if it had a chance to run.
set -uo pipefail
cd "$(dirname "$0")"

restore_term() {
  printf '\e[?1049l\e[?25h\e[?1000l\e[?1003l\e[?1006l\e[0m' 2>/dev/null || true
  stty sane 2>/dev/null || true
}
trap restore_term EXIT INT TERM

pixi run mojo run -I src "$@"
