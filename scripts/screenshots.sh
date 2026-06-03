#!/usr/bin/env bash
#
# Build the README / docs screenshots of the native macOS app:
#
#   docs/screenshots/theme-<slug>.png   one per built-in theme
#   screenshot.png                      hero: debug session paused at a
#                                       breakpoint in the repo's own test
#                                       suite, file tree docked right
#                                       (default theme)
#
# Everything is driven through env knobs the app honors when TK_CAPTURE is
# set (see "scripted screenshot capture" in app/swift/TurboKod.swift):
#
#   TK_CAPTURE=<png>            render one frame to <png>, then quit
#   TK_THEME=<name>             theme for this process only (not persisted)
#   TK_OPEN=<abs-path>:<line>   open a file at a 1-based line
#   TK_CAPTURE_ACTIONS=a,b      menu actions to invoke before the grab
#   TK_CAPTURE_WHEN=debug-stopped   wait until the debugger is paused
#   TK_CAPTURE_DELAY=<secs>     extra settle before the grab
#
# The debugger shot stages a temporary .turbokod/targets.json pointing at the
# built test binary (lldb-dap debugs it via the "cpp" adapter — Mojo binaries
# carry regular DWARF) and an empty breakpoint store, then sets a breakpoint
# on the first test function and F5s. Your real targets.json / breakpoints
# are backed up and restored on exit.
#
# Needs a real display (Core Text + a window) — run it locally on macOS, not
# headless / over SSH / in CI, or the capture comes out blank. lldb-dap must
# be on $PATH for the debugger shot (ships with Xcode 15+).
#
# Usage:
#   scripts/screenshots.sh [out-dir]      # default: docs/screenshots
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

