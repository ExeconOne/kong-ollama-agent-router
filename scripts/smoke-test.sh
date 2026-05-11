#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KONG_IMAGE="${KONG_IMAGE:-kong:3.8}"
KONG_PROXY_URL="${KONG_PROXY_URL:-http://127.0.0.1:8000}"
KONG_PROXY_PORT="${KONG_PROXY_PORT:-8000}"

PLUGIN_INSTALL_MODE="${PLUGIN_INSTALL_MODE:-local}"
LUAROCKS_PACKAGE="${LUAROCKS_PACKAGE:-kong-plugin-ollama-agent-router}"
LUAROCKS_VERSION="${LUAROCKS_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")-1}"
LUAROCKS_SERVER="${LUAROCKS_SERVER:-https://luarocks.org/manifests/grulka}"
LUAROCKS_ROCKSPEC_URL="${LUAROCKS_ROCKSPEC_URL:-}"
KONG_LUAROCKS_IMAGE="${KONG_LUAROCKS_IMAGE:-kong-ollama-agent-router-luarocks:$LUAROCKS_VERSION}"

if [[ -z "${KONG_CONTAINER:-}" ]]; then
  if [[ "$PLUGIN_INSTALL_MODE" == "luarocks" ]]; then
    KONG_CONTAINER="kong-ollama-agent-router-luarocks-test"
  else
    KONG_CONTAINER="kong-ollama-agent-router-test"
  fi
fi

NODE_ROUTER_URL="${NODE_ROUTER_URL:-http://127.0.0.1:11435}"
NODE_ROUTER_DOCKER_URL="${NODE_ROUTER_DOCKER_URL:-http://host.docker.internal:11435}"
NODE_ROUTER_CONFIG="${NODE_ROUTER_CONFIG:-$ROOT_DIR/../ollama-node-router/ollama-agent-router.yaml}"
NODE_ROUTER_RUNTIME_API_KEY="${NODE_ROUTER_RUNTIME_API_KEY:-}"
NODE_ROUTER_EXPECT_STANDALONE_DISABLED="${NODE_ROUTER_EXPECT_STANDALONE_DISABLED:-0}"

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
SMOKE_MODEL="${SMOKE_MODEL:-qwen2.5-coder:7b}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"

NODE_ROUTER_PID=""

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

json_get() {
  node -e '
const path = process.argv[1].split(".");
let value = JSON.parse(require("fs").readFileSync(0, "utf8"));
for (const key of path) value = value?.[key];
if (value === undefined || value === null) process.exit(2);
if (typeof value === "object") console.log(JSON.stringify(value));
else console.log(value);
' "$1"
}

cleanup() {
  if [[ "$KEEP_RUNNING" == "1" ]]; then
    log "KEEP_RUNNING=1, leaving Kong/node-router running"
    return
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$KONG_CONTAINER"; then
    docker rm -f "$KONG_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$NODE_ROUTER_PID" ]]; then
    kill "$NODE_ROUTER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_http() {
  local url="$1"
  local label="$2"
  local timeout="${3:-30}"
  local started
  started="$(date +%s)"
  until curl -fsS "$url" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started > timeout )); then
      fail "Timed out waiting for $label at $url"
    fi
    sleep 1
  done
}

node_router_curl() {
  local url="$1"
  if [[ -n "$NODE_ROUTER_RUNTIME_API_KEY" ]]; then
    curl -fsS -H "authorization: Bearer $NODE_ROUTER_RUNTIME_API_KEY" "$url"
  else
    curl -fsS "$url"
  fi
}

wait_node_router() {
  local url="$1"
  local label="$2"
  local timeout="${3:-30}"
  local started
  started="$(date +%s)"
  until node_router_curl "$url" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started > timeout )); then
      if [[ -f "$ROOT_DIR/.tmp/ollama-agent-router.log" ]]; then
        printf '\nLast node-router log lines:\n' >&2
        tail -n 80 "$ROOT_DIR/.tmp/ollama-agent-router.log" >&2 || true
      fi
      fail "Timed out waiting for $label at $url"
    fi
    sleep 1
  done
}

