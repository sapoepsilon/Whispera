#!/bin/bash

# Whispera CI Release & Distribution Script
# Adapted version of release-distribute.sh for GitHub Actions CI environment
#
# Signs the exported app with the Developer ID, notarizes and staples it, then builds a DMG that
# is signed, notarized and stapled as well. Any step that does not fully succeed (notarization
# status other than Accepted, a failed staple, a failed stapler/spctl/codesign check) stops the
# release: nothing unnotarized reaches dist/.

set -euo pipefail

# Configuration
APP_NAME="Whispera"
EXPORT_PATH="./build/Release"
DIST_PATH="./dist"
KEYCHAIN_LOOKUP="${SIGNING_KEYCHAIN:-whispera-signing.keychain-db}"

# Get Developer ID from keychain (set up by setup-keychain.sh)
DEVELOPER_ID=$(security find-identity -v -p codesigning "$KEYCHAIN_LOOKUP" \
    | awk -F'"' '/Developer ID|3rd Party Mac Developer/ { print $2; exit }')

# Validate environment variables
for var in APPLE_ID APP_SPECIFIC_PASSWORD TEAM_ID; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var environment variable not set"
        exit 1
    fi
done

if [ -z "$DEVELOPER_ID" ]; then
    echo "Error: Developer ID certificate not found in keychain"
    echo "Available certificates:"
    security find-identity -v -p codesigning "$KEYCHAIN_LOOKUP"
    exit 1
fi

# notarytool has no stdin option for the password; it is passed per call and never echoed
NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APP_SPECIFIC_PASSWORD" --team-id "$TEAM_ID")

# Empty-array expansion is guarded: /bin/bash 3.2 treats "${a[@]}" of an empty array as unbound
KEYCHAIN_ARGS=()
if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    KEYCHAIN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
fi

sign() {
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID" \
        ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
        "$@"
}

# Reads one key from notarytool's JSON output; prints nothing when the key is absent
json_field() {
    plutil -extract "$2" raw -o - - <<< "$1" 2>/dev/null || :
}

# Submits $1, waits, and fails unless Apple reports exactly "Accepted". The notary log (which
# lists the rejected files and reasons, no credentials) is printed on any other outcome.
notarize() {
    local file="$1" output submit_status=0 id status

    echo "Submitting $(basename "$file") for notarization..."
    output=$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json) \
        || submit_status=$?
    echo "Notarization response: $output"

    id=$(json_field "$output" id)
    if [ -z "$id" ]; then
        echo "Error: notarytool returned no submission id (exit $submit_status)"
        exit 1
    fi

    # The submit output can report a transient state; info is the authoritative final status
    status=$(json_field "$(xcrun notarytool info "$id" "${NOTARY_AUTH[@]}" --output-format json)" status)
    echo "Notarization status for $id: ${status:-unknown}"

    if [ "$status" != "Accepted" ] || [ "$submit_status" -ne 0 ]; then
        echo "Error: notarization of $(basename "$file") was not accepted; notary log:"
        xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" "notary-log-$id.json" \
            && cat "notary-log-$id.json"
        exit 1
    fi
    echo "Notarization accepted"
}

staple() {
    echo "Stapling $(basename "$1")..."
    xcrun stapler staple "$1"
    xcrun stapler validate "$1"
}

echo "Starting ${APP_NAME} CI release and distribution..."
echo "Using Developer ID: $DEVELOPER_ID"

# Clean and create dist directory
rm -rf "$DIST_PATH"
mkdir -p "$DIST_PATH"

# Verify app exists
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at ${APP_PATH}"
    ls -la "$EXPORT_PATH"
    exit 1
fi

echo "Found app at: $APP_PATH"

# Copy app to dist directory
cp -R "$APP_PATH" "$DIST_PATH/"

# Sign inside-out: XPC services first, then frameworks, then main app.
# --deep breaks Sparkle 2.x XPC services by stripping their entitlements.
APP_BUNDLE="${DIST_PATH}/${APP_NAME}.app"