out="${1:-docs/screenshots}"
mkdir -p "$out"
# The app chdir's to its bundle Resources dir on launch, so TK_CAPTURE
# must be absolute or the PNG lands inside (or fails to write into) the
# bundle.
case "$out" in /*) ;; *) out="$root/$out" ;; esac

# Give the app a moment to open the project / settle layout / finish the
# first highlight pass before the grab.
export TK_CAPTURE_DELAY="${TK_CAPTURE_DELAY:-1.5}"

# Build everything up front so the per-shot launches hit warm caches.
# The test binary needs line tables (TURBOKOD_DEBUG_INFO) or lldb can't
# bind the staged breakpoint and the debugger shot runs straight through.
TURBOKOD_BUILD_ONLY=1 ./run_swift.sh
TURBOKOD_DEBUG_INFO=1 TURBOKOD_BUILD_ONLY=1 ./run.sh tests/test_basic.mojo

# ---------------------------------------------------------------- themes --
# Same scene for every theme: the project open with the editor on a meaty
# function, so the shots differ only in palette. Anchored by grep, not a
# hard-coded line, so the scene survives edits to editor.mojo.
scene_file="$root/src/turbokod/editor.mojo"
scene_line="$(grep -n -m1 'def handle_key' "$scene_file" | cut -d: -f1)"

capture_theme() {  # <out-slug> <theme-name>
  local slug="$1" theme="$2"
  echo "[screenshots] theme '$theme' -> $out/theme-$slug.png"
  TK_THEME="$theme" \
  TK_OPEN="${scene_file}:${scene_line}" \
  TK_CAPTURE="$out/theme-$slug.png" \
    ./run_swift.sh "$root"
}

# One dark + one light example is enough for the docs — the hero shot
# already shows the default Turbo C++ 3.0. Names must match
# theme.mojo's built_in_themes().
capture_theme dracula          "Dracula"
capture_theme solarized-light  "Solarized Light"

# -------------------------------------------------------- debugger (hero) --
# Prefer Xcode's real lldb-dap over whatever shims sit first on PATH — the
# swiftly multiplexer symlinks `lldb-dap` to itself and hangs in DAP
# `initialize` when spawned from the app.
if xcdap="$(xcrun -f lldb-dap 2>/dev/null)"; then
  export PATH="$(dirname "$xcdap"):$PATH"
fi

# Mirror run.sh's binary cache key: basename + short hash of the absolute
# entry-point path, ``_g`` suffix for the debug-info build.
test_src="$root/tests/test_basic.mojo"
hash="$(printf '%s' "$test_src" | shasum -a 256 | cut -c1-8)"
test_bin="$root/.build/test_basic_${hash}_g"
[ -x "$test_bin" ] || { echo "[screenshots] missing $test_bin" >&2; exit 1; }

targets="$root/.turbokod/targets.json"
bps="$root/.turbokod/per_user/$(id -un)/breakpoints.json"
session="$root/.turbokod/per_user/$(id -un)/session.json"
mkdir -p "$(dirname "$bps")"

# Stage targets + breakpoints + session; put the user's own files back no
# matter how we exit. A missing original means "remove the staged file on
# exit".
restore() {
  for f in "$targets" "$bps" "$session"; do
    if [ -f "$f.screenshots-bak" ]; then mv "$f.screenshots-bak" "$f"
    else rm -f "$f"; fi
  done
}
trap restore EXIT
if [ -f "$targets" ]; then cp "$targets" "$targets.screenshots-bak"; fi
if [ -f "$bps" ];     then cp "$bps"     "$bps.screenshots-bak"; fi
if [ -f "$session" ]; then cp "$session" "$session.screenshots-bak"; fi

cat > "$targets" <<EOF
{
  "active": "tests (debug)",
  "targets": [
    { "name":     "tests (debug)",
      "program":  "$test_bin",
      "args":     [],
      "cwd":      "",
      "language": "cpp" }
  ]
}
EOF
printf '{"breakpoints":[]}' > "$bps"

# Breakpoint on the first test function — hit within moments of launch, and
# the paused stack shows main → the test. Anchored by grep so the shot
# survives the suite growing.
bp_line="$(grep -n -m1 '^def test_' "$test_src" | cut -d: -f1)"

# Stage the scene as a session: two cascaded, non-maximized windows so the
# shot shows window chrome + drop shadows + the desktop behind them —
# editor.mojo behind, the test suite in front with the cursor parked on the
# breakpoint line (debug:toggle_bp toggles at the cursor). Rects are cell
# coords; restore clips them to the actual workspace, so a smaller grid
# still produces a sane layout. Session cursor/scroll are 0-based.
cat > "$session" <<EOF
{
  "focused": 1,
  "z_order": [0, 1],
  "windows": [
    { "path": "src/turbokod/editor.mojo",
      "rect": [3, 1, 128, 62], "maximized": false,
      "restore_rect": [3, 1, 128, 62],
      "cursor": [$((scene_line - 1)), 0],
      "scroll": [0, $((scene_line > 6 ? scene_line - 6 : 0))] },
    { "path": "tests/test_basic.mojo",
      "rect": [12, 6, 137, 68], "maximized": false,
      "restore_rect": [12, 6, 137, 68],
      "cursor": [$((bp_line - 1)), 0],
      "scroll": [0, $((bp_line > 6 ? bp_line - 6 : 0))] }
  ]
}
EOF

echo "[screenshots] debugger paused at $test_src:$bp_line -> $root/screenshot.png"
# The tree toggle fires first (one step of the hidden→right→left cycle
# docks it on the right) so the workspace refits the two windows before
# the breakpoint + launch actions run.
TK_THEME="Turbo C++ 3.0" \
TK_MENU_INGRID=1 \
TK_CAPTURE_ACTIONS="project:tree:toggle,debug:toggle_bp,debug:start_or_continue" \
TK_CAPTURE_WHEN="debug-stopped" \
TK_CAPTURE="$root/screenshot.png" \
  ./run_swift.sh "$root"

echo "[screenshots] done -> $out/ + screenshot.png"