write_local_kong_config() {
  local target="$ROOT_DIR/.tmp/kong-smoke.yml"
  local security_yaml
  if [[ -n "$NODE_ROUTER_RUNTIME_API_KEY" ]]; then
    security_yaml=$(cat <<YAML
        security:
          auth:
            type: bearer
            token: "$NODE_ROUTER_RUNTIME_API_KEY"
          tls:
            verify: true
YAML
)
  else
    security_yaml=$(cat <<'YAML'
        security:
          auth:
            type: none
          tls:
            verify: true
YAML
)
  fi
  mkdir -p "$ROOT_DIR/.tmp"
  cat > "$target" <<YAML
_format_version: "3.0"

services:
  - name: ollama-node-router
    url: $NODE_ROUTER_DOCKER_URL
    routes:
      - name: ollama-router-all
        paths:
          - /

plugins:
  - name: kong-ollama-agent-router
    service: ollama-node-router
    config:
      node_routers:
        discovery: static
$security_yaml
        nodes:
          - id: local
            base_url: $NODE_ROUTER_DOCKER_URL
            weight: 100
            tags:
              - local
        capabilities_path: /v1/router/capabilities
        runtime_path: /v1/router/runtime
        execute_path: /v1/router/execute
        create_job_path: /v1/router/jobs
        request_timeout_ms: 180000
        snapshot_timeout_ms: 1000
        capabilities_cache_ttl_ms: 60000
        runtime_cache_ttl_ms: 1000
        stale_snapshot_ttl_ms: 5000
        allow_degraded_snapshot: false
      selection:
        strategy: score
        prefer_loaded_model: true
        respect_node_weight: true
        failover_on_execute_error: true
        max_failover_attempts: 1
      gateway_policy:
        expose_diagnostics: true
        allow_client_preferred_models: true
        allow_client_forbidden_models: true
        default_error_status: 503
YAML
  printf '%s\n' "$target"
}

build_luarocks_kong_image() {
  local build_dir="$ROOT_DIR/.tmp/kong-luarocks-image"
  mkdir -p "$build_dir"
  cat > "$build_dir/Dockerfile" <<'DOCKERFILE'
ARG KONG_IMAGE=kong:3.8
FROM ${KONG_IMAGE}

ARG LUAROCKS_PACKAGE=kong-plugin-ollama-agent-router
ARG LUAROCKS_VERSION=
ARG LUAROCKS_SERVER=https://luarocks.org/manifests/grulka
ARG LUAROCKS_ROCKSPEC_URL=

USER root
RUN if [ -n "$LUAROCKS_ROCKSPEC_URL" ]; then \
      luarocks install --deps-mode=none "$LUAROCKS_ROCKSPEC_URL"; \
    elif [ -n "$LUAROCKS_VERSION" ]; then \
      luarocks --only-server "$LUAROCKS_SERVER" install --deps-mode=none "$LUAROCKS_PACKAGE" "$LUAROCKS_VERSION"; \
    else \
      luarocks --only-server "$LUAROCKS_SERVER" install --deps-mode=none "$LUAROCKS_PACKAGE"; \
    fi
USER kong
DOCKERFILE

  if [[ -n "$LUAROCKS_ROCKSPEC_URL" ]]; then
    log "Building Kong image with $LUAROCKS_ROCKSPEC_URL from LuaRocks"
  else
    log "Building Kong image with $LUAROCKS_PACKAGE $LUAROCKS_VERSION from $LUAROCKS_SERVER"
  fi
  docker build \
    --build-arg "KONG_IMAGE=$KONG_IMAGE" \
    --build-arg "LUAROCKS_PACKAGE=$LUAROCKS_PACKAGE" \
    --build-arg "LUAROCKS_VERSION=$LUAROCKS_VERSION" \
    --build-arg "LUAROCKS_SERVER=$LUAROCKS_SERVER" \
    --build-arg "LUAROCKS_ROCKSPEC_URL=$LUAROCKS_ROCKSPEC_URL" \
    -t "$KONG_LUAROCKS_IMAGE" \
    "$build_dir" >/dev/null
}

log "Checking prerequisites"
need_cmd curl
need_cmd docker
need_cmd node
need_cmd ollama-agent-router

case "$PLUGIN_INSTALL_MODE" in
  local|luarocks) ;;
  *) fail "PLUGIN_INSTALL_MODE must be local or luarocks, got: $PLUGIN_INSTALL_MODE" ;;
