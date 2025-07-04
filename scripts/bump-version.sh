#!/bin/bash

# Whispera Version Bumping Script
# Updates version numbers in Xcode project files

set -e

VERSION="$1"
PROJECT_FILE="Whispera.xcodeproj/project.pbxproj"

if [ -z "$VERSION" ]; then
    echo "❌ Error: Version number required"
    echo "Usage: $0 <version>"
    echo "Example: $0 1.0.3"
    exit 1
fi

# Validate version format (basic semantic versioning)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Error: Invalid version format. Use semantic versioning (e.g., 1.0.3)"
    exit 1
fi

echo "🔢 Bumping version to $VERSION..."

# Check if project file exists
if [ ! -f "$PROJECT_FILE" ]; then
    echo "❌ Error: Project file not found: $PROJECT_FILE"
    exit 1
fi

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD_NUMBER=$(date +%Y%m%d%H%M)

echo "📋 Version components:"
echo "  MARKETING_VERSION: $VERSION"
echo "  CURRENT_PROJECT_VERSION: $BUILD_NUMBER"

# Create backup
cp "$PROJECT_FILE" "$PROJECT_FILE.backup"

# Update MARKETING_VERSION (version visible to users)
sed -i '' "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $VERSION/g" "$PROJECT_FILE"

# Update CURRENT_PROJECT_VERSION (build number)
sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/g" "$PROJECT_FILE"

# Verify changes
echo "🔍 Verifying changes..."
MARKETING_COUNT=$(grep -c "MARKETING_VERSION = $VERSION" "$PROJECT_FILE")
BUILD_COUNT=$(grep -c "CURRENT_PROJECT_VERSION = $BUILD_NUMBER" "$PROJECT_FILE")

echo "  MARKETING_VERSION entries updated: $MARKETING_COUNT"
echo "  CURRENT_PROJECT_VERSION entries updated: $BUILD_COUNT"

if [ "$MARKETING_COUNT" -eq 0 ] || [ "$BUILD_COUNT" -eq 0 ]; then
    echo "❌ Error: Version update failed"
    echo "Restoring backup..."
    mv "$PROJECT_FILE.backup" "$PROJECT_FILE"
    exit 1
fi

# Update Info.plist if it has hardcoded versions
if [ -f "Info.plist" ]; then
    echo "📝 Checking Info.plist..."
    if grep -q "CFBundleShortVersionString.*[0-9]" Info.plist; then
        echo "⚠️ Info.plist contains hardcoded version - consider using build settings variables"
    fi
fi

# Clean up backup
rm "$PROJECT_FILE.backup"

echo "✅ Version successfully updated to $VERSION (build $BUILD_NUMBER)"

# Show git diff for verification
echo "📄 Changes made:"
git diff --no-index /dev/null "$PROJECT_FILE" | grep "^\+" | grep -E "(MARKETING_VERSION|CURRENT_PROJECT_VERSION)" || true

# Optional: Commit the version bump
if [ "${2:-}" == "--commit" ]; then
    echo "📝 Committing version bump..."
    git add "$PROJECT_FILE"
    git commit -m "bump: version $VERSION (build $BUILD_NUMBER)"
    echo "✅ Version bump committed"
fi