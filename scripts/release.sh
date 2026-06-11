#!/usr/bin/env bash
# Build a self-contained, signed (and, when creds exist, notarized + stapled)
# TurboKod.app, zip it, and publish it to the GitHub Releases page.
#
# Unlike `make app`, the bundle this produces is portable *across machines*:
# it vendors the Mojo runtime dylibs + libonig out of the pixi env into
# Contents/Frameworks/ (the dev-only build keeps loading those from absolute
# pixi paths - see docs/app-bundle.md "What's not bundled").
#
#   make release                 # version from Info.plist
#   make release VERSION=0.0.2    # explicit version (also names the git tag)
#
# Signing / notarization are auto-detected and degrade gracefully:
#   * Developer ID Application cert in the keychain -> hardened-runtime signed.
#     Override which identity with TURBOKOD_SIGN_IDENTITY="Developer ID Application: ...".
#     No such cert -> ad-hoc signed (runnable locally, Gatekeeper-blocked for others).
#   * Notary credentials present -> submitted to Apple + stapled. Provide either:
#       TURBOKOD_NOTARY_PROFILE=<keychain-profile>   (xcrun notarytool store-credentials)
#     or all three of:
#       TURBOKOD_NOTARY_APPLE_ID / TURBOKOD_NOTARY_PASSWORD / TURBOKOD_NOTARY_TEAM_ID
#     None present -> notarization skipped with a warning.
#
# Builds for the host architecture only (arm64 on this toolchain).
set -uo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"

die() { echo "[release] error: $*" >&2; exit 1; }
note() { echo "[release] $*" >&2; }

plist_src="app/macos/TurboKod-Info.plist"
entitlements="app/macos/TurboKod.entitlements"
app=".build/TurboKod.app"
contents="$app/Contents"
fwk="$contents/Frameworks"
arch="$(uname -m)"

# ---------------------------------------------------------------------------
# 1. Version. Explicit VERSION wins; otherwise read the source Info.plist.
# ---------------------------------------------------------------------------
VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(plutil -extract CFBundleShortVersionString raw "$plist_src" 2>/dev/null)" \
    || die "could not read CFBundleShortVersionString from $plist_src; pass VERSION=x.y.z"
fi
tag="v$VERSION"
note "building TurboKod $VERSION ($tag) for macos-$arch"

# Warn (don't block) on a dirty tree - the git tag gh creates will point at
# HEAD, so uncommitted work won't be in the released commit.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  note "warning: working tree is dirty; the '$tag' tag will point at HEAD without your uncommitted changes"
fi

# ---------------------------------------------------------------------------
# 2. Build the bundle via the normal path (also re-copies the dylib + assets).
# ---------------------------------------------------------------------------
note "building bundle (run_swift.sh)..."
TURBOKOD_BUILD_ONLY=1 ./run_swift.sh || die "bundle build failed"
[ -d "$app" ] || die "$app missing after build"

# Stamp the version into the *bundle* Info.plist only (leave the tracked
# source plist alone so the release doesn't mutate the working tree).
plutil -replace CFBundleShortVersionString -string "$VERSION" "$contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$contents/Info.plist"

# ---------------------------------------------------------------------------
# 3. Vendor the Mojo runtime + libonig into Frameworks/ so the .app runs on a
#    machine with no pixi env. Fixpoint over @rpath deps: keep copying missing
#    dylibs out of the pixi lib dir until nothing new appears.
# ---------------------------------------------------------------------------
prefix="$(pixi info --json 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["environments_info"][0]["prefix"])' 2>/dev/null)"
[ -z "${prefix:-}" ] && prefix="${root}/.pixi/envs/default"
[ -d "$prefix/lib" ] || die "pixi env lib dir not found at $prefix/lib"

