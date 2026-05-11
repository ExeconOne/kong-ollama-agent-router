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
        security:
          auth:
            type: none
          tls:
            verify: true
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

## Securing the Runtime Agent Connection

`ollama-agent-router` can protect its runtime-agent plane with API keys and traffic limits. In that mode, the Kong plugin must authenticate to the node-router when calling `/v1/router/*` and `/v1/jobs/*`.

The recommended setup is:

1. Configure the node-router [Ollama Agent Router](https://www.npmjs.com/package/ollama-agent-router) `runtimeAgent` plane with `requireApiKey: true`.
2. Create one API key scoped only to `runtimeAgent`.
3. Configure this plugin with that key under `node_routers.security.auth`.
4. Keep the node-router [Ollama Agent Router](https://www.npmjs.com/package/ollama-agent-router) `standalone` plane disabled if all public traffic goes through Kong.

Node-router access config example:

```yaml
access:
  managedConfigPath: ./ollama-agent-router.access.yaml
  bootstrapIfMissing: true
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
      - id: kong-runtime
        name: Kong runtime caller
        keyHash: sha256:replace-with-runtime-key-hash
        enabled: true
        scopes: [runtimeAgent]
        limits:
          runtimeAgent:
            requests: 2000
            windowSeconds: 60
```

Kong plugin config using a bearer token:

```yaml
plugins:
  - name: kong-ollama-agent-router
    config:
      node_routers:
        discovery: static
        security:
          auth:
            type: bearer
            token: "{vault://env/OAR_RUNTIME_API_KEY}"
          tls:
            verify: true
        nodes:
          - id: gex44-a
            base_url: https://gex44-a.local:11435
            weight: 100
            tls:
              server_name: gex44-a.local
```

`auth.type` supports:

- `none`: send no runtime credential. This is the default for backwards compatibility.
- `bearer`: send `Authorization: Bearer <token>`.
- `header`: send the token in a custom header, for example `x-api-key`.

Per-node overrides are supported when different node-routers use different credentials:

```yaml
node_routers:
  security:
    auth:
      type: bearer
      token: "{vault://env/OAR_DEFAULT_RUNTIME_API_KEY}"
  nodes:
    - id: gex44-a
      base_url: https://gex44-a.local:11435
      auth:
        token: "{vault://env/OAR_GEX44_A_RUNTIME_API_KEY}"
    - id: gex44-b
      base_url: https://gex44-b.local:11435
      auth:
        type: header
        header_name: x-api-key
        token: "{vault://env/OAR_GEX44_B_RUNTIME_API_KEY}"
```

The plugin never forwards the public client `Authorization` header to node-router. Runtime-agent credentials are generated from plugin configuration only.

TLS options:

```yaml
node_routers:
  security:
    tls:
      verify: true
      server_name: node-router.local
      client_cert:
        enabled: true
        cert_path: /etc/kong/certs/kong-runtime-client.crt
        key_path: /etc/kong/certs/kong-runtime-client.key
```

`tls.verify: true` should be used in production. If the node-router uses a private CA, configure Kong/OpenResty trust for that CA. `client_cert` makes the plugin present a client certificate to a TLS endpoint that requires it. Runtime-agent authorization should still use an API key unless the node-router or a TLS proxy in front of it explicitly enforces client certificate trust for the runtime-agent plane.

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
make smoke
make smoke-secure-runtime
make smoke-luarocks
```

End-to-end smoke test with Kong OSS in Docker, a local `ollama-agent-router`, and local Ollama:

```bash
make smoke
```

By default, `make smoke` mounts the plugin source from this repository into the Kong container. To test the published LuaRocks package instead:

```bash
make smoke-luarocks
```

This builds a temporary Docker image based on `KONG_IMAGE`, runs `luarocks install kong-plugin-ollama-agent-router <version>`, then starts Kong from that image. The default LuaRocks version is derived from `VERSION` as `<VERSION>-1`, for example `0.1.1-1`.

The default LuaRocks manifest is the published module namespace:

```text
https://luarocks.org/modules/grulka/kong-plugin-ollama-agent-router
```

Override the installed package or version:

```bash
LUAROCKS_VERSION=0.1.1-1 make smoke-luarocks
LUAROCKS_PACKAGE=kong-plugin-ollama-agent-router LUAROCKS_VERSION=0.1.1-1 make smoke-luarocks
```

Defaults:

```text
KONG_IMAGE=kong:3.8
KONG_PROXY_URL=http://127.0.0.1:8000
NODE_ROUTER_URL=http://127.0.0.1:11435
NODE_ROUTER_CONFIG=../ollama-node-router/ollama-agent-router.yaml
NODE_ROUTER_RUNTIME_API_KEY=
OLLAMA_URL=http://127.0.0.1:11434
SMOKE_MODEL=qwen2.5-coder:7b
PLUGIN_INSTALL_MODE=local
LUAROCKS_PACKAGE=kong-plugin-ollama-agent-router
LUAROCKS_VERSION=<VERSION>-1
LUAROCKS_SERVER=https://luarocks.org/manifests/grulka
```

Use `KEEP_RUNNING=1 make smoke` to leave the Kong container and any node-router process started by the script running after the test.

To run the smoke test against a node-router with the runtime-agent plane protected by a bearer API key:

```bash
NODE_ROUTER_RUNTIME_API_KEY=runtime-secret make smoke
```

To run a full secure runtime-agent smoke test that generates a temporary node-router config, disables the standalone plane, requires a `runtimeAgent` API key, configures the Kong plugin with that key, and then verifies Kong can still complete sync and async requests:

```bash
make smoke-secure-runtime
```

Useful overrides for the secure smoke test:

```text
NODE_ROUTER_SECURE_PORT=11436
KONG_SECURE_PROXY_PORT=8010
NODE_ROUTER_RUNTIME_API_KEY=<generated if omitted>
NODE_ROUTER_SECURE_DIR=.tmp/secure-runtime
```

## Versioning

The plugin uses SemVer. The release tag format is `vX.Y.Z`.

Current version is stored in:

- `VERSION`
- `kong-plugin/kong/plugins/kong-ollama-agent-router/handler.lua`
- `kong-plugin-ollama-agent-router-0.1.3-1.rockspec`

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

1. Confirm the public GitHub repository URL in `kong-plugin-ollama-agent-router-0.1.3-1.rockspec`.
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
