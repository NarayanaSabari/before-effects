#!/bin/bash
set -euo pipefail

# Pull updates from upstream (palmier-io/palmier-pro) into the current branch.
#
# Usage:
#   scripts/sync-upstream.sh            # preview, merge upstream/main into current branch, then build
#   scripts/sync-upstream.sh --check    # preview only — show incoming commits, make no changes
#   scripts/sync-upstream.sh --no-build # merge only, skip the build
#
# See FORK.md for the branching model.

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
DO_MERGE=1
DO_BUILD=1

for arg in "$@"; do
  case "$arg" in
    --check)    DO_MERGE=0; DO_BUILD=0 ;;
    --no-build) DO_BUILD=0 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "!! no '$UPSTREAM_REMOTE' remote. Add it with:" >&2
  echo "   git remote add upstream https://github.com/palmier-io/palmier-pro.git" >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> Fetching $UPSTREAM_REMOTE"
git fetch "$UPSTREAM_REMOTE" --tags

REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
AHEAD="$(git rev-list --count "HEAD..$REF")"

if [ "$AHEAD" -eq 0 ]; then
  echo "==> Already up to date with $REF."
  exit 0
fi

echo ""
echo "==> $AHEAD new commit(s) on $REF not in '$CURRENT_BRANCH':"
git log --oneline --no-decorate "HEAD..$REF"
echo ""

if [ "$DO_MERGE" -eq 0 ]; then
  echo "==> --check: no changes made. Run without --check to merge."
  exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "!! working tree is dirty — commit or stash before merging." >&2
  exit 1
fi

echo "==> Merging $REF into '$CURRENT_BRANCH'"
if ! git merge --no-edit "$REF"; then
  echo "" >&2
  echo "!! merge has conflicts. Resolve them, then:" >&2
  echo "   git add -A && git commit        # rerere will remember your resolutions" >&2
  echo "   git merge --abort               # to bail out instead" >&2
  exit 1
fi

if [ "$DO_BUILD" -eq 1 ]; then
  echo "==> Building to verify the merge"
  swift build
  echo "==> Build OK. Consider: swift test"
fi

echo "==> Done. Push when ready: git push origin $CURRENT_BRANCH"