note "vendoring runtime dylibs from $prefix/lib..."
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for lib in "$fwk"/*.dylib; do
    [ -f "$lib" ] || continue
    for dep in $(otool -L "$lib" | awk '/@rpath\/.*\.dylib/{print $1}' | sed 's#@rpath/##'); do
      [ "$dep" = "libturbokod.dylib" ] && continue
      if [ ! -f "$fwk/$dep" ] && [ -f "$prefix/lib/$dep" ]; then
        cp "$prefix/lib/$dep" "$fwk/$dep"
        chmod u+w "$fwk/$dep"
        changed=1
        note "  + $dep"
      fi
    done
  done
done

# Each vendored dylib resolves its own @rpath siblings relative to itself, and
# we drop the absolute pixi rpath so the distributed bundle carries no dev-machine
# path. (The main executable already has @executable_path/../Frameworks.)
for lib in "$fwk"/*.dylib; do
  [ -f "$lib" ] || continue
  otool -l "$lib" | grep -q "@loader_path" || install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null
  install_name_tool -delete_rpath "$prefix/lib" "$lib" 2>/dev/null
done
install_name_tool -delete_rpath "$prefix/lib" "$contents/MacOS/TurboKod" 2>/dev/null

# ---------------------------------------------------------------------------
# 4. Sign. Developer ID + hardened runtime when available; else ad-hoc.
# ---------------------------------------------------------------------------
identity="${TURBOKOD_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi

if [ -z "$identity" ]; then
  note "warning: no 'Developer ID Application' identity found - ad-hoc signing."
  note "         The release will run only after a manual Gatekeeper override; notarization is impossible without it."
  identity="-"
fi

sign_dylib() {
  if [ "$identity" = "-" ]; then
    codesign --force --sign - "$1"
  else
    codesign --force --options runtime --timestamp --sign "$identity" "$1"
  fi
}

note "signing with: $identity"
# Inside-out: every vendored dylib first, then the secondary tk-tui executable.
# Signing the .app (below) only covers the main executable named by
# CFBundleExecutable — the terminal-frontend helper in MacOS/ is a separate
# Mach-O that notarization rejects unless it's hardened-runtime signed too.
find "$fwk" -name '*.dylib' -print0 | while IFS= read -r -d '' lib; do
  sign_dylib "$lib"
done
[ -f "$contents/MacOS/tk-tui" ] && sign_dylib "$contents/MacOS/tk-tui"
# ...then the bundle (which signs the main executable), with entitlements +
# hardened runtime when we have a real identity.
if [ "$identity" = "-" ]; then
  codesign --force --sign - "$app" || die "codesign (ad-hoc) failed"
else
  codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" --sign "$identity" "$app" \
    || die "codesign (Developer ID) failed"
fi
codesign --verify --deep --strict --verbose=2 "$app" || die "signature verification failed"

# ---------------------------------------------------------------------------
# 5. Notarize + staple (only meaningful with a real identity + creds).
# ---------------------------------------------------------------------------
# Version-less asset name so the homepage can link the stable
# /releases/latest/download/<name> URL (the version lives in the tag + title).
zip=".build/TurboKod-macos-$arch.zip"
notarized=0
if [ "$identity" != "-" ]; then
  notary_args=()
  if [ -n "${TURBOKOD_NOTARY_PROFILE:-}" ]; then
    notary_args=(--keychain-profile "$TURBOKOD_NOTARY_PROFILE")
  elif [ -n "${TURBOKOD_NOTARY_APPLE_ID:-}" ] \
    && [ -n "${TURBOKOD_NOTARY_PASSWORD:-}" ] \
    && [ -n "${TURBOKOD_NOTARY_TEAM_ID:-}" ]; then
    notary_args=(--apple-id "$TURBOKOD_NOTARY_APPLE_ID" \
                 --password "$TURBOKOD_NOTARY_PASSWORD" \
                 --team-id "$TURBOKOD_NOTARY_TEAM_ID")
  fi

  if [ "${#notary_args[@]}" -gt 0 ]; then
    note "submitting to Apple notary service (this can take a few minutes)..."
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    if xcrun notarytool submit "$zip" "${notary_args[@]}" --wait; then
      note "stapling notarization ticket..."
      xcrun stapler staple "$app" || die "stapler failed"
      xcrun stapler validate "$app" || die "staple validation failed"
      notarized=1
    else
      die "notarytool submission failed (see log above; 'xcrun notarytool log <id> ...' for details)"
    fi
  else
    note "warning: Developer ID signed but no notary creds set - skipping notarization."
    note "         Set TURBOKOD_NOTARY_PROFILE (or TURBOKOD_NOTARY_APPLE_ID/_PASSWORD/_TEAM_ID) to enable."
  fi
fi

# ---------------------------------------------------------------------------
# 6. Final distribution zip (rebuilt after stapling so it carries the ticket).
# ---------------------------------------------------------------------------
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
note "packaged: $zip"

# ---------------------------------------------------------------------------
# 7. Publish to GitHub Releases. Creates the tag at HEAD if it doesn't exist.
# ---------------------------------------------------------------------------
sign_state="ad-hoc signed (not notarized)"
[ "$identity" != "-" ] && sign_state="Developer ID signed"
[ "$notarized" = 1 ] && sign_state="Developer ID signed + notarized + stapled"

body="TurboKod $VERSION - native macOS app (macos-$arch).

- ${sign_state}.
- Self-contained bundle (Mojo runtime + libonig vendored)."
if [ "$notarized" != 1 ]; then
  body="$body
- Not notarized: first launch needs Control-click > Open (or 'xattr -dr com.apple.quarantine TurboKod.app')."
fi

if gh release view "$tag" >/dev/null 2>&1; then
  note "release $tag exists - uploading asset (clobbering)..."
  gh release upload "$tag" "$zip" --clobber || die "asset upload failed"
else
  note "creating release ${tag}..."
  gh release create "$tag" "$zip" --title "TurboKod $VERSION" --notes "$body" \
    || die "release creation failed"
fi

note "done: $(gh release view "$tag" --json url -q .url 2>/dev/null || echo "$tag")"
