#!/bin/bash
# Packages Stand for another Mac: mac/dist/Stand.app and mac/dist/Stand-<build>.dmg.
#
#   mac/scripts/package.sh              for Apple silicon and Intel, signed with the best identity this Mac has
#   mac/scripts/package.sh --notarize   also has Apple notarize it, so it opens with a double click anywhere.
#   mac/scripts/package.sh --release    a version to publish: notarized, built only from a checkout with nothing
#                                       uncommitted, and named mac/dist/Stand-<version>.dmg, with SHA256SUMS.txt
#                                       beside it. The version is CFBundleShortVersionString in Resources/Info.plist.
#                                       Publishing is a separate step: a GitHub release with those two files.
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
# Inside the app: identity/, talks/, prompts/, a starting brain.json, the licence. Never inside it: .env,
# brief.md, context/, linked/, runs/. On the other Mac those are the person's own, in ~/Stand.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(cd .. && pwd)"
NOTARIZE=0; RELEASE=0
for option in "$@"; do
  case "$option" in
    --notarize) NOTARIZE=1 ;;
    --release) RELEASE=1; NOTARIZE=1 ;;
    *) echo "package.sh does not know the option $option"; exit 1 ;;
  esac
done
PROFILE="${STAND_NOTARY_PROFILE:-stand-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD="$(date '+%Y-%m-%d %H:%M')"
STAMP="$(date '+%Y%m%d-%H%M')"
DIST="${STAND_DIST:-dist}"
APP="$DIST/Stand.app"
DMG="$DIST/Stand-$STAMP.dmg"
TITLE="Stand, build $BUILD"
if [ "$RELEASE" = 1 ]; then
  # A published version is built from a commit, so that what people run is what they can read.
  if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
    echo "A release is built from a checkout with nothing uncommitted. These have changed:"
    git -C "$REPO" status --short | head -20
    exit 1
  fi
  BUILD="$VERSION ($BUILD, $(git -C "$REPO" rev-parse --short HEAD))"
  DMG="$DIST/Stand-$VERSION.dmg"
  TITLE="Stand $VERSION"
fi

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
cp "$REPO/LICENSE" "$REPO/NOTICE" "$APP/Contents/Resources/"
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
  echo "$TITLE"
  echo
  echo "Stand is an AI that attends meetings and speaks up, out loud. This is an early version:"
  echo "most of it has been tried with scripted voices only. github.com/noteling/stand says what has"
  echo "been tried and what has not."
  echo
  echo "1. Drag Stand to Applications, and open it from there."
  if [ "$NOTARIZED" = "no" ]; then
    echo "   This build has not been checked by Apple, so macOS will refuse it the first time."
    echo "   Then open System Settings > Privacy & Security, scroll down, and choose Open Anyway."
    echo "   Or, in Terminal:  xattr -dr com.apple.quarantine /Applications/Stand.app"
  fi
  echo "2. Paste a Gemini API key into the panel (aistudio.google.com/apikey). It is asked for once."
  echo "   The key is yours and so is the bill: about 20 cents for the three minutes in which Stand"
  echo "   introduces itself and takes a few questions, and by our estimate 5 to 10 dollars for an"
  echo "   hour of steady talk."
  echo "3. Press Start the talk, or choose None: join the discussion under Talk and press Join the meeting."
  echo "   macOS asks for the microphone, and for system audio recording"
  echo "   so that Stand can hear a call on this Mac. Allow both."
  echo "4. For Stand to look things up, Claude Code has to be on this Mac and signed in."
  echo "   Without it Stand still talks and listens, and says when it does not know."
  echo
  echo "Before you take it into a meeting:"
  echo
  echo "- Tell the people there. Stand listens to the meeting and keeps a recording of every session"
  echo "  on this Mac, under runs in your Stand folder. Nothing deletes those but you."
  echo "- The meeting's sound goes to Google, under your key, for as long as Stand is in the meeting."
  echo "  With Claude Code on this Mac, what is said in the meeting also goes to Anthropic, as text,"
  echo "  under that login, with what Stand looks up and the notes it looks in. Nothing goes to the"
  echo "  people who make Stand."
  echo "- Anyone who speaks in the meeting can ask Stand things. So it starts out cautious: it looks in"
  echo "  the notes and folders you give it and searches the web, and asks you in the panel before"
  echo "  anything else. brain.json in your Stand folder changes that."
  echo
  echo "Everything of yours is in the folder Stand in your home folder (the panel's \"Stand's files\" opens it):"
  echo "your keys, brain.json, the brief, your notes, and a folder for each session under runs."
  echo
  echo "When something goes wrong: github.com/noteling/stand/issues. Make a Problem Report in the Stand"
  echo "menu makes a zip that holds the last session, its recording included. Send that to a person you"
  echo "trust with the recording. Do not attach it to a public issue."
  echo
  echo "Stand is open source under the Apache License 2.0. The licence is inside the app, in"
  echo "Stand.app/Contents/Resources."
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

if [ "$RELEASE" = 1 ]; then
  (cd "$DIST" && shasum -a 256 "Stand-$VERSION.dmg" > SHA256SUMS.txt)
fi

echo
echo "built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "  for: $(lipo -archs "$APP/Contents/MacOS/Stand"), macOS 14.2 or later"
echo "  signed: $SIGNED"
echo "  notarized: $NOTARIZED"
