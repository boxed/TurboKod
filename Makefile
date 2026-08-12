.PHONY: build shim app tui test check release screenshots update-lsp-list
.DEFAULT_GOAL := build

# ``make`` (default) — build both frontends without launching either.
# Use this after editing Mojo source to make sure both the macOS .app
# and the terminal-frontend code path still compile *and* to refresh
# the bundled dylib at .build/TurboKod.app/Contents/Frameworks/ so a
# Dock relaunch picks up the new code (see
# docs/app-bundle.md "Gotcha: relaunching the .app skips the bundle sync").
#
# Both halves use mtime caches — re-running is a no-op when nothing changed.
#
# ``app`` and ``tui`` are independent ``mojo build`` invocations (separate
# outputs — the dylib vs the terminal binary), so we recurse into a ``-j2``
# sub-make to compile them concurrently. On a full rebuild that roughly
# halves wall time: each frontend is ~9s, so sequential ~20s drops to ~11s.
# The Rust shim both scripts link is built first as a serial prerequisite,
# so the two parallel halves never race ``cargo`` against the same target
# dir; once it's cached the ``shim`` step is a near-instant no-op.
build: shim
	@$(MAKE) --no-print-directory -j2 app tui

# Build the Rust shim staticlib up front (cargo's own mtime check makes
# this a no-op when nothing in the crate changed). Pulling it out of the
# parallel step keeps app+tui from both triggering a cold ``cargo build``
# against the shared target dir at the same time.
shim:
	@cd app/turbokod-shim && cargo build --release -q

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
# Doesn't fit the "build only" pattern of ``build`` because a test binary has
# no purpose outside being run, so this target launches.
#
# The suites (``tests/test_<topic>.mojo``) build concurrently and then run one
# at a time — see scripts/run_tests.sh. Pass a filter to narrow it down:
# ``scripts/run_tests.sh git editor``.
test:
	scripts/run_tests.sh

# Full pre-commit sweep: build EVERY entry point (including the ones no other
# target compiles — bench/ and most of examples/), build the native frontend,
# run every test suite, and fail on a single compiler warning.
#
# ``build`` and ``test`` deliberately don't cover the standalone entry points:
# each one is a full core compile, so folding them into the edit loop would
# cost ~25s on every src/ change. That left bench/ and most of examples/
# compiled by nothing, which is exactly where warnings rotted unnoticed until
# a toolchain bump surfaced them. Run this before committing instead.
#
# ``scripts/check_all.sh --quick`` skips the test run (build + warning gate only).
check:
	scripts/check_all.sh

# Build a self-contained, Developer ID signed + Apple-notarized + stapled
# TurboKod.app, zip it, and publish to the GitHub Releases page. Unlike
# ``app``, this vendors the Mojo runtime + libonig into the bundle so it runs
# on a machine without the pixi env. Prompts for the next version (defaulting
# to a patch bump), stamps + commits + tags it, then builds. Skip the prompt
# with ``make release VERSION=0.0.2``. Notarization is MANDATORY: the script
# aborts up front (before tagging or building) if a Developer ID cert or notary
# creds are missing — we never publish a non-notarized release. The notary
# keychain profile defaults to ``turbokod-notary``; see the header of
# scripts/release.sh for the override env vars.
release:
	VERSION="$(VERSION)" scripts/release.sh

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
