#!/usr/bin/env bash
#
# Build the README / docs screenshots of the native macOS app:
#
#   docs/screenshots/theme-<slug>.png   one per built-in theme
#   screenshot.png                      hero: debug session paused at a
#                                       breakpoint in a small Python project
#                                       (boxed/scientist), file tree docked
#                                       right (default theme)
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
# The debugger shot debugs a small *Python* project (boxed/scientist) under
# debugpy rather than the repo's own Mojo test binary: lldb has no Mojo
# language plugin, so debugging a Mojo binary floods the Output pane with
# 'no plugin for the language "mojo"' and shows "(error) no variable
# information" for locals. debugpy gives a clean log and a fully populated
# Locals pane. The project is cloned + a venv (pytest + debugpy) built under
# .build/ on first run, then a .turbokod/ target + breakpoint + session are
# staged inside the clone and the suite is F5'd. Nothing of yours is touched.
#
# Needs a real display (Core Text + a window) — run it locally on macOS, not
# headless / over SSH / in CI, or the capture comes out blank. Needs network
# the first time (git clone + pip install); cached thereafter.
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

# Build the app up front so the per-shot launches hit a warm cache.
TURBOKOD_BUILD_ONLY=1 ./run_swift.sh

# Stage the user's targets/breakpoints/session out of the way for the whole
# run and put them back no matter how we exit — the theme shots and the
# debugger shot each drop in their own deterministic session.json, so we must
# never restore the user's *real* last session (which may have, say, a
# markdown buffer open and would then pop "Install marksman LSP?" right into
# the frame). A missing original means "remove the staged file on exit".
targets="$root/.turbokod/targets.json"
bps="$root/.turbokod/per_user/$(id -un)/breakpoints.json"
session="$root/.turbokod/per_user/$(id -un)/session.json"
mkdir -p "$(dirname "$bps")"
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

# ---------------------------------------------------------------- themes --
# Same scene for every theme: the project open with the editor on a meaty
# function, so the shots differ only in palette. Anchored by grep, not a
# hard-coded line, so the scene survives edits to editor.mojo.
scene_file="$root/src/turbokod/editor.mojo"
scene_line="$(grep -n -m1 'def handle_key' "$scene_file" | cut -d: -f1)"

# Stage a deterministic, all-Mojo session for the theme shots instead of
# letting ``openProject`` restore whatever the user happened to leave open.
# Every buffer here is a .mojo file from this repo, so the only language
# server involved is mojo-lsp-server (ships with the toolchain, already on
# $PATH for this pixi run — status bar reads ``LSP(mojo)::ready``) and no
# "Install <lang> LSP?" prompt can fire into the grab. editor.mojo is focused,
# maximized, and scrolled to ``scene_line``; the rest just populate the
# window-tab strip so the shot still looks like a real working session. Paths
# are session-relative to the project root.
scene_scroll=$((scene_line > 6 ? scene_line - 6 : 0))
cat > "$session" <<EOF
{
  "focused": 6,
  "z_order": [0, 1, 2, 3, 4, 5, 6],
  "windows": [
    { "path": "src/turbokod/colors.mojo",          "maximized": true, "rect": [0, 0, 0, 0], "restore_rect": [3, 1, 90, 30], "cursor": [0, 0], "scroll": [0, 0] },
    { "path": "src/turbokod/cell.mojo",             "maximized": true, "rect": [0, 0, 0, 0], "restore_rect": [3, 1, 90, 30], "cursor": [0, 0], "scroll": [0, 0] },
    { "path": "src/turbokod/app.mojo",              "maximized": true, "rect": [0, 0, 0, 0], "restore_rect": [3, 1, 90, 30], "cursor": [0, 0], "scroll": [0, 0] },
    { "path": "src/turbokod/lsp_status_menu.mojo",  "maximized": true, "rect": [0, 0, 0, 0], "restore_rect": [3, 1, 90, 30], "cursor": [0, 0], "scroll": [0, 0] },
    { "path": "examples/desktop.mojo",              "maximized": true, "rect": [0, 0, 0, 0], "restore_rect": [3, 1, 90, 30], "cursor": [0, 0], "scroll": [0, 0] },
    { "path": "src/turbokod/desktop.mojo",          "maximized": true, "rect": [0, 0, 0, 0], "restore_rect": [3, 1, 90, 30], "cursor": [0, 0], "scroll": [0, 0] },
    { "path": "src/turbokod/editor.mojo",           "maximized": true, "rect": [0, 0, 0, 0], "restore_rect": [3, 1, 90, 30], "cursor": [$((scene_line - 1)), 0], "scroll": [0, $scene_scroll] }
  ]
}
EOF

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
# Debug a small Python project under debugpy. Clone + venv are cached under
# .build/ (gitignored); both steps are keyed by existence so repeat runs are
# instant and offline.
proj="$root/.build/screenshot-scientist"
venv="$proj/.venv"
if [ ! -d "$proj/.git" ]; then
  echo "[screenshots] cloning boxed/scientist -> $proj"
  rm -rf "$proj"
  git clone --depth 1 https://github.com/boxed/scientist "$proj"
  # Keep the file tree clean: hide the venv + our staged config. (scientist's
  # own .gitignore already covers .pytest_cache and *.pyc.)
  printf '\n.venv\n.turbokod\n' >> "$proj/.gitignore"