esac

log "Checking Ollama at $OLLAMA_URL"
if ! curl -fsS "$OLLAMA_URL/api/tags" >/dev/null; then
  fail "Ollama is not reachable at $OLLAMA_URL. Start it first, for example: ollama serve"
fi

if ! curl -fsS "$OLLAMA_URL/api/tags" | grep -q "\"name\":\"$SMOKE_MODEL\""; then
  fail "Model $SMOKE_MODEL is not available in Ollama. Pull it first: ollama pull $SMOKE_MODEL"
fi

log "Checking ollama-node-router at $NODE_ROUTER_URL"
if node_router_curl "$NODE_ROUTER_URL/v1/router/capabilities" >/dev/null 2>&1; then
  log "Using already running node-router"
else
  [[ -f "$NODE_ROUTER_CONFIG" ]] || fail "Node-router config not found: $NODE_ROUTER_CONFIG"
  log "Starting ollama-agent-router with $NODE_ROUTER_CONFIG"
  ollama-agent-router serve --config "$NODE_ROUTER_CONFIG" > "$ROOT_DIR/.tmp/ollama-agent-router.log" 2>&1 &
  NODE_ROUTER_PID="$!"
  wait_node_router "$NODE_ROUTER_URL/v1/router/capabilities" "ollama-node-router" 30
fi

if [[ -n "$NODE_ROUTER_RUNTIME_API_KEY" ]]; then
  log "Checking node-router runtime-agent API key enforcement"
  UNAUTH_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' "$NODE_ROUTER_URL/v1/router/capabilities")"
  if [[ "$UNAUTH_STATUS" != "401" ]]; then
    fail "Expected unauthenticated runtime-agent request to return 401, got $UNAUTH_STATUS"
  fi
  node_router_curl "$NODE_ROUTER_URL/v1/router/capabilities" >/dev/null
fi

if [[ "$NODE_ROUTER_EXPECT_STANDALONE_DISABLED" == "1" ]]; then
  log "Checking node-router standalone plane is disabled"
  STANDALONE_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' "$NODE_ROUTER_URL/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"This should not be accepted directly\"}],\"stream\":false}")"
  if [[ "$STANDALONE_STATUS" != "404" ]]; then
    fail "Expected direct standalone request to return 404, got $STANDALONE_STATUS"
  fi
fi

log "Node-router capabilities"
node_router_curl "$NODE_ROUTER_URL/v1/router/capabilities" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.log(JSON.stringify({ nodeId: data.nodeId, status: data.status, version: data.version, models: data.models.map((m) => m.name) }, null, 2));
'

log "Preparing Kong config and container"
KONG_CONFIG="$(write_local_kong_config)"
docker pull "$KONG_IMAGE" >/dev/null
docker rm -f "$KONG_CONTAINER" >/dev/null 2>&1 || true

KONG_RUN_IMAGE="$KONG_IMAGE"
if [[ "$PLUGIN_INSTALL_MODE" == "luarocks" ]]; then
  build_luarocks_kong_image
  KONG_RUN_IMAGE="$KONG_LUAROCKS_IMAGE"
  docker run -d \
    --name "$KONG_CONTAINER" \
    -p "$KONG_PROXY_PORT:8000" \
    -e KONG_DATABASE=off \
    -e KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yml \
    -e KONG_PLUGINS=bundled,kong-ollama-agent-router \
    -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
    -e KONG_ADMIN_LISTEN=off \
    -e KONG_STATUS_LISTEN=off \
    -e KONG_LOG_LEVEL=info \
    -v "$KONG_CONFIG:/kong/declarative/kong.yml:ro" \
    "$KONG_RUN_IMAGE" >/dev/null
else
  docker run -d \
    --name "$KONG_CONTAINER" \
    -p "$KONG_PROXY_PORT:8000" \
    -e KONG_DATABASE=off \
    -e KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yml \
    -e KONG_PLUGINS=bundled,kong-ollama-agent-router \
    -e KONG_PROXY_LISTEN=0.0.0.0:8000 \
    -e KONG_ADMIN_LISTEN=off \
    -e KONG_STATUS_LISTEN=off \
    -e KONG_LOG_LEVEL=info \
    -v "$ROOT_DIR/kong-plugin/kong/plugins/kong-ollama-agent-router:/usr/local/share/lua/5.1/kong/plugins/kong-ollama-agent-router:ro" \
    -v "$KONG_CONFIG:/kong/declarative/kong.yml:ro" \
    "$KONG_RUN_IMAGE" >/dev/null
