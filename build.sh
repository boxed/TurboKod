#!/usr/bin/env bash
# Build a release ``turbokod.app`` bundle: compile the mojo backend
# (``examples/desktop.mojo``) and the rust front-end (``app/``), then
# assemble the .app around them so macOS LaunchServices can register
# the ``turbokod://`` URL scheme and route URLs back to a running app
# via the kAEGetURL Apple Event handler installed in
# ``macos_url_scheme.rs``.
#
# Usage:
#     ./build.sh                # build target/release/turbokod.app
#     ./build.sh --install      # also register with LaunchServices in place
#
# Always release. The unoptimized softbuffer + dither pixel loop in
# App::render is slow enough that re-rendering the desktop background
# once per Mojo paint frame pegs a core; release inlining shrinks
# per-pixel cost to where idle render is free. Mojo defaults to -O3
# already; we pass it explicitly so the intent is in the script.
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

set -euo pipefail

project_root="$(cd "$(dirname "$0")" && pwd)"
cd "$project_root"

do_install=0
for arg in "$@"; do
  case "$arg" in
    --install) do_install=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# 1. Resolve the pixi env prefix once. We need:
#   * ``-Lenv/lib -lonig`` at link time so the mojo build resolves
#     libonig symbols (used by the TextMate-grammar highlighter).
#   * ``env/lib/libonig.dylib`` at bundle time so the .app carries its
#     own copy and doesn't fall over when run outside the pixi env.
# ``pixi info`` is the supported way to ask for the env path; fall back
# to the conventional location when not available so this still works
# in CI / headless setups that pre-populate ``.pixi``.
env_prefix="$(pixi info --json 2>/dev/null \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["environments_info"][0]["prefix"])' \
  2>/dev/null || true)"
if [ -z "${env_prefix:-}" ]; then
  env_prefix="${project_root}/.pixi/envs/default"
fi

# 2. Compile the libonig shim (process-exit registry that batches the
#    ``onig_free`` calls we can't safely run from Mojo's per-instance
#    ``__del__``). Rebuild only when the .c file is newer than the
#    cached object, since it's tiny and rarely changes.
mkdir -p "${project_root}/.build"
shim_src="${project_root}/src/turbokod/onig_shim.c"
shim_obj="${project_root}/.build/onig_shim.o"
if [ ! -f "$shim_obj" ] || [ "$shim_src" -nt "$shim_obj" ]; then
  echo "[build] compiling onig shim -> ${shim_obj}" >&2
  clang -c -O2 -fPIC "$shim_src" -o "$shim_obj"
fi

# 3. Build the mojo backend. Mirror the flags ``run.sh`` uses so the
#    binary links to libonig and has the onig-cleanup shim bundled in.
desktop_bin="${project_root}/.build/turbokod-desktop"
echo "[build] mojo build (release) examples/desktop.mojo -> ${desktop_bin}" >&2
pixi run mojo build \
  -O3 \
  -I src \
  -Xlinker "-L${env_prefix}/lib" \
  -Xlinker "-lonig" \
  -Xlinker "$shim_obj" \
  -o "$desktop_bin" examples/desktop.mojo

# 4. Build the rust front-end (release). Bail on failure so we don't
#    end up with a .app pointing at a binary that didn't compile.
echo "[build] cargo build --release (rust front-end)" >&2
( cd "${project_root}/app" && cargo build --release )

bin_path="${project_root}/app/target/release/turbokod-app"
if [ ! -x "$bin_path" ]; then
  echo "[build] ${bin_path} not found after cargo build" >&2
  exit 1
fi

# 5. Compose the .app directory.
app_dir="${project_root}/app/target/release/turbokod.app"
contents="${app_dir}/Contents"
macos="${contents}/MacOS"
resources="${contents}/Resources"
frameworks="${contents}/Frameworks"

rm -rf "$app_dir"
mkdir -p "$macos" "$resources" "$frameworks"

cp "${project_root}/app/macos/Info.plist" "${contents}/Info.plist"
cp "${project_root}/app/macos/icon.icns"  "${resources}/icon.icns"
cp "$bin_path"                            "${macos}/turbokod-app"
cp "$desktop_bin"                         "${macos}/turbokod-desktop"

# Bundle libonig so the mojo binary's ``-lonig`` resolves at runtime
# even after install. We keep ``DYLD_FALLBACK_LIBRARY_PATH`` pointing
# at this dir from the rust front-end (see ``main.rs``); the binary
# itself isn't ``install_name_tool``'d, so the fallback is what loads
# the bundled copy. Resolve symlinks so the bundled copy is the actual
# versioned dylib, not a chain that walks back into the (now-bundle-
# external) pixi env.
onig_src="${env_prefix}/lib/libonig.dylib"
if [ -f "$onig_src" ]; then
  cp -L "$onig_src" "${frameworks}/libonig.dylib"
else
  echo "[build] WARNING: ${onig_src} not found; bundle will rely on DYLD_FALLBACK to find libonig" >&2
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

# Adhoc-sign the assembled bundle. This is what makes LaunchServices
# trust the bundle's CFBundleDocumentTypes claims: cargo signs
# ``turbokod-app`` with its own ad-hoc identity (``turbokod_app-<hash>``)
# before we drop it into the .app, and at that point the signature
# doesn't cover the bundle's Info.plist or resources. ``codesign -dv``
# on the resulting .app reports ``Info.plist=not bound`` — and
# LaunchServices, seeing a bundle whose code signature doesn't match
# its declared ``CFBundleIdentifier``, accepts the launch but refuses
# to deliver doc-type Apple Events for the bundle's claimed UTIs.
# That's what produces the macOS popup ``"the document <X> could not
# be opened. turbokod cannot open files in the 'Folder' format"``
# even when the registration dump shows the Folder claim binding to
# public.folder. Re-signing the assembled bundle (force, deep, ad-hoc)
# rewrites the signature to bind the now-final Info.plist + resources
# under the bundle's own identifier, and LaunchServices then honors
# the doc-type claims.
codesign --force --deep --sign - "$app_dir" >/dev/null

# Re-register with LaunchServices so plist changes (URL schemes,
# CFBundleDocumentTypes for ``open -a turbokod /some/dir``, ...) take
# effect immediately. ``touch`` alone is not reliable: LaunchServices
# happily keeps serving stale doc-type bindings from the previous
# build's registration until something forces a rescan.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$app_dir" >/dev/null

echo "built ${app_dir}"

if [ "$do_install" -eq 1 ]; then
  echo "test it with:  open 'turbokod://open?file=${project_root}/run.sh&line=10'"
fi
