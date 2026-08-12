#!/usr/bin/env bash
# Full pre-commit sweep: build EVERY entry point in the repo, run every test
# suite, and fail on a single compiler warning.
#
# Why this exists: Mojo only reports warnings for files in the *current*
# build's import graph, so no single build sees all of them. `make` builds two
# entry points (the dylib and examples/desktop.mojo) and `scripts/run_tests.sh`
# builds the test suites — which between them still leave `bench/*.mojo` and
# most of `examples/*.mojo` compiled by nothing at all. Warnings rotted there
# unnoticed until a toolchain bump surfaced them.
#
# Usage:
#   scripts/check_all.sh          # everything
#   scripts/check_all.sh --quick  # skip running the test suites (build only)
set -uo pipefail

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

# Internal: build one entry point. Re-invoking ourselves keeps the xargs
# command line short (same trick as run_tests.sh).
if [ "${1:-}" = "--build-one" ]; then
  f="$2"
  name="$(basename "$f" .mojo)"
  mkdir -p .build/entry-logs
  if ! TURBOKOD_BUILD_ONLY=1 ./run.sh "$f" > ".build/entry-logs/$name.log" 2>&1; then
    echo "BUILD FAILED: $f" >&2
    tail -30 ".build/entry-logs/$name.log" >&2
    exit 1
  fi
  exit 0
fi

quick=0
[ "${1:-}" = "--quick" ] && quick=1

JOBS="${JOBS:-4}"
log_dir=".build/entry-logs"
rm -rf "$log_dir"
mkdir -p "$log_dir"
fail=0

# --- 1. every standalone entry point -------------------------------------
# examples/ and bench/ are the ones no other target compiles.
entries=(examples/*.mojo bench/*.mojo)
echo "==> building ${#entries[@]} entry point(s) with -j$JOBS"
printf '%s\n' "${entries[@]}" | xargs -P "$JOBS" -n1 "$self" --build-one \
  || fail=1

# --- 2. native macOS path (dylib + Swift + tk-tui) -----------------------
# native_api.mojo is compiled ONLY here, so its warnings appear nowhere else.
echo "==> building native macOS frontend"
if ! TURBOKOD_BUILD_ONLY=1 ./run_swift.sh > "$log_dir/_swift.log" 2>&1; then
  echo "BUILD FAILED: native macOS frontend" >&2
  tail -30 "$log_dir/_swift.log" >&2
  fail=1
fi

# --- 3. test suites ------------------------------------------------------
# run_tests.sh gates warnings for its own build logs and runs the tests.
if [ "$quick" -eq 0 ]; then
  echo "==> building + running test suites"
  scripts/run_tests.sh || fail=1
fi

# --- 4. the warning gate -------------------------------------------------
# Hard rule (see CLAUDE.md "Keep the build warning-free"): zero, not "no new".
warnings="$(grep -h "warning:" "$log_dir"/*.log .build/test-logs/*.build.log \
  2>/dev/null | sort -u)"
if [ -n "$warnings" ]; then
  echo
  echo "==> compiler warnings (must be zero):" >&2
  printf '%s\n' "$warnings" >&2
  echo "==> $(printf '%s\n' "$warnings" | wc -l | tr -d ' ') unique warning(s)" >&2
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "==> check_all: OK (every entry point builds, zero warnings)"
else
  echo "==> check_all: FAILED" >&2
fi
exit "$fail"
