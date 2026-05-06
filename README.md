# kong-ollama-agent-router

Kong custom plugin for routing OpenAI-compatible chat completion requests to one or more `ollama-node-router` runtime agents.

The plugin owns public gateway behavior and routing decisions. Each `ollama-node-router` remains the source of truth for local machine state, GPU/VRAM, loaded models, queues, running counters, and async jobs.

## Layout

```text
kong-plugin/kong/plugins/kong-ollama-agent-router/
  handler.lua
  schema.lua
  classifier.lua
  router_engine.lua
  node_router_client.lua
  response.lua
  metrics.lua
spec/unit/
scripts/test.lua
```

## Test

```bash
make test
```

or directly:

```bash
lua scripts/test.lua
```

## Smoke Test

Run a local end-to-end smoke test with Kong OSS in Docker, a local `ollama-agent-router`, and local Ollama:

```bash
make smoke
```

Defaults:

```text
KONG_IMAGE=kong:3.8
KONG_PROXY_URL=http://127.0.0.1:8000
NODE_ROUTER_URL=http://127.0.0.1:11435
NODE_ROUTER_CONFIG=../ollama-node-router/ollama-agent-router.yaml
OLLAMA_URL=http://127.0.0.1:11434
SMOKE_MODEL=qwen2.5-coder:7b
```

The script verifies:

```text
1. Ollama is reachable and has SMOKE_MODEL.
2. ollama-node-router is running, or starts it from NODE_ROUTER_CONFIG.
3. Kong starts in Docker with the local plugin mounted.
4. /health and /v1/router/status work through Kong.
5. Sync /v1/chat/completions reaches Ollama and returns router metadata.
6. Async job creation and result retrieval work through Kong.
```

Use `KEEP_RUNNING=1 make smoke` to leave the Kong container and any node-router process started by the script running after the test.

## Kong Config Sketch

```yaml
plugins:
  - name: kong-ollama-agent-router
    config:
      node_routers:
        discovery: static
        nodes:
          - id: gex44-a
            base_url: http://10.0.10.11:11435
            weight: 100
          - id: gex44-b
            base_url: http://10.0.10.12:11435
            weight: 100
        capabilities_path: /v1/router/capabilities
        runtime_path: /v1/router/runtime
        execute_path: /v1/router/execute
        create_job_path: /v1/router/jobs
```

Model specs, routes, GPU policy, queue policy, and job policy are not duplicated in Kong config. They are fetched from each node-router through `/v1/router/capabilities`.
