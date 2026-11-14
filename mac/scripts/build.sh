#!/bin/bash
# Builds Stand with SwiftPM and assembles mac/build/Stand.app.
# Signed with a self-signed development identity when one exists ("Stand Dev", or the
# ones Noteling uses), so macOS permission grants survive rebuilds; ad-hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if ! OUT=$(swift build -c "$CONFIG" 2>&1); then
  echo "$OUT" | grep -E 'error' | head -20
  echo "build failed"; exit 1
fi
echo "$OUT" | grep -E 'warning' | head -5 || true
BIN=".build/$CONFIG/Stand"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

APP="build/Stand.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Stand"
cp Resources/Info.plist "$APP/Contents/"

# The app reads who Stand is from the repo's text files. Record where the repo is, so the
# app finds them however it is launched.
REPO="$(cd .. && pwd)"
/usr/libexec/PlistBuddy -c "Add :StandProjectRoot string $REPO" "$APP/Contents/Info.plist"

IDENTITY="${STAND_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for candidate in "Stand Dev" "Noteling Dev" "Familiar Dev" "Sidekick Dev"; do
    if echo "$IDS" | grep -q "\"$candidate\""; then IDENTITY="$candidate"; break; fi
  done
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"
