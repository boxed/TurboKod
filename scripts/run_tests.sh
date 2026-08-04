#!/usr/bin/env bash
# Build and run every headless test suite under tests/.
#
# The suite used to be a single 23k-line ``tests/test_basic.mojo``. That file
# grew past a compile-time cliff in the Mojo compiler — a full ``mojo build``
# took over two hours, so nobody ran it. It's now one entry point per topic
# (``tests/test_<topic>.mojo``, shared fixtures in ``tests/support.mojo``),
# which builds in ~3 minutes wall clock.
#
# Two phases, deliberately:
#   1. BUILD all suites concurrently. Separate ``mojo build`` invocations with
#      separate outputs, so they only contend for CPU.
#   2. RUN them one at a time. Suites share a scratch $HOME
#      (/tmp/turbokod_test_home — see ``setup_test_env`` in support.mojo) and
#      a couple of tests write config files into it, so concurrent runs would
#      race. Running is fast; only the build needed parallelising.
#
# Usage:
#   scripts/run_tests.sh              # all suites
#   scripts/run_tests.sh git editor   # only suites whose name matches a filter
set -uo pipefail

# Absolute path to this script, resolved *before* the cd so the parallel build
# step below can re-invoke it (see ``--build-one``) from any working directory.
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

# Build concurrency. Mojo is itself multi-threaded, so oversubscribing hurts;
# a quarter of the cores per job is about right.
JOBS="${JOBS:-4}"

# Internal: build a single suite. Re-invoking ourselves is what keeps the
# xargs command line short — an inline ``sh -c`` body long enough to do the
# logging and error reporting trips BSD xargs' "command line cannot be
# assembled, too long" limit under ``-I``.
if [ "${1:-}" = "--build-one" ]; then
  f="$2"
  name="$(basename "$f" .mojo)"
  mkdir -p .build/test-logs
  if ! TURBOKOD_BUILD_ONLY=1 ./run.sh "$f" > ".build/test-logs/$name.build.log" 2>&1
  then
    echo "BUILD FAILED: $f" >&2
    tail -30 ".build/test-logs/$name.build.log" >&2
    exit 1
  fi
  exit 0
fi

suites=()
for f in tests/test_*.mojo; do
  if [ "$#" -eq 0 ]; then
    suites+=("$f")
  else
    for pat in "$@"; do
      case "$f" in *"$pat"*) suites+=("$f"); break;; esac
    done
  fi
done

if [ "${#suites[@]}" -eq 0 ]; then
  echo "no test suites matched: $*" >&2
  exit 2
fi

log_dir=".build/test-logs"
mkdir -p "$log_dir"

echo "==> building ${#suites[@]} suite(s) with -j$JOBS"
build_start=$(date +%s)
printf '%s\n' "${suites[@]}" | xargs -P "$JOBS" -n1 "$self" --build-one
build_rc=$?
echo "==> build finished in $(( $(date +%s) - build_start ))s"
if [ "$build_rc" -ne 0 ]; then
  echo "==> aborting: a suite failed to build" >&2
  exit 1
fi

# Any compiler warning is a hard failure — see CLAUDE.md "Keep the build
# warning-free". Catching it here means a warning can't hide in a log nobody
# opens.
if grep -l "warning:" "$log_dir"/*.build.log 2>/dev/null | grep -q .; then
  echo "==> compiler warnings (must be zero):" >&2
  grep -h "warning:" "$log_dir"/*.build.log | sort -u >&2
  exit 1
fi

failed=()
total=0
for f in "${suites[@]}"; do
  name=$(basename "$f" .mojo)
  out=$(./run.sh "$f" 2>&1)
  rc=$?
  last=$(printf '%s' "$out" | tail -1)
  if [ "$rc" -ne 0 ]; then
    failed+=("$name")
    printf '  FAIL  %-22s\n' "$name"
    printf '%s\n' "$out" | tail -12 | sed 's/^/        /'
  else
    printf '  ok    %-22s %s\n' "$name" "$last"
    n=$(printf '%s' "$last" | sed -n 's/.*: \([0-9]*\) tests passed/\1/p')
    total=$(( total + ${n:-0} ))
  fi
done

if [ "${#failed[@]}" -ne 0 ]; then
  echo "==> ${#failed[@]} suite(s) failed: ${failed[*]}" >&2
  exit 1
fi
echo "==> all ${#suites[@]} suites passed ($total tests)"
