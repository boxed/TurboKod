#!/usr/bin/env bash
#
# Build the README / docs screenshots of the native macOS app:
#
#   docs/screenshots/theme-<slug>.png   one per built-in theme
#   screenshot.png                      hero: debug session paused at a
#                                       breakpoint in the repo's own test
#                                       suite (default theme)
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

# Give the app a moment to open the project / settle layout / finish the
# first highlight pass before the grab.
export TK_CAPTURE_DELAY="${TK_CAPTURE_DELAY:-1.5}"

# Build everything up front so the per-shot launches hit warm caches.
TURBOKOD_BUILD_ONLY=1 ./run_swift.sh
TURBOKOD_BUILD_ONLY=1 ./run.sh tests/test_basic.mojo

# ---------------------------------------------------------------- themes --
# Same scene for every theme: the project open with the editor on a meaty
# function, so the shots differ only in palette. Anchored by grep, not a
# hard-coded line, so the scene survives edits to editor.mojo.
scene_file="$root/src/turbokod/editor.mojo"
scene_line="$(grep -n 'def handle_key' "$scene_file" | head -1 | cut -d: -f1)"

capture_theme() {  # <out-slug> <theme-name>
  local slug="$1" theme="$2"
  echo "[screenshots] theme '$theme' -> $out/theme-$slug.png"
  TK_THEME="$theme" \
  TK_OPEN="${scene_file}:${scene_line}" \
  TK_CAPTURE="$out/theme-$slug.png" \
    ./run_swift.sh "$root"
}

# Keep in sync with theme.mojo's built_in_themes().
capture_theme turbo-cpp-3      "Turbo C++ 3.0"
capture_theme monokai          "Monokai"
capture_theme dracula          "Dracula"
capture_theme one-dark         "One Dark"
capture_theme gruvbox-dark     "Gruvbox Dark"
capture_theme solarized-dark   "Solarized Dark"
capture_theme solarized-light  "Solarized Light"
capture_theme github-light     "GitHub Light"
capture_theme one-light        "One Light"
capture_theme turbo-pascal-7   "Turbo Pascal 7"
capture_theme norton-commander "Norton Commander"
capture_theme qbasic           "QBasic"

# -------------------------------------------------------- debugger (hero) --
# Mirror run.sh's binary cache key: basename + short hash of the absolute
# entry-point path.
test_src="$root/tests/test_basic.mojo"
hash="$(printf '%s' "$test_src" | shasum -a 256 | cut -c1-8)"
test_bin="$root/.build/test_basic_${hash}"
[ -x "$test_bin" ] || { echo "[screenshots] missing $test_bin" >&2; exit 1; }

targets="$root/.turbokod/targets.json"
bps="$root/.turbokod/per_user/$(id -un)/breakpoints.json"
mkdir -p "$(dirname "$bps")"

# Stage targets + breakpoints; put the user's own files back no matter how
# we exit. A missing original means "remove the staged file on exit".
restore() {
  for f in "$targets" "$bps"; do
    if [ -f "$f.screenshots-bak" ]; then mv "$f.screenshots-bak" "$f"
    else rm -f "$f"; fi
  done
}
trap restore EXIT
if [ -f "$targets" ]; then cp "$targets" "$targets.screenshots-bak"; fi
if [ -f "$bps" ];     then cp "$bps"     "$bps.screenshots-bak"; fi

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
bp_line="$(grep -n '^def test_' "$test_src" | head -1 | cut -d: -f1)"

echo "[screenshots] debugger paused at $test_src:$bp_line -> $root/screenshot.png"
TK_THEME="Turbo C++ 3.0" \
TK_OPEN="${test_src}:${bp_line}" \
TK_CAPTURE_ACTIONS="debug:toggle_bp,debug:start_or_continue" \
TK_CAPTURE_WHEN="debug-stopped" \
TK_CAPTURE="$root/screenshot.png" \
  ./run_swift.sh "$root"

echo "[screenshots] done -> $out/ + screenshot.png"
