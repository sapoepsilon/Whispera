#!/bin/bash
# Writes appcast.xml for the DMG release-distribute-ci.sh produced, with the EdDSA signature
# release.yml made using the verified sign_update. Takes the signature from SPARKLE_SIGNATURE
# (`sparkle:edSignature="…" length="…"`); never sees the private key.

set -euo pipefail

APP_NAME="Whispera"
DIST_PATH="./dist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "Info.plist")
DMG_VERSIONED="${APP_NAME}-${VERSION}.dmg"
SIGNATURE="${SPARKLE_SIGNATURE:-}"

# Every Sparkle client rejects an enclosure without an EdDSA signature, so an unsigned appcast
# must never be written, let alone published
if ! printf '%s' "$SIGNATURE" | grep -Eq '^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$'; then
    echo "error: SPARKLE_SIGNATURE is not a sign_update signature"
    exit 1
fi
if [ ! -f "${DIST_PATH}/${DMG_VERSIONED}" ]; then
    echo "error: ${DIST_PATH}/${DMG_VERSIONED} is missing"
    exit 1
fi

# Sparkle must not offer the update to a macOS the app cannot launch on
MINIMUM_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "${DIST_PATH}/${APP_NAME}.app/Contents/Info.plist")
if [ -z "$MINIMUM_SYSTEM" ]; then
    echo "error: LSMinimumSystemVersion missing from the built app"
    exit 1
fi

DATE=$(date -R)
DOWNLOAD_URL="https://github.com/sapoepsilon/Whispera/releases/download/v${VERSION}/${DMG_VERSIONED}"

cat > appcast.xml << APPCAST
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
APPCAST
echo "Appcast generated: appcast.xml"
cat appcast.xml
