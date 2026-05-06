#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KONG_IMAGE="${KONG_IMAGE:-kong:3.8}"
KONG_CONTAINER="${KONG_CONTAINER:-kong-ollama-agent-router-test}"
KONG_PROXY_URL="${KONG_PROXY_URL:-http://127.0.0.1:8000}"
KONG_PROXY_PORT="${KONG_PROXY_PORT:-8000}"

NODE_ROUTER_URL="${NODE_ROUTER_URL:-http://127.0.0.1:11435}"
NODE_ROUTER_DOCKER_URL="${NODE_ROUTER_DOCKER_URL:-http://host.docker.internal:11435}"
NODE_ROUTER_CONFIG="${NODE_ROUTER_CONFIG:-$ROOT_DIR/../ollama-node-router/ollama-agent-router.yaml}"

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

write_local_kong_config() {
  local target="$ROOT_DIR/.tmp/kong-smoke.yml"
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

log "Checking prerequisites"
need_cmd curl
need_cmd docker
need_cmd node
need_cmd ollama-agent-router

log "Checking Ollama at $OLLAMA_URL"
if ! curl -fsS "$OLLAMA_URL/api/tags" >/dev/null; then
  fail "Ollama is not reachable at $OLLAMA_URL. Start it first, for example: ollama serve"
fi

if ! curl -fsS "$OLLAMA_URL/api/tags" | grep -q "\"name\":\"$SMOKE_MODEL\""; then
  fail "Model $SMOKE_MODEL is not available in Ollama. Pull it first: ollama pull $SMOKE_MODEL"
fi

log "Checking ollama-node-router at $NODE_ROUTER_URL"
if curl -fsS "$NODE_ROUTER_URL/v1/router/capabilities" >/dev/null 2>&1; then
  log "Using already running node-router"
else
  [[ -f "$NODE_ROUTER_CONFIG" ]] || fail "Node-router config not found: $NODE_ROUTER_CONFIG"
  log "Starting ollama-agent-router with $NODE_ROUTER_CONFIG"
  ollama-agent-router serve --config "$NODE_ROUTER_CONFIG" > "$ROOT_DIR/.tmp/ollama-agent-router.log" 2>&1 &
  NODE_ROUTER_PID="$!"
  wait_http "$NODE_ROUTER_URL/v1/router/capabilities" "ollama-node-router" 30
fi

log "Node-router capabilities"
curl -fsS "$NODE_ROUTER_URL/v1/router/capabilities" | node -e '
const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
console.log(JSON.stringify({ nodeId: data.nodeId, status: data.status, version: data.version, models: data.models.map((m) => m.name) }, null, 2));
'

log "Preparing Kong config and container"
KONG_CONFIG="$(write_local_kong_config)"
docker pull "$KONG_IMAGE" >/dev/null
docker rm -f "$KONG_CONTAINER" >/dev/null 2>&1 || true

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
  "$KONG_IMAGE" >/dev/null

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
printf 'Kong URL: %s\n' "$KONG_PROXY_URL"
printf 'Node-router URL: %s\n' "$NODE_ROUTER_URL"
