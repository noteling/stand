#!/bin/bash
# Packages Stand for another Mac: mac/dist/Stand.app and mac/dist/Stand-<build>.dmg.
#
#   mac/scripts/package.sh              for Apple silicon and Intel, signed with the best identity this Mac has
#   mac/scripts/package.sh --notarize   also has Apple notarize it, so it opens with a double click anywhere.
#
# Notarizing needs two things on this Mac. Both belong to an Apple developer account, neither to an app:
#   - a "Developer ID Application" certificate, which signs every app that account ships;
#   - a saved Apple login for the notary service (a notarytool profile in the keychain). Stand has its own,
#     called stand-notary, and does not fall back to any other app's. It is made once, by the person whose
#     account it is, with an app-specific password from account.apple.com that is typed at notarytool's prompt:
#       xcrun notarytool store-credentials stand-notary --apple-id <Apple ID> --team-id <team ID>
#     STAND_NOTARY_PROFILE names a different profile.
# STAND_DIST puts the result somewhere other than mac/dist (a full path).
#
# Inside the app: identity/, talks/, prompts/, a starting brain.json. Never inside it: .env, brief.md,
# context/, linked/, runs/. On the other Mac those are the person's own, in ~/Stand.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(cd .. && pwd)"
NOTARIZE=0; [ "${1:-}" = "--notarize" ] && NOTARIZE=1
PROFILE="${STAND_NOTARY_PROFILE:-stand-notary}"
BUILD="$(date '+%Y-%m-%d %H:%M')"
STAMP="$(date '+%Y%m%d-%H%M')"
DIST="${STAND_DIST:-dist}"
APP="$DIST/Stand.app"
DMG="$DIST/Stand-$STAMP.dmg"

IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVID="$(echo "$IDS" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"

if [ "$NOTARIZE" = 1 ]; then   # asked before the build, which takes minutes
  [ -n "$DEVID" ] || { echo "notarizing needs a Developer ID Application certificate, and this Mac has none"; exit 1; }
  if ! PROBLEM="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1)"; then
    if echo "$PROBLEM" | grep -q "No Keychain password item"; then
      TEAM="$(echo "$DEVID" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
      echo "Stand has no saved Apple login for notarizing on this Mac yet (a notarytool profile called '$PROFILE')."
      echo "It is made once, by you, because it takes a password that should not pass through anything else:"
      echo "  1. At account.apple.com, under Sign-In and Security, make an app-specific password."
      echo "  2. In Terminal:  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id ${TEAM:-<your team ID>}"
      echo "     It asks for that password and keeps it in the keychain."
    else
      echo "Apple did not accept the notarytool profile '$PROFILE':"
      echo "$PROBLEM"
    fi
    exit 1
  fi
fi

echo "== building for Apple silicon and for Intel"
swift build -c release 2>&1 | grep -E "error|Compiling|Build complete" | tail -1
swift build -c release --triple x86_64-apple-macosx14.2 --scratch-path .build-x86 2>&1 | grep -E "error|Build complete" | tail -1
ARM=".build/release/Stand"; INTEL=".build-x86/x86_64-apple-macosx/release/Stand"
[ -x "$ARM" ] && [ -x "$INTEL" ] || { echo "build failed"; exit 1; }

echo "== assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/defaults/context"
lipo -create "$ARM" "$INTEL" -output "$APP/Contents/MacOS/Stand"
cp Resources/Info.plist "$APP/Contents/"
/usr/libexec/PlistBuddy -c "Add :StandBuild string $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STAMP" "$APP/Contents/Info.plist"
D="$APP/Contents/Resources/defaults"
cp -R "$REPO/identity" "$REPO/prompts" "$D/"
# Of the talks, only Stand's own goes along. A talk its brain prepared on this Mac is about
# somebody's meeting, and may be about a system that is nobody else's business.
mkdir -p "$D/talks"
cp "$REPO/talks/introducing-stand.md" "$D/talks/"
cp "$REPO/context/README.md" "$D/context/README.md"
cp Resources/brain.default.json "$D/brain.json"
cp Resources/home-README.md "$D/README.md"
find "$D" -name ".DS_Store" -delete

echo "== signing"
if [ -n "$DEVID" ]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Stand.entitlements --sign "$DEVID" "$APP"
  SIGNED="$DEVID"
else
  IDENTITY="-"
  for candidate in "Stand Dev" "Noteling Dev" "Familiar Dev" "Sidekick Dev"; do
    if echo "$IDS" | grep -q "\"$candidate\""; then IDENTITY="$candidate"; break; fi
  done
  codesign --force --sign "$IDENTITY" "$APP"
  SIGNED="$IDENTITY (not a Developer ID: the other Mac will refuse it until told to open it anyway)"
fi
codesign --verify --strict "$APP"

staple() {   # the ticket can take a minute to reach Apple's servers after "Accepted"
  for i in 1 2 3 4 5 6; do xcrun stapler staple "$1" >/dev/null 2>&1 && return 0; sleep 30; done
  return 1
}
NOTARIZED="no"
if [ "$NOTARIZE" = 1 ]; then
  echo "== notarizing the app (a few minutes)"
  ditto -c -k --keepParent "$APP" "$DIST/Stand.zip"
  xcrun notarytool submit "$DIST/Stand.zip" --keychain-profile "$PROFILE" --wait
  staple "$APP"
  rm "$DIST/Stand.zip"
  NOTARIZED="yes"
fi

echo "== making $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
{
  echo "Stand, build $BUILD"
  echo
  echo "1. Drag Stand to Applications, and open it from there."
  if [ "$NOTARIZED" = "no" ]; then
    echo "   This build has not been checked by Apple, so macOS will refuse it the first time."
    echo "   Then open System Settings > Privacy & Security, scroll down, and choose Open Anyway."
    echo "   Or, in Terminal:  xattr -dr com.apple.quarantine /Applications/Stand.app"
  fi
  echo "2. Paste a Gemini API key into the panel (aistudio.google.com/apikey). It is asked for once."
  echo "3. Press Start the talk, or choose None: join the discussion under Talk and press Join the meeting."
  echo "   macOS asks for the microphone, and for system audio recording"
  echo "   so that Stand can hear a call on this Mac. Allow both."
  echo "4. For Stand to look things up, Claude Code has to be on this Mac and signed in."
  echo "   Without it Stand still talks and listens, and says when it does not know."
  echo
  echo "Everything of yours is in the folder Stand in your home folder (the panel's \"Stand's files\" opens it):"
  echo "your keys, brain.json, the brief, your notes, and a folder for each session under runs."
  echo "To report a problem, choose Make a Problem Report in the Stand menu and send the zip it shows you."
} > "$STAGE/Read me first.txt"
rm -f "$DMG"
hdiutil create -volname "Stand" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [ -n "$DEVID" ]; then codesign --force --timestamp --sign "$DEVID" "$DMG"; fi
if [ "$NOTARIZE" = 1 ]; then
  echo "== notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  staple "$DMG"
fi

echo
echo "built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "  for: $(lipo -archs "$APP/Contents/MacOS/Stand"), macOS 14.2 or later"
echo "  signed: $SIGNED"
echo "  notarized: $NOTARIZED"
