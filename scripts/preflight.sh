#!/usr/bin/env bash
# Checks everything notarisation cares about that can be checked locally.
#
#   ./scripts/preflight.sh [path/to/Murmur.app]
#
# Gatekeeper acceptance is reported but only *enforced* once the app has been
# stapled — before that it cannot pass, and failing on it would block the very
# step that fixes it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Murmur.app}"
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
note() { printf '  \033[33m•\033[0m %s\n' "$1"; }

[ -d "$APP" ] || { echo "no app at $APP — run ./scripts/build-app.sh release first"; exit 1; }
echo "checking $APP"

# Capture once, then inspect the text. Piping codesign into `grep -q` looks
# tidier but is a trap: grep exits on first match, codesign takes SIGPIPE, and
# under `pipefail` the whole pipeline reports failure despite the match. That
# silently inverted the hardened-runtime check.
SIGINFO="$(codesign -d --verbose=2 "$APP" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null)"

# 1. Hardened runtime — mandatory for notarisation.
case "$SIGINFO" in
  *"(runtime)"*|*",runtime)"*) ok "hardened runtime enabled" ;;
  *) bad "hardened runtime MISSING (sign with --options runtime)" ;;
esac

# 2. get-task-allow is a debug entitlement and is rejected outright.
case "$ENTITLEMENTS" in
  *get-task-allow*) bad "get-task-allow present — notarisation will reject this" ;;
  *) ok "no debug entitlement" ;;
esac

# 3. Microphone entitlement, or a hardened-runtime build records silence.
case "$ENTITLEMENTS" in
  *device.audio-input*) ok "microphone entitlement present" ;;
  *) bad "microphone entitlement missing — the app would record silence" ;;
esac

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

# 6. Ad-hoc can't be notarised; a real identity needs a secure timestamp.
case "$SIGINFO" in
  *adhoc*)
    bad "signed ad-hoc — needs a Developer ID Application certificate"
    ;;
  *)
    ok "signed with a real identity"
    case "$SIGINFO" in
      *"Timestamp="*) ok "secure timestamp present" ;;
      *) bad "no secure timestamp (drop --timestamp=none)" ;;
    esac
    ;;
esac

# 7. Gatekeeper. Only meaningful once stapled — before notarisation the correct
#    answer is "Unnotarized Developer ID", which is progress, not a problem.
STAPLED=0
xcrun stapler validate "$APP" >/dev/null 2>&1 && STAPLED=1
# Capture every line. spctl prints the verdict and the source on separate
# lines, so tailing one of them throws away the answer.
VERDICT="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)"
case "$VERDICT" in
  *accepted*) ok "Gatekeeper: accepted ($(printf '%s' "$VERDICT" | grep -o 'source=.*' | head -1))" ;;
  *)
    if [ "$STAPLED" -eq 0 ]; then
      note "Gatekeeper: not yet notarised — expected at this stage"
    else
      bad "Gatekeeper: $(printf '%s' "$VERDICT" | tr '\n' ' ')"
    fi
    ;;
esac

echo
if [ "$fail" -eq 0 ]; then
  [ "$STAPLED" -eq 1 ] && echo "ready to ship" || echo "ready to notarise"
else
  echo "not ready — fix the ✗ items above"
fi
exit "$fail"
