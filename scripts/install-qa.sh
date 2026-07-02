#!/bin/bash

# Builds a Release QA build, stamps a high QA version on the built product,
# re-signs it with the production Developer ID, and installs to /Applications.
#
# Why Developer ID: macOS TCC keys permission grants (Accessibility, Microphone)
# on the signing identity + bundle id. Production ships as Developer ID
# (NK28QT38A3); a QA build signed any other way makes macOS treat it as a
# different app, silently invalidating grants until the app is deleted and
# re-authorized. Signing QA installs identically means you grant once and every
# later install keeps the permissions. (Pre-granting TCC at deploy time is not
# possible on macOS outside MDM.) WHI-53.

set -euo pipefail

DEVELOPER_ID="Developer ID Application: Ismatulla Mansurov (NK28QT38A3)"
QA_VERSION="${QA_VERSION:-1.99.0}"
QA_BUILD="${QA_BUILD:-999}"
APP_PATH="/Applications/Whispera.app"

cd "$(dirname "$0")/.."

echo "Building Release..."
xcodebuild -scheme Whispera -project Whispera.xcodeproj \
  -configuration Release -destination 'platform=macOS' build | tail -2

APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Whispera-*/Build/Products/Release/Whispera.app | head -1)
echo "Built: $APP"

# High QA version so Sparkle never "updates" the QA build back to a release.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${QA_VERSION}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${QA_BUILD}" "$APP/Contents/Info.plist"

echo "Re-signing with: $DEVELOPER_ID"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for xpc in "$SPARKLE"/Versions/*/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    codesign --force --options runtime --sign "$DEVELOPER_ID" "$xpc"
  done
  for helper in "$SPARKLE"/Versions/*/Updater.app "$SPARKLE"/Versions/*/Autoupdate; do
    [ -e "$helper" ] || continue
    codesign --force --options runtime --sign "$DEVELOPER_ID" "$helper"
  done
fi
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [ -e "$fw" ] || continue
  codesign --force --options runtime --sign "$DEVELOPER_ID" "$fw"
done
codesign --force --options runtime \
  --entitlements Whispera.entitlements \
  --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict "$APP"

echo "Installing to $APP_PATH..."
pkill -9 -f "Whispera.app/Contents/MacOS/Whispera" 2>/dev/null || true
sleep 1
rm -rf "$APP_PATH"
ditto "$APP" "$APP_PATH"
open "$APP_PATH"

echo "Installed Whispera ${QA_VERSION} (${QA_BUILD}) signed as production."
echo ""
echo "If permissions look stuck from a previously differently-signed install,"
echo "clear the stale rows ONCE, then re-grant:"
echo "  tccutil reset Accessibility com.macwhisper.app"
echo "  tccutil reset Microphone com.macwhisper.app"
