local NodeRouterClient = require "kong.plugins.kong-ollama-agent-router.node_router_client"

local function json_stub()
  return {
    encode = function(_)
      return "encoded"
    end,
    decode = function(value)
      if value == "capabilities" then
        return { nodeId = "local", status = "ok", models = {}, routes = {} }
      end
      if value == "runtime" then
        return { nodeId = "local", status = "ok", ollama = { reachable = true }, queues = { byModel = {} } }
      end
      if value == "api-key-error" then
        return { error = { message = "API key required" } }
      end
      if value == "rate-limit-error" then
        return { error = { message = "Rate limit exceeded" } }
      end
      return {}
    end,
  }
end

local function fake_http_factory(calls, responder)
  return function()
    return {
      set_timeout = function(_, value)
        calls.timeout = value
      end,
      set_timeouts = function(_, connect, send, read)
        calls.timeouts = { connect = connect, send = send, read = read }
      end,
      request_uri = function(_, uri, opts)
        calls[#calls + 1] = { uri = uri, opts = opts }
        return responder(uri, opts)
      end,
    }
  end
end

local function client(config, calls, responder, extra_deps)
  extra_deps = extra_deps or {}
  extra_deps.http_factory = fake_http_factory(calls, responder)
  extra_deps.json = json_stub()
  return NodeRouterClient.new(config, extra_deps)
end

it("sends a runtime-agent bearer token and TLS options to node-router", function()
  local calls = {}
  local c = client({
    node_routers = {
      security = {
        auth = { type = "bearer", token = "runtime-secret" },
        tls = { verify = false, server_name = "node-router.local" },
      },
      nodes = {
        { id = "local", base_url = "https://node-router.local:11435" },
      },
      snapshot_timeout_ms = 700,
    },
  }, calls, function()
    return { status = 200, body = "" }
  end)

  local ok, err = c:request_json(c:node_configs()[1], "GET", "/v1/router/capabilities", nil, "snapshot")
  assert_truthy(ok, err)
  assert_equal(calls.timeout, 700)
  assert_equal(calls[1].opts.headers.authorization, "Bearer runtime-secret")
  assert_equal(calls[1].opts.ssl_verify, false)
  assert_equal(calls[1].opts.ssl_server_name, "node-router.local")
end)

it("lets per-node auth override global auth", function()
  local calls = {}
  local c = client({
    node_routers = {
      security = {
        auth = { type = "bearer", token = "global-secret" },
      },
      nodes = {
        {
          id = "local",
          base_url = "http://node-router",
          auth = { type = "header", token = "node-secret", header_name = "x-api-key" },
        },
      },
    },
  }, calls, function()
    return { status = 200, body = "" }
  end)

  local ok, err = c:request_json(c:node_configs()[1], "GET", "/v1/router/runtime", nil, "snapshot")
  assert_truthy(ok, err)
  assert_equal(calls[1].opts.headers.authorization, nil)
  assert_equal(calls[1].opts.headers["x-api-key"], "node-secret")
end)

it("uses runtime-agent credentials when proxying job requests", function()
  local calls = {}
  local c = client({
    node_routers = {
      security = {
        auth = { type = "bearer", token = "runtime-secret" },
      },
      nodes = {
        { id = "local", base_url = "http://node-router" },
      },
    },
  }, calls, function()
    return { status = 202, body = "" }
  end)

  local ok, err, status = c:proxy_job("GET", "job_local_abc", "/result")
  assert_truthy(ok, err)
  assert_equal(status, 202)
  assert_equal(calls[1].uri, "http://node-router/v1/jobs/job_local_abc/result")
  assert_equal(calls[1].opts.headers.authorization, "Bearer runtime-secret")
end)

it("loads and passes client certificate options when configured", function()
  local cert_path = os.tmpname()
  local key_path = os.tmpname()
  local cert_file = assert(io.open(cert_path, "w"))
  cert_file:write("CERT PEM")
  cert_file:close()
  local key_file = assert(io.open(key_path, "w"))
  key_file:write("KEY PEM")
  key_file:close()

  local calls = {}
  local c = client({
    node_routers = {
      security = {
        tls = {
          client_cert = {
            enabled = true,
            cert_path = cert_path,
            key_path = key_path,
          },
        },
      },
      nodes = {
        { id = "local", base_url = "https://node-router" },
      },
    },
  }, calls, function()
    return { status = 200, body = "" }
  end, {
    ssl = {
      parse_pem_cert = function(value)
        assert_equal(value, "CERT PEM")
        return "CERT_CDATA"
      end,
      parse_pem_priv_key = function(value)
        assert_equal(value, "KEY PEM")
        return "KEY_CDATA"
      end,
    },
  })

  local ok, err = c:request_json(c:node_configs()[1], "GET", "/v1/router/capabilities", nil, "snapshot")
  os.remove(cert_path)
  os.remove(key_path)
  assert_truthy(ok, err)
  assert_equal(calls[1].opts.ssl_client_cert, "CERT_CDATA")
  assert_equal(calls[1].opts.ssl_client_priv_key, "KEY_CDATA")
end)

it("sanitizes auth and rate-limit errors while fetching nodes", function()
  local calls = {}
  local c = client({
    node_routers = {
      nodes = {
        { id = "auth-node", base_url = "http://auth-node" },
        { id = "rate-node", base_url = "http://rate-node" },
      },
    },
  }, calls, function(uri)
    if string.find(uri, "auth-node", 1, true) then
      return { status = 401, body = "api-key-error" }
    end
    return { status = 429, body = "rate-limit-error" }
  end)

  local nodes, err = c:fetch_nodes()
  assert_equal(nodes, nil)
  assert_match(err, "auth%-node: node%-router authentication failed")
  assert_match(err, "rate%-node: node%-router rate limited")
end)

it("maps internal node-router auth failures to upstream unavailable", function()
  local calls = {}
  local c = client({
    node_routers = {
      nodes = {
        { id = "local", base_url = "http://node-router" },
      },
    },
  }, calls, function()
    return { status = 401, body = "api-key-error" }
  end)

  local result, err, status = c:request_json(c:node_configs()[1], "POST", "/v1/router/execute", {})
  assert_equal(result, nil)
  assert_equal(err, "node-router authentication failed")
  assert_equal(status, 503)
end)

it("preserves node-router rate limit status as public backpressure", function()
  local calls = {}
  local c = client({
    node_routers = {
      nodes = {
        { id = "local", base_url = "http://node-router" },
      },
    },
  }, calls, function()
    return { status = 429, body = "rate-limit-error" }
  end)

  local result, err, status = c:request_json(c:node_configs()[1], "POST", "/v1/router/execute", {})
  assert_equal(result, nil)
  assert_equal(err, "node-router rate limited")
  assert_equal(status, 429)
end)
