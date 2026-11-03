#!/bin/bash
# Verify the vendored Sparkle in Packages/Sparkle byte for byte against the official release.
#
# The release workflow hands the Sparkle EdDSA private key to Packages/Sparkle/bin/sign_update, a
# binary committed to this repository. This script downloads the upstream release asset, checks
# its SHA-256 against the pin below, unpacks it and compares every file git tracks under
# Packages/Sparkle with the upstream copy (regular files by content, symlinks by target). It fails
# when the asset hash differs, when a tracked file differs from upstream, or when a tracked file
# does not exist upstream at all.
#
# The one tracked file allowed to have no upstream counterpart is Package.swift: upstream's
# manifest points a binaryTarget at the release zip by URL, ours points it at the unpacked
# xcframework (see Packages/VENDORED.md). It is plain Swift source a reviewer reads in the diff.
# Anything else added here, binary or not, fails, so a new file cannot slip in unreviewed.
# Upstream files that are not vendored (CHANGELOG, bin/generate_appcast, ...) are fine.
#
# Nothing from the download is executed. Needs curl, shasum, ditto and git (macOS).
#
# Usage: scripts/verify-sparkle.sh [repo-path]   (default: the repository holding this script)

set -euo pipefail

SPARKLE_VERSION="2.9.0"
SPARKLE_ASSET="Sparkle-for-Swift-Package-Manager.zip"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${SPARKLE_ASSET}"
SPARKLE_SHA256="44a0d5a00d5bfb6c2ad1755a92b694d948876d61ad44f35a0119eb0e7ace4b65"

# Tracked files with no upstream counterpart, relative to Packages/Sparkle
LOCAL_ONLY=("Package.swift")

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="$(cd "$REPO" && pwd)"
VENDORED="$REPO/Packages/Sparkle"

if [ ! -d "$VENDORED" ]; then
	echo "ERROR: $VENDORED does not exist"
	exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-sparkle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading Sparkle $SPARKLE_VERSION ($SPARKLE_ASSET)"
curl -fsSL --retry 3 -o "$WORK/$SPARKLE_ASSET" "$SPARKLE_URL"

got="$(shasum -a 256 "$WORK/$SPARKLE_ASSET" | awk '{ print $1 }')"
if [ "$got" != "$SPARKLE_SHA256" ]; then
	echo "ERROR: $SPARKLE_ASSET SHA-256 is $got, expected $SPARKLE_SHA256"
	exit 1
fi
echo "Asset SHA-256 matches the pin"

UPSTREAM="$WORK/upstream"
mkdir -p "$UPSTREAM"
ditto -x -k "$WORK/$SPARKLE_ASSET" "$UPSTREAM"

is_local_only() {
	local f
	for f in "${LOCAL_ONLY[@]}"; do [ "$1" = "$f" ] && return 0; done
	return 1
}

tracked="$WORK/tracked"
git -C "$REPO" ls-files -z -- Packages/Sparkle > "$tracked"

problems=0
checked=0
while IFS= read -r -d '' path; do
	rel="${path#Packages/Sparkle/}"
	ours="$REPO/$path"
	theirs="$UPSTREAM/$rel"

	if is_local_only "$rel"; then
		continue
	fi
	checked=$((checked + 1))

	if [ ! -e "$ours" ] && [ ! -L "$ours" ]; then
		echo "MISSING   $rel (tracked but absent from the checkout)"
		problems=$((problems + 1))
	elif [ ! -e "$theirs" ] && [ ! -L "$theirs" ]; then
		echo "ADDED     $rel (not in the upstream release)"
		problems=$((problems + 1))
	elif [ -L "$ours" ] || [ -L "$theirs" ]; then
		if ! { [ -L "$ours" ] && [ -L "$theirs" ] && [ "$(readlink "$ours")" = "$(readlink "$theirs")" ]; }; then
			echo "MODIFIED  $rel (symlink differs)"
			problems=$((problems + 1))
		fi
	elif ! cmp -s "$ours" "$theirs"; then
		echo "MODIFIED  $rel"
		problems=$((problems + 1))
	fi
done < "$tracked"

# The signing step runs this exact path, so it must be one of the verified files
if ! grep -qzx "Packages/Sparkle/bin/sign_update" "$tracked"; then
	echo "MISSING   bin/sign_update is not tracked"
	problems=$((problems + 1))
fi

# Untracked files on disk (a stray binary dropped next to sign_update) would not show up above
untracked="$(git -C "$REPO" ls-files --others --exclude-standard -- Packages/Sparkle)"
if [ -n "$untracked" ]; then
	while IFS= read -r path; do
		echo "UNTRACKED ${path#Packages/Sparkle/}"
		problems=$((problems + 1))
	done <<< "$untracked"
fi

if [ "$problems" -ne 0 ]; then
	echo "$problems problem(s): Packages/Sparkle does not match Sparkle $SPARKLE_VERSION"
	exit 1
fi
echo "OK: all $checked tracked Sparkle files match Sparkle $SPARKLE_VERSION byte for byte (local-only: ${LOCAL_ONLY[*]})"
