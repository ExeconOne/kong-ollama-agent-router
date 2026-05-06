.PHONY: test syntax smoke

test:
	lua scripts/test.lua

syntax:
	luac -p kong-plugin/kong/plugins/kong-ollama-router/*.lua

smoke:
	bash scripts/smoke-test.sh