fi

wait_http "$KONG_PROXY_URL/health" "Kong proxy" 45

log "Kong health"
curl -fsS "$KONG_PROXY_URL/health"
printf '\n'

log "Kong router status"
curl -fsS "$KONG_PROXY_URL/v1/router/status" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.log(JSON.stringify(data, null, 2));
'

log "Sync chat through Kong -> plugin -> node-router -> Ollama"
SYNC_RESPONSE="$(curl -fsS "$KONG_PROXY_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"stream\":false,\"router\":{\"mode\":\"sync\",\"allowAsync\":false,\"taskType\":\"simple_chat\",\"preferredModels\":[\"$SMOKE_MODEL\"],\"requireGpuOnly\":false,\"maxExecutionTimeMs\":180000}}")"
printf '%s\n' "$SYNC_RESPONSE" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.log(JSON.stringify({
  model: data.model,
  content: data.choices?.[0]?.message?.content,
  router: data.router
}, null, 2));
if (data.choices?.[0]?.message?.content?.trim() !== "OK") process.exit(3);
if (!data.router || data.router.selectedModel === undefined || data.router.nodeId === undefined) process.exit(4);
'

log "Async chat through Kong"
ASYNC_RESPONSE="$(curl -fsS "$KONG_PROXY_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ASYNC_OK\"}],\"stream\":false,\"router\":{\"mode\":\"async\",\"allowAsync\":true,\"taskType\":\"simple_chat\",\"preferredModels\":[\"$SMOKE_MODEL\"],\"requireGpuOnly\":false}}")"
printf '%s\n' "$ASYNC_RESPONSE" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.log(JSON.stringify(data, null, 2));
if (data.object !== "router.job" || !data.id) process.exit(5);
'
JOB_ID="$(printf '%s\n' "$ASYNC_RESPONSE" | json_get id)"

log "Polling async result for $JOB_ID"
RESULT=""
for _ in $(seq 1 60); do
  HTTP_AND_BODY="$(curl -sS -w '\n%{http_code}' "$KONG_PROXY_URL/v1/jobs/$JOB_ID/result")"
  STATUS="$(printf '%s\n' "$HTTP_AND_BODY" | tail -n 1)"
  BODY="$(printf '%s\n' "$HTTP_AND_BODY" | sed '$d')"
  if [[ "$STATUS" == "200" ]]; then
    RESULT="$BODY"
    break
  fi
  if [[ "$STATUS" != "202" ]]; then
    printf '%s\n' "$BODY"
    fail "Unexpected async result status: $STATUS"
  fi
  sleep 1
done
[[ -n "$RESULT" ]] || fail "Async result was not ready in time"

printf '%s\n' "$RESULT" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.log(JSON.stringify({
  model: data.model,
  content: data.choices?.[0]?.message?.content
}, null, 2));
if (data.choices?.[0]?.message?.content?.trim() !== "ASYNC_OK") process.exit(6);
'

log "Smoke test passed"
printf 'Kong container: %s\n' "$KONG_CONTAINER"
printf 'Plugin install mode: %s\n' "$PLUGIN_INSTALL_MODE"
if [[ "$PLUGIN_INSTALL_MODE" == "luarocks" ]]; then
  printf 'Kong LuaRocks image: %s\n' "$KONG_LUAROCKS_IMAGE"
  printf 'LuaRocks package: %s %s\n' "$LUAROCKS_PACKAGE" "$LUAROCKS_VERSION"
  printf 'LuaRocks server: %s\n' "$LUAROCKS_SERVER"
  if [[ -n "$LUAROCKS_ROCKSPEC_URL" ]]; then
    printf 'LuaRocks rockspec URL: %s\n' "$LUAROCKS_ROCKSPEC_URL"
  fi
fi
printf 'Kong URL: %s\n' "$KONG_PROXY_URL"
printf 'Node-router URL: %s\n' "$NODE_ROUTER_URL"
