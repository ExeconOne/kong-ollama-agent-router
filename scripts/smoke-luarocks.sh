#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLUGIN_INSTALL_MODE=luarocks exec "$ROOT_DIR/scripts/smoke-test.sh"
