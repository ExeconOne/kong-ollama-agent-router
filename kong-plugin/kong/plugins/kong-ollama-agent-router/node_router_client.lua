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

local function header_json()
  return { ["content-type"] = "application/json", ["accept"] = "application/json" }
end

function _M.new(config, deps)
  deps = deps or {}
  return setmetatable({
    config = config or {},
    http_factory = deps.http_factory,
    json = deps.json or require_json(),
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

  local res, err = client:request_uri(join_url(node.base_url, path), {
    method = method,
    body = encoded,
    headers = header_json(),
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
    return nil, decoded.error and decoded.error.message or ("node-router returned HTTP " .. tostring(res.status)), res.status, decoded
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
      errors[#errors + 1] = (node.id or node.base_url or "node") .. ": " .. tostring(cap_err or runtime_err)
    end
  end
  if #nodes == 0 then
    return nil, table.concat(errors, "; ") ~= "" and table.concat(errors, "; ") or "no node-router available"
  end
  return nodes
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
