#!/usr/bin/env bash
# Sample the running TurboKod.app and report a function-level CPU breakdown.
#
# The Mojo drawing path is profilable headless via tests/bench_draw.mojo, but
# the Swift/AppKit half (Core Text rasterization in CellView.draw) only exists
# in the live GUI process. This attaches macOS's `sample` profiler to it.
#
# Usage:
#   1. Launch the app:           ./run_swift.sh /path/to/project
#   2. While doing the workload (e.g. wiggling the mouse continuously),
#      run:                      scripts/profile_app.sh [seconds]
#   3. Read the report it prints (and /tmp/turbokod_sample.txt).
#
# Tip: run it once while moving the mouse and once while idle to compare.

set -euo pipefail
DUR="${1:-10}"
PID="$(pgrep -x TurboKod | head -1 || true)"
if [[ -z "${PID}" ]]; then
  echo "TurboKod is not running. Launch it with ./run_swift.sh first." >&2
  exit 1
fi
echo "Sampling TurboKod (pid ${PID}) for ${DUR}s @1ms — exercise the workload now..."
sample "${PID}" "${DUR}" 1 -file /tmp/turbokod_sample.txt >/dev/null
echo
echo "=== top self-time (on-CPU) functions across ALL libraries ==="
echo "    (kernel wait / __workq / mach_msg = parked threads = idle, ignore)"
python3 - <<'PY'
import re, collections
agg = collections.Counter()
insec = False
for line in open('/tmp/turbokod_sample.txt'):
    if 'Sort by top of stack' in line:
        insec = True; continue
    if insec and line.startswith('Binary Images'):
        break
    if not insec:
        continue
    m = re.match(r'\s*(.+?)\s+\(in ([^)]+)\)\s+(\d+)\s*$', line)
    if not m:
        continue
    sym, lib, cnt = m.group(1), m.group(2), int(m.group(3))
    sym = sym.split('(')[0].strip()          # drop arg lists
    # collapse Mojo List copy/free spam into one bucket
    if sym.startswith('$') or '_REMOVED_ARG' in sym:
        sym = 'List<...> copy (Span ctor)'
    if 'List::__del__' in sym:
        sym = 'List<...> __del__'
    agg[(sym, lib)] += cnt
total = sum(agg.values())
print(f"total on-CPU samples: {total}\n")
for (sym, lib), c in agg.most_common(25):
    print(f"{100*c/total:5.1f}%  {c:6d}  {sym}   [{lib}]")
PY
echo
echo "Full report: /tmp/turbokod_sample.txt"
