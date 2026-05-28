#!/usr/bin/env bash
# Build + run the Swift front-end (owns the macOS UI) over the Mojo logic
# shared-lib. Swift renders the cell grid (Core Text), owns the run loop /
# windows / menus / resize; Mojo (libturbokod.dylib) is the Desktop model.
#
#   ./run_swift.sh                       # restore session
#   ./run_swift.sh /path/to/project      # open a project
#   TK_CAPTURE=/tmp/shot.png ./run_swift.sh src/turbokod/cell.mojo   # headless render
set -uo pipefail
cd "$(dirname "$0")"
root="$(pwd)"

env_prefix="$(pixi info --json 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["environments_info"][0]["prefix"])' 2>/dev/null)"
[ -z "${env_prefix:-}" ] && env_prefix="${root}/.pixi/envs/default"

shim_lib="app/turbokod-shim/target/release/libturbokod_shim.a"
dylib=".build/libturbokod.dylib"
swiftbin=".build/turbokod_swift"
mkdir -p .build

# Build the Rust shim if needed (pty / onig handle registry / listdir).
if [ ! -f "$shim_lib" ] || find app/turbokod-shim/src app/turbokod-shim/Cargo.toml -newer "$shim_lib" -print -quit 2>/dev/null | grep -q .; then
  echo "[run_swift] building rust shim" >&2
  ( cd app/turbokod-shim && cargo build --release ) || exit 1
fi

# Build the Mojo logic shared-lib when any Mojo source changed.
if [ ! -f "$dylib" ] || find src "$shim_lib" -newer "$dylib" -print -quit 2>/dev/null | grep -q .; then
  echo "[run_swift] building Mojo shared-lib -> $dylib" >&2
  if ! pixi run mojo build --emit shared-lib -I src \
      -Xlinker "-L${env_prefix}/lib" -Xlinker "-lonig" \
      -Xlinker "$shim_lib" \
      -o "$dylib" src/turbokod/native_api.mojo; then
    echo "[run_swift] Mojo shared-lib build failed" >&2
    exit 1
  fi
  # Absolute install name so the Swift binary loads it regardless of cwd.
  install_name_tool -id "${root}/${dylib}" "$dylib"
fi

# Build the Swift binary against the dylib + frameworks. rpath to the pixi
# lib dir resolves the dylib's @rpath deps (Mojo runtime + libonig).
if [ ! -f "$swiftbin" ] || [ app/swift/TurboKod.swift -nt "$swiftbin" ] \
   || [ app/swift/turbokod.h -nt "$swiftbin" ] || [ "$dylib" -nt "$swiftbin" ]; then
  echo "[run_swift] building Swift binary -> $swiftbin" >&2
  if ! swiftc app/swift/TurboKod.swift \
      -import-objc-header app/swift/turbokod.h \
      -L .build -lturbokod \
      -framework AppKit -framework CoreText -framework CoreGraphics -framework Foundation \
      -Xlinker -rpath -Xlinker "${env_prefix}/lib" \
      -o "$swiftbin"; then
    echo "[run_swift] Swift build failed" >&2
    exit 1
  fi
fi

# Assemble TurboKod.app so macOS shows the proper name + icon, and bundle the
# resources the Mojo side loads via relative paths (src/turbokod/grammars,
# src/turbokod/data). The app chdir's to Resources/ on launch, so these
# resolve regardless of where it's launched from (Dock, moved .app, no repo).
app_dir=".build/TurboKod.app"; contents="$app_dir/Contents"
res="$contents/Resources"
rm -rf "$res/src"
mkdir -p "$contents/MacOS" "$res/src/turbokod"
cp app/macos/TurboKod-Info.plist "$contents/Info.plist"
cp app/macos/icon.icns "$res/icon.icns"
cp "$swiftbin" "$contents/MacOS/TurboKod"
cp -R src/turbokod/grammars "$res/src/turbokod/grammars"
cp -R src/turbokod/data     "$res/src/turbokod/data"
cp app/assets/Px437_IBM_VGA_8x16.ttf "$res/Px437_IBM_VGA_8x16.ttf"

exec "$contents/MacOS/TurboKod" "$@"
