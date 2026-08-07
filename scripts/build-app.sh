#!/usr/bin/env bash
# Assembles Murmur.app from the SwiftPM build.
#
# A bare executable can't hold TCC permissions or prompt for the microphone —
# macOS keys both to a bundle identity — so everything has to run from the .app.
#
#   ./scripts/build-app.sh            debug
#   ./scripts/build-app.sh release    release
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Murmur.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Murmur"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# VERSION is the single source of truth — the plist, the git tag and the
# changelog all read from it, so they can't drift apart.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
# CFBundleVersion must increase monotonically for updaters to compare builds;
# the commit count does that and stays meaningful.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -replace MurmurGitSHA -string "$SHA" "$APP/Contents/Info.plist"

# Generated from scripts/make-icon.swift rather than checked in as a binary.
if [ ! -f "$ROOT/Resources/Murmur.icns" ]; then
  ( cd "$ROOT" && swift scripts/make-icon.swift >/dev/null \
    && iconutil -c icns build/Murmur.iconset -o Resources/Murmur.icns )
fi
cp "$ROOT/Resources/Murmur.icns" "$APP/Contents/Resources/Murmur.icns"

# Prefer a stable local identity so macOS keeps TCC grants across rebuilds.
# Falls back to ad-hoc, which works but resets Microphone / Accessibility /
# Input Monitoring every single build. See scripts/make-signing-cert.sh.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Murmur Dev"; then
  IDENTITY="Murmur Dev"
else
  IDENTITY="-"
fi

# Hardened runtime is mandatory for notarisation, and it is applied to local
# builds too so a problem surfaces here rather than at release time.
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ROOT/Resources/Murmur.entitlements" \
  --timestamp=none \
  "$APP"

echo "built $APP — v$VERSION ($BUILD, $SHA, $CONFIG)"
