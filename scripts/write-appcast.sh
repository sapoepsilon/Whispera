#!/bin/bash
# Writes appcast.xml for the release DMG. Every value comes from the environment, set by
# release.yml from the outputs of the job that built the app and the job that signed the DMG:
#   VERSION            CFBundleShortVersionString of the built app (MAJOR.MINOR.PATCH)
#   BUILD              CFBundleVersion of the built app
#   MINIMUM_SYSTEM     LSMinimumSystemVersion of the built app
#   SPARKLE_SIGNATURE  sign_update output (`sparkle:edSignature="…" length="…"`)
# Never sees the private key, and reads nothing from the checkout: the checked-out Info.plist
# still has the previous build number, which the build job bumped only on its own runner.

set -euo pipefail

APP_NAME="Whispera"
VERSION="${VERSION:-}"
BUILD="${BUILD:-}"
MINIMUM_SYSTEM="${MINIMUM_SYSTEM:-}"
SIGNATURE="${SPARKLE_SIGNATURE:-}"
DMG_VERSIONED="${APP_NAME}-${VERSION}.dmg"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION is not MAJOR.MINOR.PATCH"
    exit 1
fi
if ! [[ "$BUILD" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: BUILD is not a CFBundleVersion"
    exit 1
fi
# Sparkle must not offer the update to a macOS the app cannot launch on
if ! [[ "$MINIMUM_SYSTEM" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: MINIMUM_SYSTEM is not the built app's LSMinimumSystemVersion"
    exit 1
fi

# Every Sparkle client rejects an enclosure without an EdDSA signature, so an unsigned appcast
# must never be written, let alone published
if ! printf '%s' "$SIGNATURE" | grep -Eq '^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$'; then
    echo "error: SPARKLE_SIGNATURE is not a sign_update signature"
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
