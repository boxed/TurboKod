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
tk_tui=".build/tk_tui"
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
fi

# (Re-)stamp the install_name to ``@rpath/libturbokod.dylib`` so the
# Swift binary loads it via rpath rather than baking in an absolute or
# CWD-relative path. Checked every invocation so an interrupted earlier
# build (which may have left the install_name as Mojo's default
# ``.build/libturbokod.dylib``) self-heals on the next run. Without this,
# ``open`` / Dock launches crash at dyld with ``Library not loaded``
# because the CWD-relative path doesn't resolve. Stamp only when needed:
# install_name_tool rewrites the file even for a no-op id change, and the
# fresh mtime would re-trigger the Swift build below on every launch.
if ! otool -D "$dylib" 2>/dev/null | grep -q "^@rpath/libturbokod.dylib$"; then
  install_name_tool -id "@rpath/libturbokod.dylib" "$dylib" 2>/dev/null
fi

# Build the Swift binary against the dylib + frameworks. Two rpaths:
#   * ``@executable_path/../Frameworks`` — the .app bundle's Frameworks dir,
#     where the dylib gets copied during bundle assembly below. Makes the
#     bundle relocatable (Dock launches, moved .app, etc.).
#   * ``${env_prefix}/lib`` — pixi env, where the Mojo runtime + libonig
#     live. These aren't bundle-relocatable so we keep the absolute rpath.
if [ ! -f "$swiftbin" ] || [ app/swift/TurboKod.swift -nt "$swiftbin" ] \
   || [ app/swift/turbokod.h -nt "$swiftbin" ] || [ "$dylib" -nt "$swiftbin" ]; then
  echo "[run_swift] building Swift binary -> $swiftbin" >&2
  if ! swiftc app/swift/TurboKod.swift \
      -import-objc-header app/swift/turbokod.h \
      -L .build -lturbokod \
      -framework AppKit -framework CoreText -framework CoreGraphics -framework Foundation \
      -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
      -Xlinker -rpath -Xlinker "${env_prefix}/lib" \
      -o "$swiftbin"; then
    echo "[run_swift] Swift build failed" >&2
    exit 1
  fi
fi

# Build the terminal-frontend binary (tk-tui). Unlike examples/desktop.mojo
# (which ``run.sh`` compiles with the whole core baked in, ~4.6 MB), this links
# the dylib and reaches the Desktop only through its C ABI — so it stays tiny
# (~170 KB) and shares the one bundled libturbokod.dylib instead of duplicating
# the core. Rebuild when its source, any src Mojo, or the dylib (its ABI) moved.
#   * ``-L .build -lturbokod`` links against the dylib (install_name is
#     ``@rpath/libturbokod.dylib``, stamped above), resolved at runtime by ...
#   * ``-rpath @executable_path/../Frameworks`` — tk-tui lives in Contents/MacOS,
#     the dylib in Contents/Frameworks. (``mojo build`` already bakes the
#     ``${env_prefix}/lib`` rpath for the Mojo runtime + libonig the dylib pulls
#     in at load, so we must NOT add it again — that would warn "duplicate
#     -rpath". tk-tui itself never calls libonig, so no ``-lonig`` here.)
if [ ! -f "$tk_tui" ] || [ app/tui/main.mojo -nt "$tk_tui" ] \
   || [ "$dylib" -nt "$tk_tui" ] \
   || find src -name '*.mojo' -newer "$tk_tui" -print -quit 2>/dev/null | grep -q .; then
  echo "[run_swift] building tk-tui binary -> $tk_tui" >&2
  if ! pixi run mojo build -I src \
      -Xlinker "-L${env_prefix}/lib" \
      -Xlinker "-L.build" -Xlinker "-lturbokod" \
      -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
      -o "$tk_tui" app/tui/main.mojo; then
    echo "[run_swift] tk-tui build failed" >&2
    exit 1
  fi
fi

# Assemble TurboKod.app so macOS shows the proper name + icon, and bundle the
# resources the Mojo side loads via relative paths (src/turbokod/grammars,
# src/turbokod/data). The app chdir's to Resources/ on launch, so these
# resolve regardless of where it's launched from (Dock, moved .app, no repo).
app_dir=".build/TurboKod.app"; contents="$app_dir/Contents"
res="$contents/Resources"
fwk="$contents/Frameworks"
rm -rf "$res/src"
mkdir -p "$contents/MacOS" "$fwk" "$res/src/turbokod"
cp app/macos/TurboKod-Info.plist "$contents/Info.plist"
cp app/macos/icon.icns "$res/icon.icns"
cp "$swiftbin" "$contents/MacOS/TurboKod"
# The terminal frontend, launched by the ``tk`` CLI helper (and over SSH).
# It rpath-loads the same Contents/Frameworks/libturbokod.dylib as the Swift host.
cp "$tk_tui" "$contents/MacOS/tk-tui"
# Embed the Mojo dylib so the .app is self-contained for it. The Swift
# binary's rpath ``@executable_path/../Frameworks`` resolves to this
# location regardless of where the .app is launched from.
cp "$dylib" "$fwk/libturbokod.dylib"
cp -R src/turbokod/grammars "$res/src/turbokod/grammars"
cp -R src/turbokod/data     "$res/src/turbokod/data"
cp app/assets/Px437_IBM_VGA_8x16.ttf "$res/Px437_IBM_VGA_8x16.ttf"

# Ad-hoc re-sign the assembled bundle, innermost first. The executable and
# dylib can land here with a signature that no longer matches (a stale
# linker signature, or one invalidated by install_name_tool), and arm64
# macOS SIGKILLs (``Killed: 9``) any binary whose signature doesn't
# validate — the launch dies before main() with no output. Re-signing on
# every assembly is cheap (<100 ms) and makes the bundle always runnable.
codesign --force --sign - "$fwk/libturbokod.dylib" 2>/dev/null
codesign --force --sign - "$contents/MacOS/tk-tui" 2>/dev/null
codesign --force --sign - "$app_dir" 2>/dev/null

# ``TURBOKOD_BUILD_ONLY=1`` skips the launch — used by ``make app`` so
# the bundle gets refreshed without forcing an interactive launch.
# Relaunching the .app via Dock then picks up the fresh dylib (see
# docs/app-bundle.md "Gotcha: relaunching the .app skips the bundle sync").
if [ -n "${TURBOKOD_BUILD_ONLY:-}" ]; then
  echo "[run_swift] built $contents/MacOS/TurboKod (TURBOKOD_BUILD_ONLY=1; not launching)" >&2
  exit 0
fi
exec "$contents/MacOS/TurboKod" "$@"
