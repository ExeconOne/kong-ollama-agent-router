local classifier = require "kong.plugins.kong-ollama-agent-router.classifier"
local router_engine = require "kong.plugins.kong-ollama-agent-router.router_engine"
local NodeRouterClient = require "kong.plugins.kong-ollama-agent-router.node_router_client"
local response = require "kong.plugins.kong-ollama-agent-router.response"

local KongOllamaRouterHandler = {
  VERSION = "0.1.3",
  PRIORITY = 900,
}

local function error_body(message)
  return { error = { message = message } }
end

local function strip_client_model_overrides(conf, router)
  local policy = conf.gateway_policy or {}
  if policy.allow_client_preferred_models == false then
    router.preferredModels = {}
  end
  if policy.allow_client_forbidden_models == false then
    router.forbiddenModels = {}
  end
end

local function first_capabilities(nodes)
  for _, node in ipairs(nodes or {}) do
    if node.capabilities then
      return node.capabilities
    end
  end
  return nil
end

local function request_with_selected_model(request, model_name)
  local out = {}
  for key, value in pairs(request or {}) do
    out[key] = value
  end
  out.model = model_name
  return out
end

local function is_chat_completion(method, path)
  return method == "POST" and path == "/v1/chat/completions"
end

local function parse_job_path(path)
  local job_id = string.match(path, "^/v1/jobs/([^/]+)$")
  if job_id then
    return job_id, ""
  end
  job_id = string.match(path, "^/v1/jobs/([^/]+)/result$")
  if job_id then
    return job_id, "/result"
  end
  return nil, nil
end

local function public_status(client)
  local nodes, err = client:fetch_nodes()
  if not nodes then
    return nil, err
  end
  local result = { service = "kong-ollama-agent-router", nodes = {} }
  for _, node in ipairs(nodes) do
    result.nodes[#result.nodes + 1] = {
      id = node.id,
      baseUrl = node.base_url,
      capabilitiesStatus = node.capabilities and node.capabilities.status or "unavailable",
      runtimeStatus = node.runtime and node.runtime.status or "unavailable",
      ollamaReachable = node.runtime and node.runtime.ollama and node.runtime.ollama.reachable or false,
      models = node.capabilities and #(node.capabilities.models or {}) or 0,
      queues = node.runtime and node.runtime.queues or nil,
      gpu = node.runtime and node.runtime.gpu or nil,
    }
  end
  result.status = #result.nodes > 0 and "ok" or "unavailable"
  return result
end

function KongOllamaRouterHandler:access(conf)
  local method = kong.request.get_method()
  local path = kong.request.get_path()
  local client = NodeRouterClient.new(conf)

  if path == "/health" then
    return kong.response.exit(200, { status = "ok", service = "kong-ollama-agent-router" })
  end

  if method == "GET" and (path == "/v1/router/status" or path == "/v1/router/models" or path == "/v1/router/gpu") then
    local status, err = public_status(client)
    if not status then
      return kong.response.exit(503, error_body(err))
    end
    return kong.response.exit(200, status)
  end

  local job_id, job_suffix = parse_job_path(path)
  if job_id and (method == "GET" or method == "DELETE") then
    local result, err, status = client:proxy_job(method, job_id, job_suffix)
    if not result then
      return kong.response.exit(status or 502, error_body(err))
    end
    return kong.response.exit(status or 200, result)
  end

  if not is_chat_completion(method, path) then
    return
  end

  local request = kong.request.get_body() or {}
  if request.stream then
    return kong.response.exit(400, error_body("Streaming is not supported by kong-ollama-agent-router v1"))
  end
  if type(request.messages) ~= "table" or #request.messages == 0 then
    return kong.response.exit(400, error_body("messages must be a non-empty array"))
  end

  local nodes, err = client:fetch_nodes()
  if not nodes then
    return kong.response.exit(503, error_body(err))
  end

  local default_capabilities = first_capabilities(nodes)
  local router = router_engine.normalize_router_metadata(default_capabilities, request.router)
  strip_client_model_overrides(conf, router)

  local classification = classifier.classify(request, router.taskType)
  local decision = router_engine.decide({
    request = request,
    router = router,
    classification = classification,
    nodes = nodes,
  })

  if decision.type == "reject" then
    return kong.response.exit(decision.statusCode or 503, error_body(decision.reason))
  end

  local selected_request = request_with_selected_model(request, decision.model.name)
  local priority = router.priority

  if decision.type == "async" then
    local job, job_err, status = client:create_job(decision.target, selected_request, classification, decision, priority)
    if not job then
      return kong.response.exit(status or 502, error_body(job_err))
    end
    return kong.response.exit(202, response.async_response(job, decision, classification))
  end

  local execution, exec_err, status = client:execute(decision.target, selected_request, {
    score = decision.score,
    reason = decision.reason,
    classification = classification,
  }, priority)
  if not execution then
    return kong.response.exit(status or 502, error_body(exec_err))
  end

  local router_metadata = response.sync_router_metadata(decision, classification, execution)
  return kong.response.exit(200, response.with_router_metadata(execution.result, router_metadata))
end

return KongOllamaRouterHandler
