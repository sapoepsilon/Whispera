#!/bin/bash

# Whispera Version Bumping Script
# Updates version numbers in Xcode project files

set -e

VERSION="$1"
PROJECT_FILE="Whispera.xcodeproj/project.pbxproj"
INFO_PLIST="Info.plist"

if [ -z "$VERSION" ]; then
    echo "❌ Error: Version number required"
    echo "Usage: $0 <version>"
    echo "Example: $0 1.0.3"
    exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Error: Invalid version format. Use semantic versioning (e.g., 1.0.3)"
    exit 1
fi

if [ ! -f "$PROJECT_FILE" ]; then
    echo "❌ Error: Project file not found: $PROJECT_FILE"
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "❌ Error: Info.plist not found: $INFO_PLIST"
    exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"

CURRENT_BUILD=$(grep -A1 "CFBundleVersion" "$INFO_PLIST" | grep "<string>" | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t' | tr -d ' ')
if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER=$((CURRENT_BUILD + 1))
else
    echo "⚠️ Could not parse current build number, using patch version as build number"
    BUILD_NUMBER="$PATCH"
fi

echo "📋 Version components:"
echo "  MARKETING_VERSION: $VERSION"
echo "  BUILD_NUMBER: $BUILD_NUMBER"

cp "$PROJECT_FILE" "$PROJECT_FILE.backup"
cp "$INFO_PLIST" "$INFO_PLIST.backup"

sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/g" "$PROJECT_FILE"
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/g" "$PROJECT_FILE"
sed -i '' -e "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>.*<\/string>/<string>$VERSION<\/string>/;}" "$INFO_PLIST"
sed -i '' -e "/<key>CFBundleVersion<\/key>/{n;s/<string>.*<\/string>/<string>$BUILD_NUMBER<\/string>/;}" "$INFO_PLIST"
echo "🔍 Verifying changes..."
MARKETING_COUNT=$(grep -c "MARKETING_VERSION = $VERSION" "$PROJECT_FILE")
BUILD_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = $BUILD_NUMBER" "$PROJECT_FILE")

INFO_VERSION=$(grep -A1 "CFBundleShortVersionString" "$INFO_PLIST" | grep "<string>" | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t' | tr -d ' ')
INFO_BUILD=$(grep -A1 "CFBundleVersion" "$INFO_PLIST" | grep "<string>" | sed 's/.*<string>\(.*\)<\/string>/\1/' | tr -d '\t' | tr -d ' ')

echo "  project.pbxproj: MARKETING_VERSION entries updated: $MARKETING_COUNT"
echo "  project.pbxproj: CURRENT_PROJECT_VERSION entries updated: $BUILD_COUNT"
echo "  Info.plist: CFBundleShortVersionString = $INFO_VERSION"
echo "  Info.plist: CFBundleVersion = $INFO_BUILD"

if [ "$MARKETING_COUNT" -eq 0 ] || [ "$BUILD_COUNT" -eq 0 ] || [ "$INFO_VERSION" != "$VERSION" ] || [ "$INFO_BUILD" != "$BUILD_NUMBER" ]; then
    echo "❌ Error: Version update failed"
    echo "Restoring backups..."
    mv "$PROJECT_FILE.backup" "$PROJECT_FILE"
    mv "$INFO_PLIST.backup" "$INFO_PLIST"
    exit 1
fi

rm "$PROJECT_FILE.backup"
rm "$INFO_PLIST.backup"

echo "✅ Version successfully updated to $VERSION (build $BUILD_NUMBER)"

echo "📄 Changes made:"
echo "project.pbxproj:"
git diff "$PROJECT_FILE" | grep -E "(MARKETING_VERSION|CURRENT_PROJECT_VERSION)" || true
echo ""
echo "Info.plist:"
git diff "$INFO_PLIST" | grep -E "(CFBundleShortVersionString|CFBundleVersion)" -A1 -B1 || true

if [ "${2:-}" == "--commit" ]; then
    echo "📝 Committing version bump..."
    git add "$PROJECT_FILE" "$INFO_PLIST"
    git commit -m "bump: version $VERSION (build $BUILD_NUMBER)"
    echo "✅ Version bump committed"
fi
