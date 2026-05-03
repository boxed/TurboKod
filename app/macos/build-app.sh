#!/usr/bin/env bash
# Build a ``turbokod.app`` bundle around the cargo-built ``turbokod-app``
# binary so macOS LaunchServices can register the ``turbokod://`` URL
# scheme and route URLs back to a running app via the kAEGetURL Apple
# Event handler installed in ``macos_url_scheme.rs``.
#
# Usage:
#     ./macos/build-app.sh                 # debug build, .app at target/debug/turbokod.app
#     ./macos/build-app.sh --release       # release build at target/release/turbokod.app
#     ./macos/build-app.sh --install       # also register with LaunchServices
#                                          # (the .app stays at target/<profile>/, registered in place)
#
# What goes into the bundle:
#   * ``Contents/MacOS/turbokod-app``      cargo-built rust front-end
#   * ``Contents/MacOS/turbokod-desktop``  default mojo backend the front-end
#                                          spawns when no shell-arg is given.
#                                          Without this, a URL-cold-launched
#                                          .app would spawn ``$SHELL`` and the
#                                          ``__mvc_open:`` OSC would just set
#                                          a window title.
#   * ``Contents/Frameworks/libonig.dylib``  libonig the mojo binary links to.
#   * ``Contents/Resources/launch.env``    KEY=VALUE recording the project
#                                          root + pixi env at build time so
#                                          the rust front-end can set CWD and
#                                          DYLD_FALLBACK_LIBRARY_PATH for the
#                                          spawned mojo binary at runtime.
#   * ``Contents/Info.plist``              CFBundleURLTypes for ``turbokod://``.

set -uo pipefail
cd "$(dirname "$0")/.."

profile="debug"
do_install=0
for arg in "$@"; do
  case "$arg" in
    --release) profile="release" ;;
    --install) do_install=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# 1. Build the rust front-end. Bail on failure so we don't end up with a
#    .app pointing at a binary that didn't actually compile.
if [ "$profile" = "release" ]; then
  cargo build --release
else
  cargo build
fi

bin_path="target/${profile}/turbokod-app"
if [ ! -x "$bin_path" ]; then
  echo "build-app.sh: ${bin_path} not found after cargo build" >&2
  exit 1
fi

# 2. Build the mojo backend. Mirror the flags ``run.sh`` uses so the
#    binary links to libonig (regex engine for TextMate grammars) and
#    has the onig-cleanup shim bundled in.
project_root="$(cd .. && pwd)"
env_prefix="$(pixi info --json --manifest-path "$project_root/pixi.toml" 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["environments_info"][0]["prefix"])' \
  2>/dev/null)"
if [ -z "${env_prefix:-}" ]; then
  env_prefix="${project_root}/.pixi/envs/default"
fi
shim_src="${project_root}/src/turbokod/onig_shim.c"
shim_obj="${project_root}/.build/onig_shim.o"
mkdir -p "${project_root}/.build"
if [ ! -f "$shim_obj" ] || [ "$shim_src" -nt "$shim_obj" ]; then
  clang -c -O2 -fPIC "$shim_src" -o "$shim_obj"
fi
desktop_bin="${project_root}/.build/turbokod-desktop"
echo "[build-app] mojo build examples/desktop.mojo -> ${desktop_bin}" >&2
( cd "$project_root" && pixi run mojo build \
    -I src \
    -Xlinker "-L${env_prefix}/lib" \
    -Xlinker "-lonig" \
    -Xlinker "$shim_obj" \
    -o "$desktop_bin" examples/desktop.mojo )

# 3. Compose the .app directory.
app_dir="target/${profile}/turbokod.app"
contents="${app_dir}/Contents"
macos="${contents}/MacOS"
resources="${contents}/Resources"
frameworks="${contents}/Frameworks"

rm -rf "$app_dir"
mkdir -p "$macos" "$resources" "$frameworks"

cp macos/Info.plist "${contents}/Info.plist"
cp "$bin_path" "${macos}/turbokod-app"
cp "$desktop_bin" "${macos}/turbokod-desktop"

# Bundle libonig so the mojo binary's ``-lonig`` resolves at runtime
# even after install. We keep ``DYLD_FALLBACK_LIBRARY_PATH`` pointing
# at this dir from the rust front-end (see ``main.rs``); the binary
# itself isn't ``install_name_tool``'d, so the fallback is what loads
# the bundled copy.
onig_src="${env_prefix}/lib/libonig.dylib"
if [ -f "$onig_src" ]; then
  # Resolve symlink so the bundled copy is the actual versioned dylib,
  # not a chain that walks back into the (now-bundle-external) pixi env.
  cp -L "$onig_src" "${frameworks}/libonig.dylib"
else
  echo "[build-app] WARNING: ${onig_src} not found; bundle will rely on DYLD_FALLBACK to find libonig" >&2
fi

# Record where to chdir before launching the mojo backend (so its
# relative grammar paths still resolve) and which extra lib dir
# (typically pixi's env) to add to DYLD_FALLBACK_LIBRARY_PATH. The
# rust front-end always inserts ``<exe_dir>/../Frameworks`` itself —
# launch.env only carries the *additional* lookup paths the bundle
# wants to layer on top.
cat > "${resources}/launch.env" <<EOF
PROJECT_ROOT=${project_root}
EXTRA_DYLD_FALLBACK=${env_prefix}/lib
EOF

# Touch the bundle so LaunchServices notices and re-reads Info.plist —
# without this, repeated builds with plist edits keep using the cached
# URL-scheme registration from the first build.
touch "$app_dir"

echo "built ${app_dir}"

if [ "$do_install" -eq 1 ]; then
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f -v "$app_dir" >/dev/null
  echo "registered ${app_dir} with LaunchServices"
  echo "test it with:  open 'turbokod://open?file=${project_root}/run.sh&line=10'"
fi
