#!/usr/bin/env bash
# Native-frontend runner: like ``run.sh`` but links the macOS windowing
# staticlib (``app/turbokod-render``) and the frameworks winit / softbuffer
# / Core Text need, so a Mojo entry point using ``NativeFrontend`` opens a
# real window instead of driving a TTY.
#
#   ./run_native.sh examples/hello_native.mojo
#
# We still link ``turbokod-shim`` too (pty / onig / listdir / …) so the same
# script can run the full Desktop natively, not just the hello demo.
set -uo pipefail

args=()
for arg in "$@"; do
  if [[ "$arg" == /* ]] || [[ ! -e "$arg" ]]; then
    args+=("$arg")
  else
    args+=("$(cd "$(dirname -- "$arg")" && pwd)/$(basename -- "$arg")")
  fi
done

cd "$(dirname "$0")"

if [ "${#args[@]}" -eq 0 ]; then
  echo "usage: ./run_native.sh <entry.mojo> [program-args...]" >&2
  exit 2
fi

src="${args[0]}"
prog_args=("${args[@]:1}")

mkdir -p .build
hash="$(printf '%s' "$src" | shasum -a 256 | cut -c1-8)"
bin=".build/$(basename -- "$src" .mojo)_native_${hash}"

shim_lib="app/turbokod-shim/target/release/libturbokod_shim.a"
render_lib="app/turbokod-render/target/release/libturbokod_render.a"

# Rebuild the binary when any Mojo source, the entry point, or either
# staticlib is newer than the cached binary.
needs_build=1
if [ -x "$bin" ]; then
  newer=$(find src "$src" -name '*.mojo' -newer "$bin" -print -quit 2>/dev/null)
  if [ -z "$newer" ] \
     && [ ! "$shim_lib" -nt "$bin" ] \
     && [ ! "$render_lib" -nt "$bin" ]; then
    needs_build=0
  fi
fi

restore_term() {
  stty sane 2>/dev/null || true
}
trap restore_term EXIT INT TERM

env_prefix="$(pixi info --json 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["environments_info"][0]["prefix"])' \
  2>/dev/null)"
if [ -z "${env_prefix:-}" ]; then
  env_prefix="$(pwd)/.pixi/envs/default"
fi

# --- Build the two Rust staticlibs (only when their sources changed) --------
build_crate() {
  local crate="$1" lib="$2"
  local need=0
  if [ ! -f "$lib" ]; then
    need=1
  elif find "$crate/src" "$crate/Cargo.toml" -newer "$lib" -print -quit 2>/dev/null | grep -q .; then
    need=1
  fi
  if [ "$need" -eq 1 ]; then
    echo "[run_native.sh] building $crate -> $lib" >&2
    if ! ( cd "$crate" && cargo build --release ); then
      echo "[run_native.sh] $crate build failed; aborting" >&2
      exit 1
    fi
  fi
}
build_crate "app/turbokod-shim" "$shim_lib"
build_crate "app/turbokod-render" "$render_lib"

# Frameworks pulled in by winit (objc2-app-kit), softbuffer
# (objc2-quartz-core / core-graphics), and core-text. Rust emits these as
# link directives for its own builds, but a staticlib linked into a non-Rust
# binary carries none of them, so we pass them explicitly. A generous set —
# extra frameworks are harmless.
fw=()
for f in AppKit Foundation CoreFoundation CoreGraphics CoreText QuartzCore Metal IOKit CoreVideo Carbon; do
  fw+=( -Xlinker -framework -Xlinker "$f" )
done

if [ "$needs_build" -eq 1 ]; then
  echo "[run_native.sh] building $src -> $bin" >&2
  if ! pixi run mojo build \
    -I src \
    -Xlinker "-L${env_prefix}/lib" \
    -Xlinker "-lonig" \
    -Xlinker "-lobjc" \
    -Xlinker "$render_lib" \
    -Xlinker "$shim_lib" \
    "${fw[@]}" \
    -o "$bin" "$src"; then
    echo "[run_native.sh] mojo build failed; aborting" >&2
    exit 1
  fi
fi

export DYLD_LIBRARY_PATH="${env_prefix}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export LD_LIBRARY_PATH="${env_prefix}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Run from inside a TurboKod.app bundle so macOS resolves NSBundle.mainBundle
# and shows the proper app name ("TurboKod") in the menu bar + the icon in the
# Dock — instead of the raw binary's hashed name and a generic icon. AppKit
# reads CFBundleName / CFBundleIconFile from the enclosing bundle even when the
# executable is launched directly (no `open` / LaunchServices needed). cwd is
# unchanged (still the project root), so grammar relative paths still resolve.
app_dir=".build/TurboKod.app"
contents="$app_dir/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "app/macos/TurboKod-Info.plist" "$contents/Info.plist"
cp "app/macos/icon.icns"           "$contents/Resources/icon.icns"
cp "$bin"                          "$contents/MacOS/TurboKod"
exec "$contents/MacOS/TurboKod" ${prog_args[@]+"${prog_args[@]}"}
