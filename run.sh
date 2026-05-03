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
# in ``src/``, the entry point itself, and the C shims linked into it
# (a shim rebuild needs a binary rebuild — they're statically linked).
# ``find -newer`` returns the first match and we short-circuit on
# -print -quit, so this scales fine as the package grows.
needs_build=1
if [ -x "$bin" ]; then
  newer=$(find src "$src" -name '*.mojo' -newer "$bin" -print -quit 2>/dev/null)
  if [ -z "$newer" ] \
     && [ ! "src/turbokod/onig_shim.c" -nt "$bin" ] \
     && [ ! "src/turbokod/process_shim.c" -nt "$bin" ]; then
    needs_build=0
  fi
fi

restore_term() {
  printf '\e[?1049l\e[?25h\e[?1000l\e[?1003l\e[?1006l\e[0m' 2>/dev/null || true
  stty sane 2>/dev/null || true
}
trap restore_term EXIT INT TERM

# Resolve the pixi env's lib/include dirs once. We need:
#   * ``-Lenv/lib -lonig`` at link time so the build resolves libonig
#     symbols (used by the TextMate-grammar highlighter via FFI).
#   * ``DYLD/LD_LIBRARY_PATH=env/lib`` at exec time so the resulting
#     dylib reference resolves when the binary actually runs.
# ``pixi info`` is the supported way to ask for the env path; fall back
# to the conventional location when not available so this still works
# in CI / headless setups that pre-populate ``.pixi``.
env_prefix="$(pixi info --json 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["environments_info"][0]["prefix"])' \
  2>/dev/null)"
if [ -z "${env_prefix:-}" ]; then
  env_prefix="$(pwd)/.pixi/envs/default"
fi

# Compile the C shims:
#   * ``onig_shim``    — process-exit registry that batches the
#                         ``onig_free`` calls we can't safely run from
#                         Mojo's per-instance ``__del__``.
#   * ``process_shim`` — kill-on-parent-death registry: SIGTERMs every
#                         spawned child PID on SIGHUP / SIGTERM / clean
#                         exit, so quitting the macOS app while a Run /
#                         Debug session is active doesn't orphan it.
# Each rebuilds only when its .c is newer than the cached object;
# they're tiny and rarely change.
onig_src="src/turbokod/onig_shim.c"
onig_obj=".build/onig_shim.o"
if [ ! -f "$onig_obj" ] || [ "$onig_src" -nt "$onig_obj" ]; then
  echo "[run.sh] compiling onig shim -> $onig_obj" >&2
  if ! clang -c -O2 -fPIC "$onig_src" -o "$onig_obj"; then
    echo "[run.sh] onig shim compilation failed; aborting (would otherwise run a stale binary)" >&2
    exit 1
  fi
fi
proc_src="src/turbokod/process_shim.c"
proc_obj=".build/process_shim.o"
if [ ! -f "$proc_obj" ] || [ "$proc_src" -nt "$proc_obj" ]; then
  echo "[run.sh] compiling process shim -> $proc_obj" >&2
  if ! clang -c -O2 -fPIC "$proc_src" -o "$proc_obj"; then
    echo "[run.sh] process shim compilation failed; aborting (would otherwise run a stale binary)" >&2
    exit 1
  fi
fi

if [ "$needs_build" -eq 1 ]; then
  echo "[run.sh] building $src -> $bin" >&2
  if ! pixi run mojo build \
    -I src \
    -Xlinker "-L${env_prefix}/lib" \
    -Xlinker "-lonig" \
    -Xlinker "$onig_obj" \
    -Xlinker "$proc_obj" \
    -o "$bin" "$src"; then
    # Without this guard, ``exec "$bin"`` below would silently run the
    # previous successful build — making "all tests passed" mean
    # "nothing changed since the last build that worked." Ask me how I
    # know.
    echo "[run.sh] mojo build failed; aborting (would otherwise run a stale binary)" >&2
    exit 1
  fi
fi

# macOS uses DYLD_LIBRARY_PATH, Linux uses LD_LIBRARY_PATH; setting both
# is harmless on whichever platform isn't relevant.
export DYLD_LIBRARY_PATH="${env_prefix}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="${env_prefix}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$bin" ${prog_args[@]+"${prog_args[@]}"}
