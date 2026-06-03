.PHONY: build app tui test screenshots update-lsp-list
.DEFAULT_GOAL := build

# ``make`` (default) — build both frontends without launching either.
# Use this after editing Mojo source to make sure both the macOS .app
# and the terminal-frontend code path still compile *and* to refresh
# the bundled dylib at .build/TurboKod.app/Contents/Frameworks/ so a
# Dock relaunch picks up the new code (see
# docs/app-bundle.md "Gotcha: relaunching the .app skips the bundle sync").
#
# Both halves use mtime caches — re-running is a no-op when nothing changed.
build: app tui

# Build .build/TurboKod.app — Rust shim + Mojo dylib + Swift binary,
# then assemble the bundle. Does NOT launch (use ``./run_swift.sh``
# for that, or ``open .build/TurboKod.app`` after this target).
app:
	TURBOKOD_BUILD_ONLY=1 ./run_swift.sh

# Build the canonical terminal-frontend entry point (``examples/desktop.mojo``).
# That demo wires up the full ``Desktop`` model, so it's a good smoke
# build for the entire terminal code path. Does NOT run (use
# ``./run.sh examples/desktop.mojo`` for that, or ``pixi run desktop``).
tui:
	TURBOKOD_BUILD_ONLY=1 ./run.sh examples/desktop.mojo

# Build + run the headless unit tests. Same as ``pixi run test``.
# Doesn't fit the "build only" pattern of ``build`` because the
# ``test_basic.mojo`` binary has no purpose outside being run, so this
# target launches.
test:
	./run.sh tests/test_basic.mojo

# Regenerate the README / docs screenshots: the per-theme gallery under
# docs/screenshots/ and the debugger-paused hero shot (screenshot.png).
# Launches the native app once per shot, so it needs a real display —
# run on a Mac desktop session, not headless / over SSH / in CI.
screenshots:
	scripts/screenshots.sh

# Refresh src/turbokod/data/languages.json from upstream Helix
# (helix-editor/helix on master). Commit the resulting JSON.
update-lsp-list:
	python3 scripts/refresh_languages.py