if [ -d "$APP_BUNDLE/Contents/XPCServices" ]; then
  echo "Found app-level XPCServices (Sparkle 2.x incompatible). Removing..."
  rm -rf "$APP_BUNDLE/Contents/XPCServices"
fi

SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  for xpc in "$SPARKLE_FRAMEWORK"/Versions/*/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    echo "  Signing Sparkle XPC service: $(basename "$xpc")"
    sign "$xpc"
  done

  for helper in "$SPARKLE_FRAMEWORK"/Versions/*/Updater.app "$SPARKLE_FRAMEWORK"/Versions/*/Autoupdate; do
    [ -e "$helper" ] || continue
    echo "  Signing Sparkle helper: $(basename "$helper")"
    sign "$helper"
  done
fi

for framework in "$APP_BUNDLE"/Contents/Frameworks/*.framework; do
  [ -e "$framework" ] || continue
  echo "  Signing framework: $(basename "$framework")"
  sign "$framework"
done

# Login items (the Mac link helper) are nested apps: signed on their own, before the app that
# embeds them, or the app's signature seals an unsigned bundle and notarization refuses it.
for login_item in "$APP_BUNDLE"/Contents/Library/LoginItems/*.app; do
  [ -e "$login_item" ] || continue
  echo "  Signing login item: $(basename "$login_item")"
  sign "$login_item"
done

echo "  Signing main app bundle..."
sign --entitlements "${APP_NAME}.entitlements" "$APP_BUNDLE"

echo "Verifying code signature..."
codesign -vvv --deep --strict "$APP_BUNDLE"

# Captured first so a short read cannot SIGPIPE codesign under pipefail
SIGNING_INFO=$(codesign --display --verbose=2 "$APP_BUNDLE" 2>&1)
echo "Code signing information:"
printf '%s\n' "$SIGNING_INFO" | sed -n '1,10p'
ENTITLEMENTS=$(codesign --display --entitlements - "$APP_BUNDLE" 2>&1)
echo "Entitlements embedded:"
printf '%s\n' "$ENTITLEMENTS" | sed -n '1,20p'

cd "$DIST_PATH"

# Notarize the app (submitted as a zip), staple it, and check Gatekeeper accepts it
ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip"
notarize "${APP_NAME}.zip"
staple "${APP_NAME}.app"
spctl -a -vv -t exec "${APP_NAME}.app"

# Zip of the stapled app for the release
rm -f "${APP_NAME}.zip"
ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.app.zip"

# Create DMG
echo "Creating DMG..."
ln -s /Applications Applications
hdiutil create -volname "$APP_NAME" -srcfolder . -ov -format UDZO "${APP_NAME}.dmg"
rm -f Applications

# The DMG carries its own Developer ID signature and ticket, so Gatekeeper accepts the download
# itself and release.yml can verify it before the Sparkle signature is made
codesign --force --timestamp --sign "$DEVELOPER_ID" \
    ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "${APP_NAME}.dmg"
codesign --verify --strict --verbose=2 "${APP_NAME}.dmg"
notarize "${APP_NAME}.dmg"
staple "${APP_NAME}.dmg"
spctl -a -vv -t open --context context:primary-signature "${APP_NAME}.dmg"

# Go back to project root
cd - > /dev/null

# Get version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "Info.plist")

# Versioned copy of the stapled DMG (byte-identical, ticket included)
DMG_VERSIONED="${APP_NAME}-${VERSION}.dmg"
cp "${DIST_PATH}/${APP_NAME}.dmg" "${DIST_PATH}/${DMG_VERSIONED}"

echo "CI distribution complete!"
echo "Release artifacts:"
ls -lh "${DIST_PATH}/${APP_NAME}.dmg" "${DIST_PATH}/${DMG_VERSIONED}" "${DIST_PATH}/${APP_NAME}.app.zip"

# The Sparkle signature and appcast are made by later release.yml jobs from the uploaded DMG; the
# private key never reaches this script or the job that runs it (scripts/write-appcast.sh).

echo ""
echo "Ready for GitHub release!"
