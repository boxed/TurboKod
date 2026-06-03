#!/usr/bin/env bash
#
# Capture doc screenshots of TurboKod in several themes.
#
# The native app renders one frame to a PNG when TK_CAPTURE is set (see
# capturePNG in app/swift/TurboKod.swift), and TK_THEME picks the color theme
# for that process without touching the saved config. We drive the same scene
# through a few themes so the docs can show what theming actually does.
#
# Needs a real display (Core Text + a window) — run it locally on macOS, not
# headless / over SSH / in CI, or the capture comes out blank.
#
# Usage:
#   scripts/screenshots.sh [project-path] [out-dir]
# Defaults: project = this repo, out-dir = docs/.
set -euo pipefail
cd "$(dirname "$0")/.."

project="${1:-$PWD}"
out="${2:-docs}"
mkdir -p "$out"

# Give the app a moment to open the project / settle layout before the grab.
export TK_CAPTURE_DELAY="${TK_CAPTURE_DELAY:-1.5}"

capture() {  # <out-name> <theme-name>
  local name="$1" theme="$2"
  echo "[screenshots] capturing '$theme' -> $out/$name.png"
  TK_THEME="$theme" TK_CAPTURE="$out/$name.png" ./run_swift.sh "$project"
}

# Add/trim rows here to cover more themes in the docs. Names must match
# theme.mojo's built_in_themes().
capture screenshot-turbo    "Turbo C++ 3.0"
capture screenshot-dracula  "Dracula"
capture screenshot-solarized-light "Solarized Light"

echo "[screenshots] done -> $out/"
