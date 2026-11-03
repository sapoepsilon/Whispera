#!/bin/bash
# Verify the vendored Swift packages under Packages/ against their upstreams.
#
# For every package in Packages/vendored-sources.txt this fetches the upstream at the recorded
# commit (or downloads the recorded release asset and checks its SHA-256), then compares it with
# Packages/<dir> file by file. It prints only what a reviewer has to look at:
#
#   MODIFIED   a file present in both whose bytes (or symlink target) differ
#   ADDED      a file in Packages/<dir> that upstream does not have
#   MISSING    an upstream file absent from Packages/<dir> that no `rm` line documents
#   STALE-RM   an `rm` line that matches nothing upstream
#   LOCAL      a file a `local` line documents as changed or added here (not a problem)
#   STALE-LOCAL a `local` line naming a file that is identical to upstream or missing
#
# Package.swift and Package@swift-*.swift at a package root are expected to differ (local path
# dependencies, trimmed targets) and are listed separately; pass --manifests to print their diffs.
#
# Needs network access, git, curl and ditto. The sapoepsilon repositories are private, so the
# git credentials in use must be able to read them. --from <dir>=<path-or-url> fetches one package
# from somewhere else (a local clone, a mirror) instead; the commit hash is still checked.
#
# Usage: scripts/verify-vendored.sh [--manifests] [--keep] [--from dir=src ...] [package-dir ...]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES="$ROOT/Packages"
CONF="$PACKAGES/vendored-sources.txt"

show_manifests=0
keep=0
only=()
overrides=()
while [ $# -gt 0 ]; do
	case "$1" in
		--manifests) show_manifests=1 ;;
		--keep) keep=1 ;;
		--from)
			[ $# -ge 2 ] || { echo "--from needs dir=source" >&2; exit 2; }
			overrides+=("$2")
			shift
			;;
		--from=*) overrides+=("${1#--from=}") ;;
		-h | --help)
			sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) only+=("$1") ;;
	esac
	shift
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-vendored.XXXXXX")"
if [ "$keep" -eq 0 ]; then
	trap 'rm -rf "$WORK"' EXIT
else
	echo "Keeping upstream checkouts in $WORK"
fi

source_for() {
	local o
	if [ "${#overrides[@]}" -gt 0 ]; then
		for o in "${overrides[@]}"; do
			if [ "${o%%=*}" = "$1" ]; then
				echo "${o#*=}"
				return
			fi
		done
	fi
	echo "$2"
}

wanted() {
	[ "${#only[@]}" -eq 0 ] && return 0
	local o
	for o in "${only[@]}"; do [ "$o" = "$1" ] && return 0; done
	return 1
}

# Regular files and symlinks, relative, sorted. find does not follow symlinked directories, so a
# framework's Versions/Current link is compared as a link rather than walked twice.
list_files() {
	# .build and .swiftpm are what SwiftPM and Xcode leave in a package they open; git ignores them.
	(cd "$1" && find . \( -type f -o -type l \) -not -path './.git/*' -not -path './.build/*' \
		-not -path './.swiftpm/*' | sed 's|^\./||' | LC_ALL=C sort)
}

is_manifest() {
	case "$1" in
		Package.swift | Package@swift-*.swift) return 0 ;;
	esac
	return 1
}

# rm patterns for one package, one per line
removals_for() {
	awk -v d="$1" '$1 == "rm" && $2 == d { print $3 }' "$CONF"
}

# Files changed or added in place for this repository, one per line (exact paths).
locals_for() {
	awk -v d="$1" '$1 == "local" && $2 == d { print $3 }' "$CONF"
}

is_local() {
	local file="$1" path
	while IFS= read -r path; do
		[ -n "$path" ] && [ "$file" = "$path" ] && return 0
	done <<< "$2"
	return 1
}

