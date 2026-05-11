local handler = require "kong.plugins.kong-ollama-agent-router.handler"
local schema = require "kong.plugins.kong-ollama-agent-router.schema"

local function read_project_version()
  local file = assert(io.open("VERSION", "r"))
  local value = file:read("*l")
  file:close()
  return value
end

local function find_named_field(fields, name)
  for _, entry in ipairs(fields or {}) do
    if entry[name] ~= nil then
      return entry[name]
    end
  end
  return nil
end

local function plugin_config_schema()
  local config = find_named_field(schema.fields, "config")
  assert_type(config, "table", "schema must expose a config record")
  return config
end

it("loads the Kong handler with VERSION and PRIORITY", function()
  assert_type(handler, "table")
  assert_match(handler.VERSION, "^%d+%.%d+%.%d+$")
  assert_equal(handler.VERSION, read_project_version())
  assert_type(handler.PRIORITY, "number")
  assert_truthy(handler.PRIORITY > 0, "handler PRIORITY must be positive")
end)

it("declares the expected Kong plugin name", function()
  assert_equal(schema.name, "kong-ollama-agent-router")
end)

it("requires at least one configured node-router", function()
  local config = plugin_config_schema()
  local node_routers = find_named_field(config.fields, "node_routers")
  assert_type(node_routers, "table", "node_routers schema is missing")
  assert_equal(node_routers.required, true)

  local nodes = find_named_field(node_routers.fields, "nodes")
  assert_type(nodes, "table", "nodes schema is missing")
  assert_equal(nodes.required, true)
  assert_equal(nodes.len_min, 1)

  local node_fields = nodes.elements and nodes.elements.fields
  assert_type(node_fields, "table", "node record fields are missing")
  assert_equal(find_named_field(node_fields, "id").required, true)
  assert_equal(find_named_field(node_fields, "base_url").required, true)
end)

it("keeps node-router security disabled by default for backwards compatibility", function()
  local config = plugin_config_schema()
  local node_routers = find_named_field(config.fields, "node_routers")
  local security = find_named_field(node_routers.fields, "security")
  assert_type(security, "table", "node_routers.security schema is missing")

  local auth = find_named_field(security.fields, "auth")
  local tls = find_named_field(security.fields, "tls")
  assert_type(auth, "table", "node_routers.security.auth schema is missing")
  assert_type(tls, "table", "node_routers.security.tls schema is missing")
  assert_equal(find_named_field(auth.fields, "type").default, "none")
  assert_equal(find_named_field(auth.fields, "type").one_of[2], "bearer")
  assert_equal(find_named_field(tls.fields, "verify").default, true)
end)

it("allows per-node auth and TLS overrides", function()
  local config = plugin_config_schema()
  local node_routers = find_named_field(config.fields, "node_routers")
  local nodes = find_named_field(node_routers.fields, "nodes")
  local node_fields = nodes.elements and nodes.elements.fields
  local auth = find_named_field(node_fields, "auth")
  local tls = find_named_field(node_fields, "tls")
  assert_type(auth, "table", "node auth override schema is missing")
  assert_type(tls, "table", "node TLS override schema is missing")
  assert_equal(find_named_field(auth.fields, "type").one_of[3], "header")
  assert_equal(find_named_field(tls.fields, "verify").default, true)
end)

it("keeps gateway policy defaults permissive for existing clients", function()
  local config = plugin_config_schema()
  local gateway_policy = find_named_field(config.fields, "gateway_policy")
  assert_type(gateway_policy, "table", "gateway_policy schema is missing")

  assert_equal(find_named_field(gateway_policy.fields, "allow_client_preferred_models").default, true)
  assert_equal(find_named_field(gateway_policy.fields, "allow_client_forbidden_models").default, true)
  assert_equal(find_named_field(gateway_policy.fields, "default_error_status").default, 503)
end)
