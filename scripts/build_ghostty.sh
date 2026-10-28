#!/usr/bin/env bash
# Build libghostty-vt — the terminal emulator behind the shell and test panes
# (see docs/terminal-emulation.md) — at a pinned Ghostty commit.
#
#   scripts/build_ghostty.sh          # no-op when the pinned build is present
#
# Output: ``.build/ghostty/{lib/libghostty-vt.a,include/ghostty/}``. The Rust
# shim's build.rs links the static lib into ``libturbokod_shim.a``, so every
# Mojo binary that links the shim (tests, the terminal frontend, the dylib)
# gets it with no change to its link line.
#
# The API is explicitly unstable ("definitely going to change", per the
# header), so the commit is pinned and bumping it is a deliberate act: change
# ``GHOSTTY_COMMIT``, rebuild, and fix whatever ``app/turbokod-shim/src/tk_vt.c``
# no longer compiles against. That file is the only code that sees Ghostty's
# headers.
#
# Zig comes from the pixi env (``pixi.toml``), and its caches live under
# ``.build/`` rather than ``~/.cache/zig`` so the disk use stays attributable
# to this checkout. A cold build is ~2 minutes; it reruns only when the pin
# changes.
set -euo pipefail

GHOSTTY_COMMIT="6ba144158577d033ccb6ed4b574e4013957c9161"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty"

cd "$(dirname "$0")/.."
root="$(pwd)"
src="$root/.build/ghostty-src"
out="$root/.build/ghostty"
stamp="$out/.commit"

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$GHOSTTY_COMMIT" ] \
    && [ -f "$out/lib/libghostty-vt.a" ]; then
  exit 0
fi

echo "[ghostty] building libghostty-vt @ ${GHOSTTY_COMMIT:0:12}" >&2
if [ ! -d "$src/.git" ]; then
  git init -q "$src"
  git -C "$src" remote add origin "$GHOSTTY_REPO"
fi
if [ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$GHOSTTY_COMMIT" ]; then
  git -C "$src" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$src" checkout -q --detach FETCH_HEAD
fi

rm -rf "$out"
export ZIG_GLOBAL_CACHE_DIR="$root/.build/zig-cache/global"
export ZIG_LOCAL_CACHE_DIR="$root/.build/zig-cache/local"
( cd "$src" && pixi run --manifest-path "$root/pixi.toml" zig build \
    -Demit-lib-vt=true -Doptimize=ReleaseFast -p "$out" )
echo "$GHOSTTY_COMMIT" > "$stamp"
