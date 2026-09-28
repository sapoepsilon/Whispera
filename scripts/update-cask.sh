#!/bin/bash
# Point Casks/whispera.rb at a published GitHub release.
# Usage: ./scripts/update-cask.sh <version> [local-dmg]
#   With a local DMG (the release workflow passes dist/Whispera-<version>.dmg) the
#   hash is taken from that file, so the cask can be bumped in the same job that
#   uploads the release. Without one, the published release asset is downloaded.
#   CASK_SKIP_STYLE=1 skips `brew style` (CI runners would have to install RuboCop).
set -euo pipefail

VERSION="${1:?usage: $0 <version> [local-dmg]}"
LOCAL_DMG="${2:-}"
REPO="sapoepsilon/Whispera"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="${CASK_PATH:-$ROOT/Casks/whispera.rb}"
URL="https://github.com/$REPO/releases/download/v$VERSION/Whispera-$VERSION.dmg"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Invalid version '$VERSION' (expected MAJOR.MINOR.PATCH)" >&2
	exit 1
fi

if [ -n "$LOCAL_DMG" ]; then
	[ -f "$LOCAL_DMG" ] || { echo "DMG not found: $LOCAL_DMG" >&2; exit 1; }
	DMG="$LOCAL_DMG"
else
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	echo "Downloading $URL"
	curl -fsSL -o "$TMP/Whispera.dmg" "$URL"
	DMG="$TMP/Whispera.dmg"
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

sed -i '' -E \
	-e "s/^  version \".*\"/  version \"$VERSION\"/" \
	-e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
	"$CASK"

grep -q "^  version \"$VERSION\"$" "$CASK" || { echo "Failed to write version into $CASK" >&2; exit 1; }
grep -q "^  sha256 \"$SHA\"$" "$CASK" || { echo "Failed to write sha256 into $CASK" >&2; exit 1; }

echo "Updated $CASK to $VERSION ($SHA)"
if [ "${CASK_SKIP_STYLE:-0}" != 1 ] && command -v brew >/dev/null; then
	brew style "$CASK"
fi
