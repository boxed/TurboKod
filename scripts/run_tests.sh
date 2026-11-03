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
#   2. RUN the binaries phase 1 built — directly, not through ``run.sh``,
#      which would rebuild (one suite at a time) any suite whose sources
#      changed since, and run code the warning gate never saw. Concurrently
#      too: each process gets its own scratch $HOME and temp dirs (see
#      ``setup_test_env`` in support.mojo). Each suite's output goes to its
#      own log and the summary prints in suite order, so it stays readable.
#
# Usage:
#   scripts/run_tests.sh              # all suites
#   scripts/run_tests.sh git editor   # only suites whose name matches a filter
#
# A single test: ./run.sh tests/test_git.mojo --only <test_name>
set -uo pipefail

# Absolute path to this script, resolved *before* the cd so the parallel build
# step below can re-invoke it (see ``--build-one``) from any working directory.
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

# Build concurrency. Mojo is itself multi-threaded, so oversubscribing hurts;
# a quarter of the cores per job is about right.
JOBS="${JOBS:-4}"
# Run concurrency. Suites are mostly single-threaded and seconds long.
RUN_JOBS="${RUN_JOBS:-4}"

# Internal: build a single suite. Re-invoking ourselves is what keeps the
# xargs command line short — an inline ``sh -c`` body long enough to do the
# logging and error reporting trips BSD xargs' "command line cannot be
# assembled, too long" limit under ``-I``.
. scripts/lib.sh
if [ "${1:-}" = "--build-one" ]; then
  build_entry_logged "$2" .build/test-logs .build.log
  exit $?
fi
# Internal: run one built suite, its output to ``<name>.run.log`` and its
# exit status to ``<name>.rc``.
if [ "${1:-}" = "--run-one" ]; then
  name=$(basename "$2" .mojo)
  "$(entry_bin "$PWD/$2")" > ".build/test-logs/$name.run.log" 2>&1
  echo $? > ".build/test-logs/$name.rc"
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

# The shim (and libghostty-vt under it) once, serially: every parallel
# ``run.sh`` below would otherwise race to build it from a cold checkout.
ensure_shim "$(basename "$0")" || exit 1
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

# The slowest builds, for knowing where build time goes.
echo "==> slowest builds:"
for f in "${suites[@]}"; do
  name=$(basename "$f" .mojo)
  printf '%s %s\n' "$(cat "$log_dir/$name.build.log.secs" 2>/dev/null || echo 0)" "$name"
done | sort -rn | head -5 | while read -r secs name; do
  printf '      %-22s %ss\n' "$name" "$secs"
done

# The suites link libonig from the pixi env, as ``run.sh`` arranges.
env_prefix="$(resolve_env_prefix)"
export DYLD_LIBRARY_PATH="${env_prefix}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="${env_prefix}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
run_start=$(date +%s)
for f in "${suites[@]}"; do
  rm -f "$log_dir/$(basename "$f" .mojo).rc"
done
printf '%s\n' "${suites[@]}" | xargs -P "$RUN_JOBS" -n1 "$self" --run-one
echo "==> ran in $(( $(date +%s) - run_start ))s"

failed=()
total=0
for f in "${suites[@]}"; do
  name=$(basename "$f" .mojo)
  out=$(cat "$log_dir/$name.run.log" 2>/dev/null)
  rc=$(cat "$log_dir/$name.rc" 2>/dev/null || echo 1)
  # Suites run under std.testing.TestSuite, which ends with a line like
  # ``Summary [ 25355.780 ] 144 tests run: 144 passed , 0 failed , 0 skipped``.
  summary=$(printf '%s\n' "$out" | grep '^Summary' | tail -1)
  if [ "$rc" -ne 0 ]; then
    failed+=("$name")
    printf '  FAIL  %-22s\n' "$name"
    # Everything but the per-test PASS lines: the FAIL entries with their
    # assertion detail, the summary, or a build/crash message.
    printf '%s\n' "$out" | grep -v '^ *PASS ' | head -60 | sed 's/^/        /'
  else
    n=$(printf '%s' "$summary" | sed -n 's/.* \([0-9]*\) passed .*/\1/p')
    secs=$(printf '%s' "$summary" | sed -n 's/^Summary \[ *\([0-9]*\)\.[0-9]* \].*/\1/p')
    printf '  ok    %-22s %s tests (%ss)\n' "$name" "${n:-?}" "$(( ${secs:-0} / 1000 ))"
    total=$(( total + ${n:-0} ))
  fi
done

if [ "${#failed[@]}" -ne 0 ]; then
  echo "==> ${#failed[@]} suite(s) failed: ${failed[*]}" >&2
  exit 1
fi
echo "==> all ${#suites[@]} suites passed ($total tests)"
