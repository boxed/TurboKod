#!/usr/bin/env bash
# Integration check for the kill-on-parent-death shim.
#
# Builds + runs ``sighup_self_test.mojo``, captures the sleep child's
# PID off its first stdout line, sends SIGHUP to the mojo parent, and
# verifies the sleep child was killed within a small grace window. If
# the shim's signal handler isn't wired up, the sleep survives as an
# orphan reparented to launchd / init — exactly the bug we're guarding
# against.

set -uo pipefail

cd "$(dirname "$0")/.."

# Build (cached if up-to-date) and exec the self-test in the
# background. We can't use ``./run.sh`` directly because it ``exec``s
# into the binary — we want a PID we own, not the shell's.
# stderr goes to a separate file so the noisy ``[run.sh] building …``
# line on a cold build doesn't get parsed as the sleep PID.
./run.sh tests/sighup_self_test.mojo \
  >/tmp/sighup_self_test.out 2>/tmp/sighup_self_test.err &
parent=$!

# Wait for the child to print its sleep PID. Bounded poll: 5s. The
# self-test prints exactly one numeric line then sleeps; tolerate
# blank lines but reject anything non-numeric so misbehavior fails
# loudly rather than racing on a stale file.
sleep_pid=""
for _ in $(seq 1 50); do
  if [ -s /tmp/sighup_self_test.out ]; then
    candidate=$(grep -m1 -E '^[0-9]+$' /tmp/sighup_self_test.out 2>/dev/null)
    if [[ "$candidate" =~ ^[0-9]+$ ]]; then
      sleep_pid="$candidate"
      break
    fi
  fi
  sleep 0.1
done

if [[ ! "$sleep_pid" =~ ^[0-9]+$ ]]; then
  echo "FAIL: never saw sleep PID on stdout" >&2
  cat /tmp/sighup_self_test.out >&2
  kill -KILL "$parent" 2>/dev/null
  exit 1
fi

# Confirm the sleep is alive *before* we hang up the parent — sanity
# check that we're testing what we think we are.
if ! kill -0 "$sleep_pid" 2>/dev/null; then
  echo "FAIL: sleep $sleep_pid not alive before SIGHUP" >&2
  exit 1
fi

# Send SIGHUP to the parent. The shim's handler should walk the
# tracked-PID registry, SIGTERM the sleep, and re-raise SIGHUP.
kill -HUP "$parent"
wait "$parent" 2>/dev/null

# Grace window for SIGTERM delivery + sleep exit. 1s is generous.
gone=0
for _ in $(seq 1 20); do
  if ! kill -0 "$sleep_pid" 2>/dev/null; then
    gone=1
    break
  fi
  sleep 0.05
done

if [ "$gone" -ne 1 ]; then
  echo "FAIL: sleep $sleep_pid still alive 1s after parent SIGHUP" >&2
  kill -KILL "$sleep_pid" 2>/dev/null
  exit 1
fi

echo "ok: sleep $sleep_pid killed when parent received SIGHUP"
