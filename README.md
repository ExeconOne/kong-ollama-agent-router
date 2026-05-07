# kong-ollama-agent-router

Kong Gateway plugin for routing OpenAI-compatible agentic chat completion requests to one or more `ollama-agent-router` runtime nodes.

The plugin owns public gateway behavior and routing decisions at the Kong layer. Each `ollama-agent-router` node remains the source of truth for local machine state, GPU/VRAM, loaded models, queues, running counters, and async jobs.

## Requirements

- Kong Gateway 3.8+ (also [Kong Gateway Community Edition](https://github.com/ExeconOne/kong-oss-community-edition) ). The local smoke test currently uses `kong:3.8`.
- Lua 5.1 / LuaJIT, as used by Kong/OpenResty.
- LuaRocks 3.x for local package builds.
- Runtime node-router service: [`ollama-agent-router`](https://www.npmjs.com/package/ollama-agent-router) .

## Installation

Install from LuaRocks after the package has been published:

```bash
luarocks install kong-plugin-ollama-agent-router
```

Then enable the plugin in Kong:

```bash
export KONG_PLUGINS=bundled,kong-ollama-agent-router
kong restart
```

Local install from this repository:

```bash
make install-local
```

Local build without installing dependencies, useful in CI:

```bash
make build-rock
```

The package installs these Kong modules:

```text
kong.plugins.kong-ollama-agent-router.handler
kong.plugins.kong-ollama-agent-router.schema
kong.plugins.kong-ollama-agent-router.classifier
kong.plugins.kong-ollama-agent-router.router_engine
kong.plugins.kong-ollama-agent-router.node_router_client
kong.plugins.kong-ollama-agent-router.response
kong.plugins.kong-ollama-agent-router.metrics
```

## Configuration

Declarative config example:

```yaml
_format_version: "3.0"

services:
  - name: ollama-node-router
    url: http://127.0.0.1:11435
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
            base_url: http://127.0.0.1:11435
            weight: 100
            tags:
              - local
        capabilities_path: /v1/router/capabilities
        runtime_path: /v1/router/runtime
        execute_path: /v1/router/execute
        create_job_path: /v1/router/jobs
        request_timeout_ms: 120000
        snapshot_timeout_ms: 500
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
        expose_diagnostics: false
        allow_client_preferred_models: true
        allow_client_forbidden_models: true
        default_error_status: 503
```

Admin API example:

```bash
curl -sS -X POST http://127.0.0.1:8001/services/ollama-node-router/plugins \
  --data "name=kong-ollama-agent-router" \
  --data "config.node_routers.discovery=static" \
  --data "config.node_routers.nodes[1].id=local" \
  --data "config.node_routers.nodes[1].base_url=http://127.0.0.1:11435" \
  --data "config.node_routers.nodes[1].weight=100"
```

Model specs, routes, GPU policy, queue policy, and job policy are not duplicated in Kong config. They are fetched from each node-router through `/v1/router/capabilities`.

## Development

Repository layout:

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
scripts/
```

Useful commands:

```bash
make lint
make test
make rockspec-lint
make build-rock
make pack-source-rock
make install-local
```

End-to-end smoke test with Kong OSS in Docker, a local `ollama-agent-router`, and local Ollama:

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

Use `KEEP_RUNNING=1 make smoke` to leave the Kong container and any node-router process started by the script running after the test.

## Versioning

The plugin uses SemVer. The release tag format is `vX.Y.Z`.

Current version is stored in:

- `VERSION`
- `kong-plugin/kong/plugins/kong-ollama-agent-router/handler.lua`
- `kong-plugin-ollama-agent-router-0.1.1-1.rockspec`

Check consistency:

```bash
./scripts/check-version.sh
```

Bump the version:

```bash
./scripts/bump-version.sh 1.0.0
```

## Building a New Version

Use the release helper for normal releases:

```bash
./scripts/release.sh
```

The default is a patch release. For example, if `VERSION` contains `0.1.0`, this creates `0.1.1`.

Explicit release modes:

```bash
./scripts/release.sh patch
./scripts/release.sh minor
./scripts/release.sh major
./scripts/release.sh 1.0.0
```

The script requires a clean git working tree, then:

1. reads the current version from `VERSION`,
2. computes the next version,
3. runs `./scripts/bump-version.sh X.Y.Z`,
4. runs `make lint`, `make test`, and `make build-rock`,
5. commits `Release vX.Y.Z`,
6. tags `vX.Y.Z`,
7. pushes the current branch and tags to `origin`.

If you need to force the branch name used during push:

```bash
RELEASE_BRANCH=main ./scripts/release.sh patch
```

## Publishing to LuaRocks

Before the first release:

1. Confirm the public GitHub repository URL in `kong-plugin-ollama-agent-router-0.1.1-1.rockspec`.
2. Create a LuaRocks account at `https://luarocks.org`.
3. Generate an API key in the LuaRocks account settings.
4. Add the key to GitHub repository secrets as `LUAROCKS_API_KEY`.

Preferred release flow:

```bash
./scripts/release.sh patch
```

Manual equivalent:

```bash
./scripts/bump-version.sh 1.0.0
git add .
git commit -m "Release v1.0.0"
git tag v1.0.0
git push origin main --tags
```

The GitHub Actions release workflow runs on `vX.Y.Z` tags. It verifies the version, runs lint/tests, builds the source rock, uploads artifacts, and publishes with:

```bash
luarocks upload kong-plugin-ollama-agent-router-1.0.0-1.rockspec --temp-key "$LUAROCKS_API_KEY"
```

The workflow only publishes for newly created tags. It uses the tag value as the release version and refuses to publish if `VERSION`, `handler.lua`, the rockspec version, or the rockspec `source.tag` do not match that tag.

Do not reuse an existing LuaRocks revision for changed content. If you need to correct an already published rockspec, increment the rockspec revision instead of forcing an upload.

## License

MIT. See [LICENSE](LICENSE).