fi
if [ ! -x "$venv/bin/debugpy-adapter" ]; then
  echo "[screenshots] building venv (pytest + debugpy + ty) -> $venv"
  python3 -m venv "$venv"
  "$venv/bin/python" -m pip install -q --upgrade pip
  # debugpy: the adapter. pytest: the suite we debug. ty: pre-seed the Python
  # LSP so the app's debug-start "install ty into the venv" one-shot finds it
  # already present and stays silent instead of flashing into the grab.
  "$venv/bin/python" -m pip install -q pytest debugpy ty
fi

# scientist ships no setup.py/pyproject, so ``from scientist import …`` needs
# the project root on the path. debugpy inherits our env, so export it here.
export PYTHONPATH="$proj"

# Stage the target + an empty breakpoint store inside the clone's .turbokod/.
# ``python`` is swapped for the venv interpreter by the app's venv detection;
# ``-m pytest`` is debugged as a module.
ptk="$proj/.turbokod"
pbps="$ptk/per_user/$(id -un)/breakpoints.json"
psession="$ptk/per_user/$(id -un)/session.json"
mkdir -p "$(dirname "$pbps")"
cat > "$ptk/targets.json" <<EOF
{
  "active": "tests (debug)",
  "targets": [
    { "name":     "tests (debug)",
      "program":  "python",
      "args":     ["-m", "pytest", "tests/test_scientist.py"],
      "cwd":      "",
      "language": "python" }
  ]
}
EOF
printf '{"breakpoints":[]}' > "$pbps"

# Breakpoint inside check_candidate, after every local is assigned: the first
# test (test_golden_path) hits it within moments of launch, so the paused
# stack + a fully populated Locals pane (a, candidate, args, kwargs,
# control_result, …) show off the debugger. Anchored by grep so the shot
# survives edits upstream.
src_file="scientist/__init__.py"
test_file="tests/test_scientist.py"
bp_line="$(grep -n -m1 'if reason is not None:' "$proj/$src_file" | cut -d: -f1)"

# Two cascaded, non-maximized windows so the shot shows window chrome + drop
# shadows + the desktop behind them — the test file behind, the library
# function in front with the cursor parked on the breakpoint line
# (debug:toggle_bp toggles at the cursor). Rects are cell coords; restore
# clips them to the actual workspace. Session cursor/scroll are 0-based.
cat > "$psession" <<EOF
{
  "focused": 1,
  "z_order": [0, 1],
  "windows": [
    { "path": "$test_file",
      "rect": [3, 1, 128, 62], "maximized": false,
      "restore_rect": [3, 1, 128, 62],
      "cursor": [0, 0], "scroll": [0, 0] },
    { "path": "$src_file",
      "rect": [12, 6, 137, 68], "maximized": false,
      "restore_rect": [12, 6, 137, 68],
      "cursor": [$((bp_line - 1)), 0],
      "scroll": [0, $((bp_line > 6 ? bp_line - 6 : 0))] }
  ]
}
EOF

echo "[screenshots] debugger paused at $src_file:$bp_line -> $root/screenshot.png"
# The tree toggle fires first (one step of the hidden→right→left cycle
# docks it on the right) so the workspace refits the two windows before
# the breakpoint + launch actions run.
TK_THEME="Turbo C++ 3.0" \
TK_MENU_INGRID=1 \
TK_CAPTURE_ACTIONS="project:tree:toggle,debug:toggle_bp,debug:start_or_continue" \
TK_CAPTURE_WHEN="debug-stopped" \
TK_CAPTURE="$root/screenshot.png" \
  ./run_swift.sh "$proj"

echo "[screenshots] done -> $out/ + screenshot.png"
