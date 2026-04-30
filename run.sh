#!/usr/bin/env bash
# Convenience wrapper: `./run.sh examples/hello.mojo` or `./run.sh tests/test_basic.mojo`.
#
# Builds the entry point with `mojo build -I src` and runs the resulting
# native binary. Build artifacts are cached under `.build/` keyed by the
# source path so repeat runs are zero-cost when no source has changed.
# We use `mojo build` (not `mojo run`) because `mojo run` is JIT-only and
# silently ignores `-Xlinker` — the build step is what makes linking
# against C libraries (e.g. libonig for TextMate-grammar syntax
# highlighting) actually work.
#
# Restores the terminal on EXIT / INT / TERM so a hung process killed
# with ``kill <pid>`` (or even ``Ctrl+C`` while the app is in raw mode)
# doesn't leave you with a wedged shell. ``stty sane`` re-enables
# canonical mode + echo, the printf unrolls alt-screen / mouse-tracking
# / SGR / hidden-cursor — the mirror of what ``Terminal.stop()`` would
# have done if it had a chance to run.
set -uo pipefail

# Resolve relative path arguments to absolute *before* cd, so paths the
# user typed (often relative to a different cwd, e.g. ``app/`` for the
# native wrapper) survive the directory change. Non-path args are passed
# through untouched — the ``-e`` existence check is the disambiguator.
args=()
for arg in "$@"; do
  if [[ "$arg" == /* ]] || [[ ! -e "$arg" ]]; then
    args+=("$arg")
  else
    args+=("$(cd "$(dirname -- "$arg")" && pwd)/$(basename -- "$arg")")
  fi
done

cd "$(dirname "$0")"

if [ "${#args[@]}" -eq 0 ]; then
  echo "usage: ./run.sh <entry.mojo> [program-args...]" >&2
  exit 2
fi

src="${args[0]}"
prog_args=("${args[@]:1}")

# Cache key: basename + short hash of the absolute path, so two files
# with the same basename in different dirs (``examples/desktop.mojo`` vs
# ``tests/desktop.mojo``) don't clobber each other's binary.
mkdir -p .build
hash="$(printf '%s' "$src" | shasum -a 256 | cut -c1-8)"
bin=".build/$(basename -- "$src" .mojo)_${hash}"

# Skip the build when the cached binary is newer than every Mojo source
# in ``src/`` and the entry point itself. ``find -newer`` returns the
# first match and we short-circuit on -print -quit, so this scales fine
# as the package grows.
needs_build=1
if [ -x "$bin" ]; then
  newer=$(find src "$src" -name '*.mojo' -newer "$bin" -print -quit 2>/dev/null)
  if [ -z "$newer" ]; then
    needs_build=0
  fi
fi

restore_term() {
  printf '\e[?1049l\e[?25h\e[?1000l\e[?1003l\e[?1006l\e[0m' 2>/dev/null || true
  stty sane 2>/dev/null || true
}
trap restore_term EXIT INT TERM

if [ "$needs_build" -eq 1 ]; then
  echo "[run.sh] building $src -> $bin" >&2
  pixi run mojo build -I src -o "$bin" "$src"
fi

exec "$bin" ${prog_args[@]+"${prog_args[@]}"}
