#!/usr/bin/env bash
# Checks everything notarisation cares about that can be checked locally.
# Run before submitting a release.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Murmur.app}"
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }

[ -d "$APP" ] || { echo "no app at $APP — run ./scripts/build-app.sh release first"; exit 1; }
echo "checking $APP"

# 1. Hardened runtime — mandatory.
if codesign -d --verbose=2 "$APP" 2>&1 | grep -q "runtime"; then
  ok "hardened runtime enabled"
else
  bad "hardened runtime MISSING (add --options runtime)"
fi

# 2. get-task-allow is a debug entitlement and is rejected outright.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null | grep -q "get-task-allow"; then
  bad "get-task-allow present — notarisation will reject this"
else
  ok "no debug entitlement"
fi

# 3. Microphone entitlement, or a hardened-runtime build captures silence.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null | grep -q "device.audio-input"; then
  ok "microphone entitlement present"
else
  bad "microphone entitlement missing — the app will record silence"
fi

# 4. Every nested mach-O must carry its own signature.
unsigned=0
while read -r f; do
  file "$f" 2>/dev/null | grep -q "Mach-O" || continue
  codesign -v "$f" 2>/dev/null || { bad "unsigned: ${f#"$APP"/}"; unsigned=1; }
done < <(find "$APP" -type f -perm +111 2>/dev/null)
[ "$unsigned" -eq 0 ] && ok "all nested code signed"

# 5. Full signature check.
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  ok "signature verifies (deep, strict)"
else
  bad "signature verification failed"
fi

# 6. Ad-hoc cannot be notarised, and needs a secure timestamp.
if codesign -d --verbose=2 "$APP" 2>&1 | grep -q "adhoc"; then
  bad "signed ad-hoc — needs a Developer ID Application certificate"
else
  ok "signed with a real identity"
  codesign -dvv "$APP" 2>&1 | grep -q "Timestamp=" \
    && ok "secure timestamp present" \
    || bad "no secure timestamp (drop --timestamp=none)"
fi

# 7. Gatekeeper's own verdict — the closest local proxy for the real thing.
verdict="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tail -1)"
case "$verdict" in
  *accepted*) ok "spctl: accepted" ;;
  *) bad "spctl: $verdict" ;;
esac

echo
[ "$fail" -eq 0 ] && echo "ready to notarise" || echo "not ready — fix the ✗ items above"
exit "$fail"
