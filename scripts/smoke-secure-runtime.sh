#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NODE_ROUTER_SECURE_PORT="${NODE_ROUTER_SECURE_PORT:-11436}"
KONG_SECURE_PROXY_PORT="${KONG_SECURE_PROXY_PORT:-8010}"
NODE_ROUTER_RUNTIME_API_KEY="${NODE_ROUTER_RUNTIME_API_KEY:-secure-runtime-smoke-$(date +%s)-$RANDOM}"
NODE_ROUTER_SECURE_DIR="${NODE_ROUTER_SECURE_DIR:-$ROOT_DIR/.tmp/secure-runtime}"
NODE_ROUTER_SECURE_CONFIG="$NODE_ROUTER_SECURE_DIR/ollama-agent-router-secure.yaml"
NODE_ROUTER_SECURE_ACCESS_CONFIG="$NODE_ROUTER_SECURE_DIR/ollama-agent-router.access.yaml"

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
SMOKE_MODEL="${SMOKE_MODEL:-qwen2.5-coder:7b}"

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

runtime_key_hash() {
  node -e "const crypto=require('crypto'); console.log('sha256:'+crypto.createHash('sha256').update(process.argv[1]).digest('hex'))" "$NODE_ROUTER_RUNTIME_API_KEY"
}

write_secure_node_router_config() {
  mkdir -p "$NODE_ROUTER_SECURE_DIR"
  rm -f "$NODE_ROUTER_SECURE_ACCESS_CONFIG"
  local key_hash
  key_hash="$(runtime_key_hash)"
  cat > "$NODE_ROUTER_SECURE_CONFIG" <<YAML
server:
  nodeId: local
  host: 127.0.0.1
  port: $NODE_ROUTER_SECURE_PORT
  basePath: /
  requestBodyLimit: 8mb
  https:
    enabled: false
    certPath:
    keyPath:
    caPath:
access:
  managedConfigPath: $NODE_ROUTER_SECURE_ACCESS_CONFIG
  bootstrapIfMissing: true
  admin:
    enabled: false
    allowedIps: [127.0.0.1, "::1"]
    trustedProxy: false
    apiKeyHashes: []
    clientCert:
      required: false
      allowedFingerprints: []
      allowedSubjects: []
    auditLog: true
  managed:
    version: 1
    planes:
      standalone:
        enabled: false
        auth:
          requireApiKey: true
          anonymous: reject
      runtimeAgent:
        enabled: true
        auth:
          requireApiKey: true
          anonymous: reject
        defaultLimit:
          requests: 2000
          windowSeconds: 60
    apiKeys:
      - id: kong-runtime-smoke
        name: Kong secure smoke runtime caller
        keyHash: $key_hash
        enabled: true
        scopes: [runtimeAgent]
        limits:
          runtimeAgent:
            requests: 2000
            windowSeconds: 60
ollama:
  baseUrl: $OLLAMA_URL
  openAiCompatiblePath: /v1/chat/completions
  nativeApiBasePath: /api
  keepAlive: 5m
  requestTimeoutMs: 180000
gpu:
  provider: none
  name: Secure smoke CPU
  vramTotalMb: 0
  vramSafetyReserveMb: 0
  maxGpuUtilizationPct: 95
  requireGpuOnlyByDefault: false
  monitor:
    enabled: false
    intervalMs: 5000
    nvidiaSmiPath: nvidia-smi
router:
  defaultMode: auto
  syncMaxQueueTimeMs: 250
  heavyLoadQueueDepth: 4
  heavyLoadGpuFreeMbThreshold: 0
  defaultTaskType: unknown
  classification:
    mode: heuristic
    optionalClassifierModel:
    classifierTimeoutMs: 1500
jobs:
  store: memory
  resultTtlSeconds: 86400
  maxAttempts: 2
  cleanupIntervalMs: 60000
models:
  - name: $SMOKE_MODEL
    sizeGb: 4.0
    purpose: [triage, simple_chat, summarize, code_generate, code_review, code_fix, agentic_reasoning, large_context, tool_use]
    priority: 50
    maxConcurrent: 1
    defaultContext: 4096
    maxContext: 8192
    timeoutMs: 180000
    costClass: low
    exclusive: false
    allowWhenBusy: true
    tags: [secure-smoke]
routes:
  triage: [$SMOKE_MODEL]
  simple_chat: [$SMOKE_MODEL]
  summarize: [$SMOKE_MODEL]
  code_generate: [$SMOKE_MODEL]
  code_review: [$SMOKE_MODEL]
  code_fix: [$SMOKE_MODEL]
  agentic_reasoning: [$SMOKE_MODEL]
  large_context: [$SMOKE_MODEL]
  tool_use: [$SMOKE_MODEL]
  unknown: [$SMOKE_MODEL]
queue:
  globalMaxConcurrent: 1
  globalMaxQueued: 20
  perUserMaxQueued: 20
  defaultPriority: normal
  timeoutMs: 180000
YAML
}

log "Preparing secure node-router config"
need_cmd node
write_secure_node_router_config

log "Running secure Kong -> runtime-agent smoke test"
NODE_ROUTER_URL="http://127.0.0.1:$NODE_ROUTER_SECURE_PORT" \
NODE_ROUTER_DOCKER_URL="http://host.docker.internal:$NODE_ROUTER_SECURE_PORT" \
NODE_ROUTER_CONFIG="$NODE_ROUTER_SECURE_CONFIG" \
NODE_ROUTER_RUNTIME_API_KEY="$NODE_ROUTER_RUNTIME_API_KEY" \
NODE_ROUTER_EXPECT_STANDALONE_DISABLED=1 \
KONG_CONTAINER="${KONG_CONTAINER:-kong-ollama-agent-router-secure-test}" \
KONG_PROXY_PORT="${KONG_PROXY_PORT:-$KONG_SECURE_PROXY_PORT}" \
KONG_PROXY_URL="${KONG_PROXY_URL:-http://127.0.0.1:$KONG_SECURE_PROXY_PORT}" \
OLLAMA_URL="$OLLAMA_URL" \
SMOKE_MODEL="$SMOKE_MODEL" \
bash "$ROOT_DIR/scripts/smoke-test.sh"
