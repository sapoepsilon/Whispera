#!/bin/bash
# Creates an isolated worktree + branch for a QA run so the main checkout's
# branch is never touched. Worktrees live outside the repo so Xcode and SPM
# never index them from the main checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WT_BASE="${WHISPERA_WT_BASE:-$HOME/Developer/whispera-worktrees}"

usage() {
  echo "usage: $(basename "$0") <slug> | --rm <slug> | --list" >&2
  exit 1
}

case "${1:-}" in
  --list)
    git -C "$ROOT" worktree list
    exit 0
    ;;
  --rm)
    [ -n "${2:-}" ] || usage
    git -C "$ROOT" worktree remove --force "$WT_BASE/$2"
    git -C "$ROOT" worktree prune
    exit 0
    ;;
  "" | -*)
    usage
    ;;
esac

SLUG="$1"
BRANCH="${QA_BRANCH:-sapoepsilon/autoship-$SLUG}"
WT="$WT_BASE/$SLUG"

if [ -d "$WT" ]; then
  echo "$WT"
  exit 0
fi

git -C "$ROOT" fetch origin main
mkdir -p "$WT_BASE"
if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$ROOT" worktree add "$WT" "$BRANCH"
else
  git -C "$ROOT" worktree add -b "$BRANCH" "$WT" origin/main
fi
echo "$WT"
