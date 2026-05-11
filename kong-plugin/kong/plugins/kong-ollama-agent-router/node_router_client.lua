local _M = {}
_M.__index = _M

local function require_json()
  local ok, cjson = pcall(require, "cjson.safe")
  if ok then
    return cjson
  end
  ok, cjson = pcall(require, "cjson")
  if ok then
    return cjson
  end
  return nil
end

local function trim_slash(value)
  return tostring(value or ""):gsub("/+$", "")
end

local function join_url(base_url, path)
  path = tostring(path or "")
  if string.sub(path, 1, 1) ~= "/" then
    path = "/" .. path
  end
  return trim_slash(base_url) .. path
end

local function copy_table(value)
  local out = {}
  for key, item in pairs(value or {}) do
    out[key] = item
  end
  return out
end

local function merge_config(global, local_override)
  local out = copy_table(global)
  for key, value in pairs(local_override or {}) do
    out[key] = value
  end
  return out
end

local function header_json()
  return { ["content-type"] = "application/json", ["accept"] = "application/json" }
end

local function prefixed_value(prefix, token)
  token = tostring(token or "")
  prefix = tostring(prefix or "")
  if prefix == "" then
    return token
  end
  return prefix .. " " .. token
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err or ("failed to open " .. tostring(path))
  end
  local data = file:read("*a")
  file:close()
  return data
end

function _M.new(config, deps)
  deps = deps or {}
  return setmetatable({
    config = config or {},
    http_factory = deps.http_factory,
    json = deps.json or require_json(),
    ssl = deps.ssl,
    cert_cache = {},
  }, _M)
end

function _M:node_configs()
  local cfg = self.config.node_routers or {}
  return cfg.nodes or {}
end

function _M:path(name, fallback)
  local cfg = self.config.node_routers or {}
  return cfg[name] or fallback
end

function _M:timeout_ms(kind)
  local cfg = self.config.node_routers or {}
  if kind == "snapshot" then
    return cfg.snapshot_timeout_ms or 500
  end
  return cfg.request_timeout_ms or 120000
end

function _M:security_config(node, section)
  local cfg = self.config.node_routers or {}
  local global_security = cfg.security or {}
  local node_security = nil
  if section == "auth" then
    node_security = node and node.auth or nil
  elseif section == "tls" then
    node_security = node and node.tls or nil
  end
  return merge_config(global_security[section] or {}, node_security or {})
end

function _M:headers_for_node(node)
  local headers = header_json()
  local auth = self:security_config(node, "auth")
  local auth_type = auth.type or "none"
  if auth_type == "none" then
    return headers
  end

  local token = auth.token
  if token == nil or token == "" then
    return headers
  end

  if auth_type == "bearer" then
    local prefix = auth.header_prefix
    if prefix == nil or prefix == "" then
      prefix = "Bearer"
    end
    headers["authorization"] = prefixed_value(prefix, token)
    return headers
  end

  if auth_type == "header" then
    headers[auth.header_name or "x-api-key"] = prefixed_value(auth.header_prefix or "", token)
  end
  return headers
end

function _M:request_options(node)
  local tls = self:security_config(node, "tls")
  local options = {
    ssl_verify = tls.verify ~= false,
  }
  if tls.server_name and tls.server_name ~= "" then
    options.ssl_server_name = tls.server_name
  end

  local client_cert = tls.client_cert or {}
  if client_cert.enabled then
    local cert, key, err = self:load_client_cert(client_cert.cert_path, client_cert.key_path)
    if err then
      return nil, err
    end
    options.ssl_client_cert = cert
    options.ssl_client_priv_key = key
  end

  return options
end

function _M:load_client_cert(cert_path, key_path)
  if not cert_path or cert_path == "" or not key_path or key_path == "" then
    return nil, nil, "TLS client certificate requires cert_path and key_path"
  end
  local cache_key = cert_path .. "\0" .. key_path
  local cached = self.cert_cache[cache_key]
  if cached then
    return cached.cert, cached.key
  end

  local ssl = self.ssl
  if not ssl then
    local ok
    ok, ssl = pcall(require, "ngx.ssl")
    if not ok then
      return nil, nil, "ngx.ssl is unavailable for TLS client certificate parsing"
    end
  end

  local cert_pem, cert_err = read_file(cert_path)
  if not cert_pem then
    return nil, nil, cert_err
  end
  local key_pem, key_err = read_file(key_path)
  if not key_pem then
    return nil, nil, key_err
  end

  local cert, parse_cert_err = ssl.parse_pem_cert(cert_pem)
  if not cert then
    return nil, nil, parse_cert_err or "failed to parse TLS client certificate"
  end
  local key, parse_key_err = ssl.parse_pem_priv_key(key_pem)
  if not key then
    return nil, nil, parse_key_err or "failed to parse TLS client private key"
  end

  self.cert_cache[cache_key] = { cert = cert, key = key }
  return cert, key
end

