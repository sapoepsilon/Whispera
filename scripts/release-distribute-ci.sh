#!/bin/bash

# Whispera CI Release & Distribution Script
# Adapted version of release-distribute.sh for GitHub Actions CI environment

set -e

# Configuration
APP_NAME="Whispera"
EXPORT_PATH="./build/Release"
DIST_PATH="./dist"

# Get Developer ID from keychain (set up by setup-keychain.sh)
DEVELOPER_ID=$(security find-identity -v -p codesigning "${SIGNING_KEYCHAIN:-whispera-signing.keychain-db}" | grep -E "(Developer ID|3rd Party Mac Developer)" | head -1 | sed -n 's/.*"\(.*\)".*/\1/p')

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

# Sign inside-out: XPC services first, then frameworks, then main app.
# --deep breaks Sparkle 2.x XPC services by stripping their entitlements.
APP_BUNDLE="${DIST_PATH}/${APP_NAME}.app"

if [ -d "$APP_BUNDLE/Contents/XPCServices" ]; then
  echo "⚠️ Found app-level XPCServices (Sparkle 2.x incompatible). Removing..."
  rm -rf "$APP_BUNDLE/Contents/XPCServices"
fi

SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
  for xpc in "$SPARKLE_FRAMEWORK"/Versions/*/XPCServices/*.xpc; do
    [ -e "$xpc" ] || continue
    echo "  Signing Sparkle XPC service: $(basename "$xpc")"
    codesign --force --options runtime \
      --sign "$DEVELOPER_ID" \
      $KEYCHAIN_PARAM \
      "$xpc"
  done

  for helper in "$SPARKLE_FRAMEWORK"/Versions/*/Updater.app "$SPARKLE_FRAMEWORK"/Versions/*/Autoupdate; do
    [ -e "$helper" ] || continue
    echo "  Signing Sparkle helper: $(basename "$helper")"
    codesign --force --options runtime \
      --sign "$DEVELOPER_ID" \
      $KEYCHAIN_PARAM \
      "$helper"
  done
fi

for framework in "$APP_BUNDLE"/Contents/Frameworks/*.framework; do
  [ -e "$framework" ] || continue
  echo "  Signing framework: $(basename "$framework")"
  codesign --force --options runtime \
    --sign "$DEVELOPER_ID" \
    $KEYCHAIN_PARAM \
    "$framework"
done

echo "  Signing main app bundle..."
codesign --force --options runtime \
  --entitlements "${APP_NAME}.entitlements" \
  --sign "$DEVELOPER_ID" \
  $KEYCHAIN_PARAM \
  "$APP_BUNDLE"

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

# Get version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "Info.plist")

# Rename DMG with version
DMG_VERSIONED="${APP_NAME}-${VERSION}.dmg"
if [ -f "${DIST_PATH}/${APP_NAME}.dmg" ]; then
    cp "${DIST_PATH}/${APP_NAME}.dmg" "${DIST_PATH}/${DMG_VERSIONED}"
    echo "📦 Created versioned DMG: ${DMG_VERSIONED}"
fi

# Generate Sparkle signature if private key is available
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    echo "🔐 Generating Sparkle EdDSA signature..."

    # Write private key to temp file, removed on every exit path
    SPARKLE_KEY_FILE=$(mktemp)
    trap 'rm -f "$SPARKLE_KEY_FILE"' EXIT
    echo "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"

    # Find Sparkle sign_update tool
    SIGN_UPDATE=""
    for path in \
        "./build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        "$(find ~/Library/Developer/Xcode/DerivedData -name 'sign_update' -type f 2>/dev/null | head -1)"; do
        if [ -f "$path" ]; then
            SIGN_UPDATE="$path"
            break
        fi
    done

		if [ -n "$SIGN_UPDATE" ]; then
			# Sign the versioned DMG
			SIGNATURE=$("$SIGN_UPDATE" "${DIST_PATH}/${DMG_VERSIONED}" -f "$SPARKLE_KEY_FILE" | tr -d '\r\n')
			# Every Sparkle client rejects an enclosure without an EdDSA signature, so an
			# unsigned appcast must never be written, let alone published
			if ! printf '%s' "$SIGNATURE" | grep -Eq '^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$'; then
				echo "❌ Sparkle sign_update did not produce a signature: '${SIGNATURE}'"
				exit 1
			fi
			echo "✅ Sparkle signature generated"

        # Sparkle must not offer the update to a macOS the app cannot launch on
        MINIMUM_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "${DIST_PATH}/${APP_NAME}.app/Contents/Info.plist")
        if [ -z "$MINIMUM_SYSTEM" ]; then
            echo "❌ LSMinimumSystemVersion missing from the built app"
            exit 1
        fi

        # Get file size
        FILE_SIZE=$(stat -f%z "${DIST_PATH}/${DMG_VERSIONED}")

        # Generate appcast.xml
        DATE=$(date -R)
        DOWNLOAD_URL="https://github.com/sapoepsilon/Whispera/releases/download/v${VERSION}/${DMG_VERSIONED}"

        cat > appcast.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Whispera Updates</title>
    <link>https://github.com/sapoepsilon/Whispera/releases</link>
    <description>Most recent updates to Whispera</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM}</sparkle:minimumSystemVersion>
      <enclosure url="${DOWNLOAD_URL}"
                 ${SIGNATURE}
                 type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
        echo "✅ Appcast generated: appcast.xml"
        cat appcast.xml
    else
        echo "❌ Sparkle sign_update tool not found; the appcast cannot be signed"
        exit 1
    fi

    # Clean up key file
    rm -f "$SPARKLE_KEY_FILE"
    trap - EXIT
else
    echo "⚠️ SPARKLE_PRIVATE_KEY not set, skipping Sparkle signing"
fi

echo ""
echo "🎯 Ready for GitHub release!"
