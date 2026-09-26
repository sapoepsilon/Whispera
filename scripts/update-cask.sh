#!/bin/bash
# Point Casks/whispera.rb at a published GitHub release.
# Usage: ./scripts/update-cask.sh 1.3.3
set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
REPO="sapoepsilon/Whispera"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="$ROOT/Casks/whispera.rb"
URL="https://github.com/$REPO/releases/download/v$VERSION/Whispera-$VERSION.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fsSL -o "$TMP/Whispera.dmg" "$URL"
SHA="$(shasum -a 256 "$TMP/Whispera.dmg" | awk '{print $1}')"

sed -i '' -E \
	-e "s/^  version \".*\"/  version \"$VERSION\"/" \
	-e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
	"$CASK"

echo "Updated $CASK to $VERSION ($SHA)"
if command -v brew >/dev/null; then
	brew style "$CASK"
fi
