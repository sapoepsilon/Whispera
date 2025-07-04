#!/bin/bash

# Whispera CI Release & Distribution Script
# Adapted version of release-distribute.sh for GitHub Actions CI environment

set -e

# Configuration
APP_NAME="Whispera"
EXPORT_PATH="./build/Release"
DIST_PATH="./dist"

# Get Developer ID from keychain (set up by setup-keychain.sh)
DEVELOPER_ID=$(security find-identity -v -p codesigning "${SIGNING_KEYCHAIN:-whispera-signing.keychain-db}" | grep "Developer ID" | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')

# Validate environment variables
if [ -z "$APPLE_ID" ]; then
    echo "❌ Error: APPLE_ID environment variable not set"
    exit 1
fi

if [ -z "$APP_SPECIFIC_PASSWORD" ]; then
    echo "❌ Error: APP_SPECIFIC_PASSWORD environment variable not set"
    exit 1
fi

if [ -z "$TEAM_ID" ]; then
    echo "❌ Error: TEAM_ID environment variable not set"
    exit 1
fi

if [ -z "$DEVELOPER_ID" ]; then
    echo "❌ Error: Developer ID certificate not found in keychain"
    echo "🔍 Available certificates:"
    security find-identity -v -p codesigning "${SIGNING_KEYCHAIN:-whispera-signing.keychain-db}" || true
    exit 1
fi

echo "🚀 Starting ${APP_NAME} CI release and distribution..."
echo "🔑 Using Developer ID: $DEVELOPER_ID"

# Clean and create dist directory
echo "🧹 Preparing distribution directory..."
rm -rf "$DIST_PATH"
mkdir -p "$DIST_PATH"

# Verify app exists
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App not found at ${APP_PATH}"
    echo "🔍 Contents of ${EXPORT_PATH}:"
    ls -la "$EXPORT_PATH" || true
    exit 1
fi

echo "📦 Found app at: $APP_PATH"

# Copy app to dist directory
cp -R "$APP_PATH" "$DIST_PATH/"

# Sign the app with entitlements
echo "🔏 Signing ${APP_NAME} with entitlements..."
echo "🔑 Certificate: $DEVELOPER_ID"

# Get the keychain parameter if set
KEYCHAIN_PARAM=""
if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    KEYCHAIN_PARAM="--keychain ${SIGNING_KEYCHAIN}"
fi

codesign --force --deep --options runtime \
  --entitlements "${APP_NAME}.entitlements" \
  --sign "$DEVELOPER_ID" \
  $KEYCHAIN_PARAM \
  "${DIST_PATH}/${APP_NAME}.app"

# Verify code signing
echo "🔍 Verifying code signature..."
codesign -vvv --deep --strict "${DIST_PATH}/${APP_NAME}.app"

if [ $? -eq 0 ]; then
    echo "✅ Code signature is valid"
else
    echo "❌ Code signature verification failed"
    exit 1
fi

echo "📋 Code signing information:"
codesign --display --verbose=2 "${DIST_PATH}/${APP_NAME}.app" 2>&1 | head -10

echo "📋 Entitlements embedded:"
codesign --display --entitlements - "${DIST_PATH}/${APP_NAME}.app" | head -20

# Create zip for notarization
echo "📦 Creating ZIP for notarization..."
cd "$DIST_PATH"
ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip"

# Create a copy for release artifacts
cp "${APP_NAME}.zip" "${APP_NAME}.app.zip"

# Submit for notarization
echo "📤 Submitting for notarization..."
echo "🍎 Apple ID: $APPLE_ID"
echo "👥 Team ID: $TEAM_ID"

NOTARIZATION_OUTPUT=$(xcrun notarytool submit "${APP_NAME}.zip" \
  --apple-id "$APPLE_ID" \
  --password "$APP_SPECIFIC_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait \
  --output-format json)

echo "📄 Notarization response:"
echo "$NOTARIZATION_OUTPUT"

# Check notarization status
NOTARIZATION_STATUS=$(echo "$NOTARIZATION_OUTPUT" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "unknown")

echo "🎯 Notarization status: $NOTARIZATION_STATUS"

if [ "$NOTARIZATION_STATUS" = "Accepted" ]; then
    echo "✅ Notarization successful"
    
    # Staple the notarization
    echo "📎 Stapling notarization..."
    xcrun stapler staple "${APP_NAME}.app"
    
    if [ $? -eq 0 ]; then
        echo "✅ Stapling successful"
        
        # Re-create zip with stapled app
        rm "${APP_NAME}.zip"
        ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip"
        cp "${APP_NAME}.zip" "${APP_NAME}.app.zip"
    else
        echo "⚠️ Stapling failed - app may show security warnings"
    fi
else
    echo "⚠️ Notarization failed or pending - app may show security warnings"
    echo "📋 You can check status later with:"
    echo "xcrun notarytool log <submission-id> --apple-id $APPLE_ID --password <password> --team-id $TEAM_ID"
fi

# Create Applications symlink for DMG
echo "🔗 Creating Applications symlink..."
ln -s /Applications Applications

# Clean up the zip file before creating DMG (keep the .app.zip for releases)
rm -f "${APP_NAME}.zip"

# Create DMG
echo "💿 Creating DMG..."
hdiutil create -volname "$APP_NAME" -srcfolder . -ov -format UDZO "${APP_NAME}.dmg"

# Clean up symlink
rm -f Applications

# Go back to project root
cd - > /dev/null

echo "✅ CI distribution complete!"
echo "📦 DMG created: ${DIST_PATH}/${APP_NAME}.dmg"
echo "📱 App bundle: ${DIST_PATH}/${APP_NAME}.app"
echo "🗜️ Zipped app: ${DIST_PATH}/${APP_NAME}.app.zip"

# Show final file sizes
echo "📊 Release artifacts:"
ls -lh "${DIST_PATH}/"*.dmg "${DIST_PATH}/"*.zip 2>/dev/null || true

echo ""
echo "🎯 Ready for GitHub release!"