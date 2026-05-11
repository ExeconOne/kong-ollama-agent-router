package.path = table.concat({
  "./kong-plugin/?.lua",
  "./kong-plugin/?/init.lua",
  "./kong-plugin/kong/plugins/kong-ollama-agent-router/?.lua",
  "./spec/?.lua",
  package.path,
}, ";")

local tests = {}

function it(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values are not equal") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

function assert_truthy(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

function assert_match(value, pattern, message)
  if not string.match(tostring(value), pattern) then
    error((message or "pattern did not match") .. ": " .. tostring(value) .. " !~ " .. tostring(pattern), 2)
  end
end

function assert_type(value, expected, message)
  local actual = type(value)
  if actual ~= expected then
    error((message or "type mismatch") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local specs = {
  "spec.unit.classifier_spec",
  "spec.unit.router_engine_spec",
  "spec.unit.node_router_client_spec",
  "spec.unit.plugin_contract_spec",
}

for _, spec in ipairs(specs) do
  require(spec)
end

local failed = 0
for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if ok then
    io.write(".")
  else
    failed = failed + 1
    io.write("F")
    io.stderr:write("\n", test.name, "\n", tostring(err), "\n")
  end
end

io.write("\n", tostring(#tests - failed), " passed, ", tostring(failed), " failed\n")
if failed > 0 then
  os.exit(1)
end
