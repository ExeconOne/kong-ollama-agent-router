#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/release.sh [patch|minor|major|X.Y.Z]

Default is patch.

The script:
  1. requires a clean git working tree,
  2. bumps VERSION, handler.lua, rockspec, README, and CHANGELOG,
  3. runs lint/tests/build,
  4. commits "Release vX.Y.Z",
  5. creates tag vX.Y.Z,
  6. pushes the current branch and tags to origin.

Set RELEASE_BRANCH=main to force pushing a specific branch name.
EOF
  exit 2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

next_version() {
  local bump="$1"
  local current="$2"
  local major minor patch

  IFS=. read -r major minor patch <<< "$current"

  case "$bump" in
    patch)
      patch=$((patch + 1))
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    *)
      [[ "$bump" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
      printf '%s\n' "$bump"
      return
      ;;
  esac

  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

need_cmd git
need_cmd lua
need_cmd luarocks

BUMP="${1:-patch}"
[[ $# -le 1 ]] || usage

CURRENT_VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must be SemVer X.Y.Z, got: $CURRENT_VERSION"

if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "Working tree must be clean before release"
fi

BRANCH="${RELEASE_BRANCH:-$(git branch --show-current)}"
[[ -n "$BRANCH" ]] || fail "Cannot determine current branch. Set RELEASE_BRANCH=main."

git fetch --tags origin

NEW_VERSION="$(next_version "$BUMP" "$CURRENT_VERSION")"
TAG="v$NEW_VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "Tag already exists locally: $TAG"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  fail "Tag already exists on origin: $TAG"
fi

./scripts/bump-version.sh "$NEW_VERSION"
make lint
make test
make build-rock

git add .
git commit -m "Release $TAG"
git tag "$TAG"
git push origin "$BRANCH" --tags

printf 'Released %s on %s\n' "$TAG" "$BRANCH"
