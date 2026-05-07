# Contributing

## Development Setup

Install Lua 5.1 and LuaRocks, then run:

```bash
make lint
make test
make build-rock
```

For local Kong smoke testing, run:

```bash
make smoke
```

The smoke test expects Docker, Ollama, and `ollama-agent-router` to be available.

## Pull Requests

- Keep plugin module paths under `kong-plugin/kong/plugins/kong-ollama-agent-router/`.
- Keep `VERSION`, `handler.lua`, and the rockspec version in sync.
- Add or update tests for routing, schema, or package behavior changes.
- Do not commit secrets, API keys, generated rocks, or local runtime logs.

## Releases

Use SemVer and tag releases as `vX.Y.Z`.

```bash
./scripts/bump-version.sh X.Y.Z
git add .
git commit -m "Release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```
