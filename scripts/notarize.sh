#!/usr/bin/env bash
# Builds, signs, notarises and staples a distributable Murmur.dmg.
#
#   ./scripts/notarize.sh
#
# Prerequisites (one-time, see DISTRIBUTION.md):
#   1. A "Developer ID Application" certificate in your login keychain
#   2. A notarytool keychain profile named "murmur"
#
# Apple's notary service is the only step that can't be checked locally — it
# runs a malware scan server-side. Everything checkable is checked first, so a
# failure here is almost always a credential problem rather than the app.
set -euo pipefail

PROFILE="${MURMUR_NOTARY_PROFILE:-murmur}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Murmur.app"
DIST="$ROOT/build/dist"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DMG="$DIST/Murmur-$VERSION.dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- preconditions -----------------------------------------------------------

security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
  || die "no Developer ID Application certificate. See DISTRIBUTION.md step 1."

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || die "no notarytool profile '$PROFILE'. See DISTRIBUTION.md step 2."

# --- build -------------------------------------------------------------------

step "Building release v$VERSION"
"$ROOT/scripts/build-app.sh" release

step "Pre-flight"
# Everything notarisation checks that we can check ourselves. Cheaper to fail
# here than to wait on Apple.
"$ROOT/scripts/preflight.sh" "$APP" || die "pre-flight failed"

# --- notarise the app --------------------------------------------------------

rm -rf "$DIST" && mkdir -p "$DIST"

step "Submitting app to Apple"
# notarytool wants an archive, not a bundle. ditto preserves the signature;
# plain zip does not.
ditto -c -k --keepParent "$APP" "$DIST/Murmur.zip"
xcrun notarytool submit "$DIST/Murmur.zip" --keychain-profile "$PROFILE" --wait \
  || die "notarisation failed — run: xcrun notarytool log <id> --keychain-profile $PROFILE"

step "Stapling the app"
# Staple the app itself, not just the DMG, so it still validates when someone
# drags it out of the disk image.
xcrun stapler staple "$APP"
rm -f "$DIST/Murmur.zip"

# --- package -----------------------------------------------------------------

step "Building disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# The Applications symlink is what makes "drag to install" obvious.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Murmur" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

step "Signing and notarising the disk image"
IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait \
  || die "disk image notarisation failed"
xcrun stapler staple "$DMG"

# --- verify ------------------------------------------------------------------

step "Verifying what a user's Mac will see"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/  /'
xcrun stapler validate "$DMG" 2>&1 | sed 's/^/  /'

printf '\n\033[32m✓\033[0m %s\n' "$DMG"
echo "  Upload with: gh release create v$VERSION \"$DMG\" --notes-from-tag"
