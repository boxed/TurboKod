#!/usr/bin/env bash
# Build a self-contained, signed (and, when creds exist, notarized + stapled)
# TurboKod.app, zip it, and publish it to the GitHub Releases page.
#
# Unlike `make app`, the bundle this produces is portable *across machines*:
# it vendors the Mojo runtime dylibs + libonig out of the pixi env into
# Contents/Frameworks/ (the dev-only build keeps loading those from absolute
# pixi paths - see docs/app-bundle.md "What's not bundled").
#
#   make release                 # prompts for the next version (defaults to a
#                                 # patch bump of the current Info.plist version)
#   make release VERSION=0.0.2    # explicit version, no prompt (also names the tag)
#
# The chosen version is stamped into the source Info.plist, committed as
# "Release vX.Y.Z", and tagged + pushed before the bundle is built.
#
# Signing + notarization are MANDATORY for a published release. We NEVER ship a
# release that isn't Developer ID signed *and* Apple-notarized + stapled; the
# script aborts up front (before pushing the tag or building) if either is
# unavailable, rather than degrading to an ad-hoc / un-notarized bundle.
#   * Developer ID Application cert in the keychain -> hardened-runtime signed.
#     Override which identity with TURBOKOD_SIGN_IDENTITY="Developer ID Application: ...".
#     No such cert -> hard error.
#   * Notary credentials -> submitted to Apple + stapled. Provide either:
#       TURBOKOD_NOTARY_PROFILE=<keychain-profile>   (xcrun notarytool store-credentials)
#         (defaults to "turbokod-notary" if unset)
#     or all three of:
#       TURBOKOD_NOTARY_APPLE_ID / TURBOKOD_NOTARY_PASSWORD / TURBOKOD_NOTARY_TEAM_ID
#     None resolvable -> hard error.
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
# 0. Notarization is MANDATORY. Validate signing + notary credentials up front,
#    BEFORE we push a tag or spend minutes building a bundle we couldn't notarize
#    anyway. The actual sign / notarize still happens in steps 5-6; this just
#    fails fast so we never publish (or even tag) a non-notarized release.
# ---------------------------------------------------------------------------
: "${TURBOKOD_NOTARY_PROFILE:=turbokod-notary}"

preflight_identity="${TURBOKOD_SIGN_IDENTITY:-}"
[ -n "$preflight_identity" ] || preflight_identity="$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$preflight_identity" ] \
  || die "no 'Developer ID Application' identity in the keychain. A published release must be Developer ID signed + notarized; refusing to continue (ad-hoc signing is not allowed for releases)."

if xcrun notarytool history --keychain-profile "$TURBOKOD_NOTARY_PROFILE" >/dev/null 2>&1; then
  : # keychain profile credentials are valid
elif [ -n "${TURBOKOD_NOTARY_APPLE_ID:-}" ] \
  && [ -n "${TURBOKOD_NOTARY_PASSWORD:-}" ] \
  && [ -n "${TURBOKOD_NOTARY_TEAM_ID:-}" ]; then
  : # explicit Apple-ID credentials provided
else
  die "notary credentials unavailable: keychain profile '$TURBOKOD_NOTARY_PROFILE' not found and TURBOKOD_NOTARY_APPLE_ID/_PASSWORD/_TEAM_ID unset. Run 'xcrun notarytool store-credentials' (or set those env vars). Releases must be notarized; refusing to continue."
fi

# ---------------------------------------------------------------------------
# 1. Version. An explicit VERSION (e.g. `make release VERSION=0.0.2`) is used
#    as-is and non-interactively. Otherwise read the current version from the
#    source Info.plist and prompt for the next one, defaulting to a patch bump.
# ---------------------------------------------------------------------------
current="$(plutil -extract CFBundleShortVersionString raw "$plist_src" 2>/dev/null)" \
  || die "could not read CFBundleShortVersionString from $plist_src"

VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
  # Default = patch bump of the current version (last dotted numeric field +1).
  default="$(python3 - "$current" <<'PY'
import re, sys
parts = sys.argv[1].split(".")
for i in range(len(parts) - 1, -1, -1):
    m = re.match(r"^(\d+)(.*)$", parts[i])
    if m:
        parts[i] = str(int(m.group(1)) + 1) + m.group(2)
        break
print(".".join(parts))
PY
)"
  printf '[release] current version is %s. Next version [%s]: ' "$current" "$default" >&2
  read -r reply < /dev/tty || die "no tty to read version from; pass VERSION=x.y.z"
  VERSION="${reply:-$default}"
fi
[ -n "$VERSION" ] || die "empty version"
tag="v$VERSION"
note "releasing TurboKod $VERSION ($tag) for macos-$arch"

# ---------------------------------------------------------------------------
# 2. Stamp the version into the *source* Info.plist, commit that bump, and
#    create + push the tag so the released commit carries the new version.
# ---------------------------------------------------------------------------
plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist_src"
plutil -replace CFBundleVersion -string "$VERSION" "$plist_src"

if ! git diff --quiet -- "$plist_src"; then
  note "committing version bump..."
  git commit -m "Release $tag" -- "$plist_src" || die "git commit failed"
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  note "tag $tag already exists locally - reusing it"
else
  git tag "$tag" || die "git tag failed"
fi
note "pushing commit + tag..."
git push origin HEAD || die "git push (commit) failed"
git push origin "$tag" || die "git push (tag) failed"

# ---------------------------------------------------------------------------
# 3. Build the bundle via the normal path (also re-copies the dylib + assets).
#    run_swift.sh copies the now-stamped source plist into the bundle, so the
#    .app picks up the new version automatically.
# ---------------------------------------------------------------------------
note "building bundle (run_swift.sh)..."
TURBOKOD_BUILD_ONLY=1 ./run_swift.sh || die "bundle build failed"
[ -d "$app" ] || die "$app missing after build"

# ---------------------------------------------------------------------------
# 4. Vendor the Mojo runtime + libonig into Frameworks/ so the .app runs on a
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
# 5. Sign. Developer ID + hardened runtime when available; else ad-hoc.
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
# 6. Notarize + staple (only meaningful with a real identity + creds).
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
    die "no notary credentials resolved at notarization time (should have been caught by pre-flight)."
  fi
fi

# Notarization is mandatory: never publish a release that wasn't stapled.
[ "$notarized" = 1 ] \
  || die "refusing to publish a non-notarized release (identity='$identity', notarized=$notarized). A release must be Developer ID signed + Apple-notarized + stapled."

# ---------------------------------------------------------------------------
# 7. Final distribution zip (rebuilt after stapling so it carries the ticket).
# ---------------------------------------------------------------------------
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
note "packaged: $zip"

# ---------------------------------------------------------------------------
# 8. Publish to GitHub Releases. The tag was already created + pushed above.
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
