.PHONY: lint test syntax smoke smoke-secure-runtime smoke-luarocks rockspec-lint build-rock pack-source-rock install-local version-check release-patch

ROCKSPEC := kong-plugin-ollama-agent-router-$(shell tr -d '[:space:]' < VERSION)-1.rockspec

lint: syntax version-check rockspec-lint

test:
	lua scripts/test.lua

syntax:
	luac -p kong-plugin/kong/plugins/kong-ollama-agent-router/*.lua

version-check:
	bash scripts/check-version.sh

rockspec-lint:
	luarocks lint $(ROCKSPEC)

build-rock:
	luarocks make --deps-mode=none --pack-binary-rock $(ROCKSPEC)

pack-source-rock:
	luarocks pack $(ROCKSPEC)

install-local:
	luarocks --local make --deps-mode=none $(ROCKSPEC)

smoke:
	bash scripts/smoke-test.sh

smoke-secure-runtime:
	bash scripts/smoke-secure-runtime.sh

smoke-luarocks:
	bash scripts/smoke-luarocks.sh

release-patch:
	bash scripts/release.sh patch