function _M:request_json(node, method, path, body, timeout_kind)
  local json = self.json
  if not json then
    return nil, "JSON module is unavailable"
  end

  local http_factory = self.http_factory
  if not http_factory then
    local ok, http = pcall(require, "resty.http")
    if not ok then
      return nil, "resty.http is unavailable"
    end
    http_factory = http.new
  end

  local client = http_factory()
  if client.set_timeout then
    client:set_timeout(self:timeout_ms(timeout_kind))
  end
  if client.set_timeouts then
    client:set_timeouts(self:timeout_ms(timeout_kind), self:timeout_ms(timeout_kind), self:timeout_ms(timeout_kind))
  end

  local encoded
  if body ~= nil then
    encoded = json.encode(body)
  end

  local request_options, options_err = self:request_options(node)
  if not request_options then
    return nil, options_err
  end
  request_options.method = method
  request_options.body = encoded
  request_options.headers = self:headers_for_node(node)

  local res, err = client:request_uri(join_url(node.base_url, path), {
    method = request_options.method,
    body = request_options.body,
    headers = request_options.headers,
    ssl_verify = request_options.ssl_verify,
    ssl_server_name = request_options.ssl_server_name,
    ssl_client_cert = request_options.ssl_client_cert,
    ssl_client_priv_key = request_options.ssl_client_priv_key,
  })
  if not res then
    return nil, err or "node-router request failed"
  end

  local decoded = {}
  if res.body and res.body ~= "" then
    decoded = json.decode(res.body)
    if decoded == nil then
      return nil, "invalid JSON from node-router"
    end
  end

  if res.status < 200 or res.status >= 300 then
    local message = decoded.error and decoded.error.message or ("node-router returned HTTP " .. tostring(res.status))
    if res.status == 401 or res.status == 403 then
      return nil, self:format_node_error(message), 503, decoded
    end
    if res.status == 429 then
      return nil, self:format_node_error(message), 429, decoded
    end
    return nil, message, res.status, decoded
  end

  return decoded, nil, res.status
end

function _M:fetch_nodes()
  local nodes = {}
  local errors = {}
  for _, node in ipairs(self:node_configs()) do
    local capabilities, cap_err = self:request_json(node, "GET", self:path("capabilities_path", "/v1/router/capabilities"), nil, "snapshot")
    local runtime, runtime_err = nil, nil
    if capabilities then
      runtime, runtime_err = self:request_json(node, "GET", self:path("runtime_path", "/v1/router/runtime"), nil, "snapshot")
    end
    if capabilities and runtime then
      nodes[#nodes + 1] = {
        id = node.id or capabilities.nodeId,
        base_url = node.base_url,
        weight = node.weight or 0,
        tags = node.tags or {},
        capabilities = capabilities,
        runtime = runtime,
      }
    else
      errors[#errors + 1] = (node.id or node.base_url or "node") .. ": " .. self:format_node_error(cap_err or runtime_err)
    end
  end
  if #nodes == 0 then
    return nil, table.concat(errors, "; ") ~= "" and table.concat(errors, "; ") or "no node-router available"
  end
  return nodes
end

function _M:format_node_error(err)
  err = tostring(err or "node-router unavailable")
  local lowered = string.lower(err)
  if string.find(lowered, "api key") or string.find(lowered, "authentication") or string.find(lowered, "authorization") then
    return "node-router authentication failed"
  end
  if string.find(lowered, "rate limit") then
    return "node-router rate limited"
  end
  return err
end

function _M:execute(target, request, decision, priority)
  return self:request_json(target.node, "POST", self:path("execute_path", "/v1/router/execute"), {
    selectedModel = target.model.name,
    request = request,
    priority = priority,
    routerDecision = {
      taskType = decision.classification and decision.classification.taskType or nil,
      score = decision.score,
      reason = decision.reason,
      priority = priority,
    },
  })
end

function _M:create_job(target, request, classification, decision, priority)
  return self:request_json(target.node, "POST", self:path("create_job_path", "/v1/router/jobs"), {
    selectedModel = target.model.name,
    request = request,
    classification = {
      taskType = classification.taskType,
      complexity = classification.complexity,
      requiresLargeContext = classification.requiresLargeContext,
      requiresToolUse = classification.requiresToolUse,
      confidence = classification.confidence,
    },
    priority = priority,
    routerDecision = {
      score = decision.score,
      reason = decision.reason,
      priority = priority,
    },
  })
end

function _M:node_by_job_id(job_id)
  local node_id = string.match(tostring(job_id or ""), "^job_([^_]+)_")
  if not node_id then
    return nil
  end
  for _, node in ipairs(self:node_configs()) do
    if node.id == node_id then
      return node
    end
  end
  return nil
end

function _M:proxy_job(method, job_id, suffix)
  local node = self:node_by_job_id(job_id)
  if not node then
    return nil, "Cannot resolve node-router for job id"
  end
  return self:request_json(node, method, "/v1/jobs/" .. job_id .. (suffix or ""), nil)
end

return _M
