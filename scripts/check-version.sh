#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

VERSION_VALUE="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$VERSION_VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must be SemVer X.Y.Z, got: $VERSION_VALUE"

if [[ $# -gt 1 ]]; then
  fail "Usage: $0 [expected-version]"
fi

if [[ $# -eq 1 && "$VERSION_VALUE" != "$1" ]]; then
  fail "VERSION is $VERSION_VALUE, expected $1"
fi

ROCKSPEC="$ROOT_DIR/kong-plugin-ollama-agent-router-$VERSION_VALUE-1.rockspec"
[[ -f "$ROCKSPEC" ]] || fail "Expected rockspec not found: $ROCKSPEC"

HANDLER_VERSION="$(sed -n 's/.*VERSION = "\([^"]*\)".*/\1/p' "$ROOT_DIR/kong-plugin/kong/plugins/kong-ollama-agent-router/handler.lua")"
ROCKSPEC_VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "$ROCKSPEC")"
ROCKSPEC_TAG="$(sed -n 's/.*tag = "\([^"]*\)".*/\1/p' "$ROCKSPEC")"

[[ "$HANDLER_VERSION" == "$VERSION_VALUE" ]] || fail "handler.lua VERSION is $HANDLER_VERSION, expected $VERSION_VALUE"
[[ "$ROCKSPEC_VERSION" == "$VERSION_VALUE-1" ]] || fail "rockspec version is $ROCKSPEC_VERSION, expected $VERSION_VALUE-1"
[[ "$ROCKSPEC_TAG" == "v$VERSION_VALUE" ]] || fail "rockspec source.tag is $ROCKSPEC_TAG, expected v$VERSION_VALUE"

printf 'Version OK: %s\n' "$VERSION_VALUE"
