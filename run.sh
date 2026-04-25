#!/usr/bin/env bash
# Convenience wrapper: `./run.sh examples/hello.mojo` or `./run.sh tests/test_basic.mojo`.
# Runs through pixi so the project's pinned Mojo toolchain is used; -I src makes
# `from mojovision import ...` resolve.
set -euo pipefail
cd "$(dirname "$0")"
exec pixi run mojo run -I src "$@"