documented() {
	local file="$1" pattern
	while IFS= read -r pattern; do
		[ -z "$pattern" ] && continue
		# shellcheck disable=SC2053 # the pattern is a glob on purpose
		if [[ "$file" == $pattern || "$file" == $pattern/* ]]; then
			return 0
		fi
	done <<< "$2"
	return 1
}

fetch_git() {
	local url="$1" commit="$2" dest="$3"
	if [ -d "$url" ]; then
		git clone -q --no-checkout "$url" "$dest"
		git -C "$dest" -c advice.detachedHead=false checkout -q "$commit" 2>/dev/null || {
			echo "  ERROR: $url does not contain $commit"
			return 1
		}
	else
		git init -q "$dest"
		git -C "$dest" remote add origin "$url"
		git -C "$dest" fetch -q --depth 1 origin "$commit" 2>/dev/null || {
			echo "  ERROR: $url does not serve $commit (not pushed, or no read access)"
			return 1
		}
		git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD
	fi
	local head
	head="$(git -C "$dest" rev-parse HEAD)"
	if [ "$head" != "$commit" ]; then
		echo "  ERROR: fetched $head, expected $commit"
		return 1
	fi
}

fetch_zip() {
	local url="$1" sha="$2" dest="$3"
	local zip="$WORK/$(basename "$dest").zip"
	curl -fsSL -o "$zip" "$url"
	local got
	got="$(shasum -a 256 "$zip" | awk '{ print $1 }')"
	if [ "$got" != "$sha" ]; then
		echo "  ERROR: asset SHA-256 is $got, expected $sha"
		return 1
	fi
	mkdir -p "$dest"
	ditto -x -k "$zip" "$dest"
}

same_entry() {
	local a="$1" b="$2"
	if [ -L "$a" ] || [ -L "$b" ]; then
		[ -L "$a" ] && [ -L "$b" ] && [ "$(readlink "$a")" = "$(readlink "$b")" ]
	else
		cmp -s "$a" "$b"
	fi
}

problems=0
checked=0

while read -r kind dir source pin; do
	case "$kind" in git | zip) ;; *) continue ;; esac
	wanted "$dir" || continue
	checked=$((checked + 1))

	vendored="$PACKAGES/$dir"
	upstream="$WORK/$dir"
	echo "== $dir ($kind ${pin:0:12})"

	if [ ! -d "$vendored" ]; then
		echo "  ERROR: $vendored does not exist"
		problems=$((problems + 1))
		continue
	fi
	source="$(source_for "$dir" "$source")"
	if [ "$kind" = git ]; then
		fetch_git "$source" "$pin" "$upstream" || { problems=$((problems + 1)); continue; }
	else
		fetch_zip "$source" "$pin" "$upstream" || { problems=$((problems + 1)); continue; }
	fi

	removals="$(removals_for "$dir")"
	locals="$(locals_for "$dir")"
	local_seen=()
	list_files "$upstream" > "$WORK/$dir.up"
	list_files "$vendored" > "$WORK/$dir.vendored"

	manifests=()
	while IFS= read -r f; do
		if is_manifest "$f"; then
			manifests+=("$f (new)")
			continue
		fi
		if is_local "$f" "$locals"; then
			echo "  LOCAL     $f (added)"
			local_seen+=("$f")
			continue
		fi
		echo "  ADDED     $f"
		problems=$((problems + 1))
	done < <(LC_ALL=C comm -13 "$WORK/$dir.up" "$WORK/$dir.vendored")

	removed=0
	while IFS= read -r f; do
		if documented "$f" "$removals"; then
			removed=$((removed + 1))
		elif is_manifest "$f"; then
			manifests+=("$f (deleted)")
		else
			echo "  MISSING   $f"
			problems=$((problems + 1))
		fi
	done < <(LC_ALL=C comm -23 "$WORK/$dir.up" "$WORK/$dir.vendored")

	while IFS= read -r f; do
		if same_entry "$upstream/$f" "$vendored/$f"; then
			continue
		fi
		if is_manifest "$f"; then
			manifests+=("$f")
		elif is_local "$f" "$locals"; then
			echo "  LOCAL     $f (modified)"
			local_seen+=("$f")
		else
			echo "  MODIFIED  $f"
			problems=$((problems + 1))
		fi
	done < <(LC_ALL=C comm -12 "$WORK/$dir.up" "$WORK/$dir.vendored")

	while IFS= read -r pattern; do
		[ -z "$pattern" ] && continue
		matched=0
		while IFS= read -r f; do
			# shellcheck disable=SC2053
			if [[ "$f" == $pattern || "$f" == $pattern/* ]]; then
				matched=1
				break
			fi
		done < "$WORK/$dir.up"
		if [ "$matched" -eq 0 ]; then
			echo "  STALE-RM  $pattern"
			problems=$((problems + 1))
		fi
	done <<< "$removals"

	while IFS= read -r path; do
		[ -z "$path" ] && continue
		found=0
		if [ "${#local_seen[@]}" -gt 0 ]; then
			for f in "${local_seen[@]}"; do [ "$f" = "$path" ] && found=1; done
		fi
		if [ "$found" -eq 0 ]; then
			echo "  STALE-LOCAL $path"
			problems=$((problems + 1))
		fi
	done <<< "$locals"

	kept="$(wc -l < "$WORK/$dir.vendored" | tr -d ' ')"
	echo "  ok: $kept files kept, $removed removed as documented, ${#manifests[@]} manifest change(s)"
	if [ "${#manifests[@]}" -gt 0 ]; then
		for m in "${manifests[@]}"; do
			echo "    manifest  $m"
			if [ "$show_manifests" -eq 1 ]; then
				name="${m%% (*}"
				diff -u "$upstream/$name" "$vendored/$name" 2>/dev/null | sed 's/^/      /' || true
			fi
		done
	fi
done < "$CONF"

if [ "$checked" -eq 0 ]; then
	echo "No package matched the given names"
	exit 2
fi

echo
if [ "$problems" -eq 0 ]; then
	echo "All $checked vendored packages match upstream apart from the documented removals, manifests and local files."
else
	echo "$problems problem(s) found across $checked package(s)."
	exit 1
fi
