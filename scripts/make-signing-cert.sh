#!/usr/bin/env bash
# Creates a local self-signed code-signing identity called "Murmur Dev".
#
# Why this exists: macOS ties TCC permissions (Microphone, Accessibility, Input
# Monitoring) to an app's code signature. An ad-hoc signature changes on every
# rebuild, so every rebuild wipes the grants and you re-approve three prompts.
# A stable identity keeps them.
#
# This is NOT a Developer ID — it does nothing for distribution. Shipping to
# other people still needs a real Apple certificate (SPEC.md §9).
#
# Run once:  ./scripts/make-signing-cert.sh
set -euo pipefail

NAME="Murmur Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity \"$NAME\" already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" \
  -x509 -days 3650 \
  -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

# OpenSSL 3 defaults to a PKCS12 MAC that macOS's Security framework rejects
# ("MAC verification failed"). These legacy algorithms are what it accepts.
PASS="murmur"
openssl pkcs12 -export \
  -out "$TMP/identity.p12" \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout "pass:$PASS" 2>/dev/null

# -T /usr/bin/codesign pre-authorises codesign so it doesn't prompt every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

# A self-signed cert isn't a usable code-signing identity until it's trusted,
# and marking it trusted requires an authorisation prompt — so that step can't
# be scripted silently. Export the cert and print the command to finish it.
cp "$TMP/cert.pem" /tmp/murmur-dev-cert.pem

echo "created \"$NAME\" — one manual step left."
echo
echo "Run this and enter your login password when asked:"
echo
echo "  security add-trusted-cert -r trustRoot -p codeSign \\"
echo "    -k ~/Library/Keychains/login.keychain-db /tmp/murmur-dev-cert.pem"
echo
echo "Then re-run ./scripts/build-app.sh — permissions will survive rebuilds."
