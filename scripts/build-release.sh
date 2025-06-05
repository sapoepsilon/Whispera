#!/bin/bash

# Whispera Release Build Script
# This script builds the app and creates a clean distribution ZIP without user path references

set -e  # Exit on any error

# Configuration
APP_NAME="Whispera"
SCHEME_NAME="Whispera"
BUILD_CONFIGURATION="Release"
ARCHIVE_PATH="./build/Release/${APP_NAME}.xcarchive"
EXPORT_PATH="./build/Release"
DIST_PATH="./dist"

# Check for signing configuration
SIGNING_MODE="automatic"
if [ -n "$DEVELOPER_ID_APPLICATION" ]; then
    SIGNING_MODE="manual"
    echo "🔐 Using manual code signing with identity: $DEVELOPER_ID_APPLICATION"
else
    echo "🔐 Using automatic code signing (development team required)"
fi

echo "🚀 Building ${APP_NAME} for distribution..."

# Clean previous builds
echo "🧹 Cleaning previous builds..."
rm -rf build/Release
rm -rf dist
mkdir -p dist

# Build the app using xcodebuild
echo "🔨 Building ${APP_NAME}..."
if [ "$SIGNING_MODE" = "manual" ]; then
    # Manual signing for distribution
    xcodebuild -project "${APP_NAME}.xcodeproj" \
               -scheme "${SCHEME_NAME}" \
               -configuration "${BUILD_CONFIGURATION}" \
               -archivePath "${ARCHIVE_PATH}" \
               -destination "generic/platform=macOS" \
               CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
               CODE_SIGN_STYLE=Manual \
               PROVISIONING_PROFILE_SPECIFIER="" \
               archive
else
    # Automatic signing for development/testing
    xcodebuild -project "${APP_NAME}.xcodeproj" \
               -scheme "${SCHEME_NAME}" \
               -configuration "${BUILD_CONFIGURATION}" \
               -archivePath "${ARCHIVE_PATH}" \
               -destination "generic/platform=macOS" \
               CODE_SIGN_STYLE=Automatic \
               archive
fi

# Export the app
echo "📦 Exporting ${APP_NAME}..."
if [ "$SIGNING_MODE" = "manual" ]; then
    EXPORT_OPTIONS="scripts/ExportOptions.plist"
else
    EXPORT_OPTIONS="scripts/ExportOptions-dev.plist"
fi

xcodebuild -exportArchive \
           -archivePath "${ARCHIVE_PATH}" \
           -exportPath "${EXPORT_PATH}" \
           -exportOptionsPlist "${EXPORT_OPTIONS}"

# Create clean distribution
echo "📁 Creating clean distribution..."
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
    echo "❌ Error: App not found at ${APP_PATH}"
    exit 1
fi

# Copy app to dist directory with clean structure
cp -R "${APP_PATH}" "${DIST_PATH}/"

# Verify code signing
echo "🔍 Verifying code signature..."
codesign -vvv --deep --strict "${DIST_PATH}/${APP_NAME}.app"
if [ $? -eq 0 ]; then
    echo "✅ Code signature is valid"
    
    # Show signing information
    echo "📋 Code signing details:"
    codesign -dv "${DIST_PATH}/${APP_NAME}.app" 2>&1 | grep -E "(Authority|TeamIdentifier|Identifier)"
else
    echo "⚠️ Code signature verification failed - app may show security warnings"
fi

# Check if notarization is possible
if [ "$SIGNING_MODE" = "manual" ] && [ -n "$APPLE_ID" ] && [ -n "$APP_SPECIFIC_PASSWORD" ]; then
    echo "📤 Submitting for notarization..."
    
    # Create a ZIP for notarization
    cd "${DIST_PATH}"
    zip -r "${APP_NAME}-notarize.zip" "${APP_NAME}.app"
    
    # Submit for notarization
    xcrun notarytool submit "${APP_NAME}-notarize.zip" \
        --apple-id "$APPLE_ID" \
        --password "$APP_SPECIFIC_PASSWORD" \
        --team-id "NK28QT38A3" \
        --wait
    
    if [ $? -eq 0 ]; then
        echo "✅ Notarization successful"
        # Staple the notarization
        xcrun stapler staple "${APP_NAME}.app"
        rm "${APP_NAME}-notarize.zip"
    else
        echo "⚠️ Notarization failed - app may show security warnings"
        rm "${APP_NAME}-notarize.zip"
    fi
    cd ..
else
    echo "ℹ️ Skipping notarization (requires APPLE_ID, APP_SPECIFIC_PASSWORD, and manual signing)"
fi

# Create ZIP with clean paths (no user references)
echo "🗜️ Creating distribution ZIP..."
cd dist
zip -r "${APP_NAME}-v$(date +%Y%m%d).zip" "${APP_NAME}.app"
cd ..

echo "✅ Distribution created successfully!"
echo "📦 ZIP file: dist/${APP_NAME}-v$(date +%Y%m%d).zip"
echo ""
echo "Next steps:"
echo "1. Test the app: open dist/${APP_NAME}.app"
echo "2. Upload to GitHub releases"
if [ "$SIGNING_MODE" = "automatic" ]; then
    echo ""
    echo "🔐 For production distribution without security warnings:"
    echo "1. Get an Apple Developer account"
    echo "2. Create a Developer ID Application certificate"
    echo "3. Set DEVELOPER_ID_APPLICATION environment variable"
    echo "4. Set APPLE_ID and APP_SPECIFIC_PASSWORD for notarization"
fi