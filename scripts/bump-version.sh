#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s X.Y.Z\n' "$0" >&2
  exit 2
fi

NEW_VERSION="$1"
if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'ERROR: version must be SemVer X.Y.Z, got: %s\n' "$NEW_VERSION" >&2
  exit 2
fi

OLD_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
OLD_ROCKSPEC="$ROOT_DIR/kong-plugin-ollama-agent-router-$OLD_VERSION-1.rockspec"
NEW_ROCKSPEC="$ROOT_DIR/kong-plugin-ollama-agent-router-$NEW_VERSION-1.rockspec"

if [[ ! -f "$OLD_ROCKSPEC" ]]; then
  printf 'ERROR: expected rockspec not found: %s\n' "$OLD_ROCKSPEC" >&2
  exit 1
fi

printf '%s\n' "$NEW_VERSION" > "$ROOT_DIR/VERSION"

perl -0pi -e "s/VERSION = \"\\Q$OLD_VERSION\\E\"/VERSION = \"$NEW_VERSION\"/" \
  "$ROOT_DIR/kong-plugin/kong/plugins/kong-ollama-agent-router/handler.lua"

perl -0pi -e "s/version = \"\\Q$OLD_VERSION\\E-1\"/version = \"$NEW_VERSION-1\"/; s/tag = \"v\\Q$OLD_VERSION\\E\"/tag = \"v$NEW_VERSION\"/g; s/kong-plugin-ollama-agent-router-\\Q$OLD_VERSION\\E-1\\.rockspec/kong-plugin-ollama-agent-router-$NEW_VERSION-1.rockspec/g" \
  "$OLD_ROCKSPEC" "$ROOT_DIR/README.md" "$ROOT_DIR/CHANGELOG.md"

if [[ "$OLD_ROCKSPEC" != "$NEW_ROCKSPEC" ]]; then
  mv "$OLD_ROCKSPEC" "$NEW_ROCKSPEC"
fi

"$ROOT_DIR/scripts/check-version.sh"
