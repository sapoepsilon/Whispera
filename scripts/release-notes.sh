#!/bin/bash
# Write the GitHub release body, which the app also shows in What's New.
# Usage: ./scripts/release-notes.sh <version> [output-file]
#   release-notes/v<version>.md, when present, is used as the "What's New" section as is.
#   Otherwise the section is built from the feat, fix and perf commit subjects since the
#   previous tag, without merges, scopes or conventional-commit prefixes, skipping
#   developer-only scopes (ci, qa, scripts, release, build, deps, test).
set -euo pipefail

VERSION="${1:?usage: $0 <version> [output-file]}"
OUT="${2:-release_notes.md}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CURATED="$ROOT/release-notes/v$VERSION.md"

section() {
	local type="$1" title="$2" range="$3" lines
	lines=$(git -C "$ROOT" log $range --no-merges --pretty=format:'%s' |
		grep -E "^$type(\([^)]*\))?!?: " |
		grep -vE "^$type\((ci|qa|scripts|release|build|deps|tests?)\)" |
		sed -E "s/^$type(\([^)]*\))?!?: +//" |
		awk '{ print "- " toupper(substr($0, 1, 1)) substr($0, 2) }' |
		sort -u || true)
	if [ -n "$lines" ]; then
		printf '### %s\n\n%s\n' "$title" "$lines"
	fi
}

{
	echo "## What's New"
	echo
	if [ -f "$CURATED" ]; then
		cat "$CURATED"
		echo
	else
		LAST_TAG=$(git -C "$ROOT" describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null ||
			git -C "$ROOT" describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")
		RANGE="${LAST_TAG:+$LAST_TAG..}HEAD"
		[ -n "$LAST_TAG" ] || RANGE="-20 HEAD"
		BODY=""
		for spec in "feat:Features" "fix:Fixes" "perf:Performance"; do
			PART="$(section "${spec%%:*}" "${spec#*:}" "$RANGE")"
			[ -n "$PART" ] && BODY="${BODY:+$BODY$'\n\n'}$PART"
		done
		if [ -n "$BODY" ]; then
			printf '%s\n\n' "$BODY"
		else
			echo "Maintenance and stability improvements."
			echo
		fi
	fi
	cat <<'EOF'
## Download

Download `Whispera.dmg` below and drag Whispera to your Applications folder, or install it with Homebrew:

```bash
brew tap sapoepsilon/whispera https://github.com/sapoepsilon/Whispera
brew install --cask sapoepsilon/whispera/whispera
```

Existing installs update themselves through Sparkle.

## System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac
- Microphone and Accessibility permissions
EOF
} >"$OUT"

echo "Wrote $OUT"
