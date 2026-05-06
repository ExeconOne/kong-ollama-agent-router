local _M = {}

local priority_weights = {
  low = 10,
  normal = 50,
  high = 90,
}

_M.priority_weights = priority_weights

local function array_contains(array, value)
  if type(array) ~= "table" then
    return false
  end
  for _, item in ipairs(array) do
    if item == value then
      return true
    end
  end
  return false
end

local function index_of(array, value)
  if type(array) ~= "table" then
    return nil
  end
  for index, item in ipairs(array) do
    if item == value then
      return index
    end
  end
  return nil
end

local function copy_array(array)
  local copy = {}
  if type(array) == "table" then
    for _, item in ipairs(array) do
      copy[#copy + 1] = item
    end
  end
  return copy
end

local function split_qualified_model(value)
  if type(value) ~= "string" then
    return nil, nil
  end
  local slash = string.find(value, "/", 1, true)
  if not slash then
    return nil, value
  end
  return string.sub(value, 1, slash - 1), string.sub(value, slash + 1)
end

local function model_for(capabilities, name)
  for _, model in ipairs(capabilities.models or {}) do
    if model.name == name then
      return model
    end
  end
  return nil
end

local function runtime_model_state(runtime, model_name)
  for _, loaded in ipairs(runtime.loadedModels or {}) do
    if loaded.name == model_name then
      return loaded
    end
  end
  return nil
end

local function model_counter(runtime, model_name, field)
  local queues = runtime.queues or {}
  for _, item in ipairs(queues.byModel or {}) do
    if item.model == model_name then
      return tonumber(item[field]) or 0
    end
  end
  return 0
end

local function route_for(capabilities, task_type)
  local routes = capabilities.routes or {}
  return routes[task_type] or routes.unknown or {}
end

local function target_key(node_id, model_name)
  return tostring(node_id) .. "/" .. tostring(model_name)
end

local function forbidden_target(router, node_id, model_name)
  for _, forbidden in ipairs(router.forbiddenModels or {}) do
    local forbidden_node, forbidden_model = split_qualified_model(forbidden)
    if forbidden_model == model_name and (not forbidden_node or forbidden_node == node_id) then
      return true
    end
  end
  return false
end

local function preferred_index(router, node_id, model_name)
  for index, preferred in ipairs(router.preferredModels or {}) do
    local preferred_node, preferred_model = split_qualified_model(preferred)
    if preferred_model == model_name and (not preferred_node or preferred_node == node_id) then
      return index
    end
  end
  return nil
end

local function add_candidate(names, name)
  if type(name) == "string" and name ~= "" then
    names[name] = true
  end
end

local function build_candidates_for_node(node, router, classification)
  local capabilities = node.capabilities or {}
  local names = {}

  for _, preferred in ipairs(router.preferredModels or {}) do
    local preferred_node, preferred_model = split_qualified_model(preferred)
    if not preferred_node or preferred_node == node.id then
      add_candidate(names, preferred_model)
    end
  end

  for _, name in ipairs(route_for(capabilities, classification.taskType)) do
    add_candidate(names, name)
  end

  for _, model in ipairs(capabilities.models or {}) do
    if array_contains(model.purpose, classification.taskType) or array_contains(model.tags, classification.taskType) then
      add_candidate(names, model.name)
    end
  end

  local candidates = {}
  for name, _ in pairs(names) do
    local model = model_for(capabilities, name)
    if model and not forbidden_target(router, node.id, model.name) then
      candidates[#candidates + 1] = {
        node = node,
        model = model,
        key = target_key(node.id, model.name),
      }
    end
  end
  return candidates
end

local function block_reason(target, router)
  local node = target.node
  local model = target.model
  local runtime = node.runtime or {}
  local capabilities = node.capabilities or {}
  local gpu_policy = capabilities.gpu or {}

  if router.requireGpuOnly then
    local gpu = runtime.gpu
    local loaded = runtime_model_state(runtime, model.name)
    local processor = string.lower(tostring(loaded and loaded.processor or ""))
    if not gpu or tonumber(gpu.vramTotalMb or 0) <= 0 then
      return "gpu_only"
    end
    if processor ~= "" and string.find(processor, "cpu", 1, true) and not string.find(processor, "100% gpu", 1, true) then
      return "gpu_only"
    end
    local free_mb = tonumber(gpu.vramFreeMb or gpu.vramTotalMb or 0)
    local reserve_mb = tonumber(gpu_policy.vramSafetyReserveMb or 0)
    if (tonumber(model.sizeGb or 0) * 1024 + reserve_mb) > free_mb and not loaded then
      return "gpu_only"
    end
  end

  local running = model_counter(runtime, model.name, "running")
  if (model.exclusive and running > 0) or (not model.allowWhenBusy and running >= tonumber(model.maxConcurrent or 1)) then
    return "busy"
  end
  return nil
end

local function score_target(target, router, classification)
  local node = target.node
  local model = target.model
  local capabilities = node.capabilities or {}
  local runtime = node.runtime or {}
  local route = route_for(capabilities, classification.taskType)
  local route_index = index_of(route, model.name)
  local loaded = runtime_model_state(runtime, model.name) ~= nil
  local queue_depth = model_counter(runtime, model.name, "queued")
  local running = model_counter(runtime, model.name, "running")
  local preferred_idx = preferred_index(router, node.id, model.name)
  local gpu = runtime.gpu or {}
  local gpu_policy = capabilities.gpu or {}
  local free_mb = tonumber(gpu.vramFreeMb or gpu.vramTotalMb or 0)
  local required_mb = tonumber(model.sizeGb or 0) * 1024 + tonumber(gpu_policy.vramSafetyReserveMb or 0)

  local score = 100 + tonumber(model.priority or 0)
  if route_index then
    score = score + math.max(0, 50 - (route_index - 1) * 8)
  end
  if array_contains(model.purpose, classification.taskType) then
    score = score + 25
  end
  if array_contains(model.tags, classification.taskType) then
    score = score + 15
  end
  if preferred_idx then
    score = score + 80 - (preferred_idx - 1) * 10
  end
  if loaded then
    score = score + 20
  end
  if classification.complexity == "heavy" and model.costClass == "high" then
    score = score + 20
  end
  if classification.complexity == "light" and model.costClass == "low" then
    score = score + 15
  end
  if free_mb > required_mb then
    score = score + math.min(25, (free_mb - required_mb) / 512)
  elseif free_mb > 0 and free_mb < required_mb then
    score = score - 60
  end
  score = score - queue_depth * 18
  score = score - running * 25
  if model.exclusive then
    score = score - running * 80
  end
  score = score + tonumber(node.weight or 0) / 10
  if runtime.status == "degraded" then
    score = score - 35
  end

  return {
    target = target,
    score = score,
    reason = string.format("Selected %s on %s for %s with score %.1f", model.name, node.id, classification.taskType, score),
  }
end

local function queue_position(target)
  return model_counter(target.node.runtime or {}, target.model.name, "queued") + 1
end

local function total_node_queue_depth(runtime)
  local queues = runtime and runtime.queues or {}
  if queues.globalQueued ~= nil then
    return tonumber(queues.globalQueued) or 0
  end
  local total = 0
  for _, item in ipairs(queues.byModel or {}) do
    total = total + (tonumber(item.queued) or 0)
  end
  return total
end

local function is_node_heavy(target)
  local capabilities = target.node.capabilities or {}
  local runtime = target.node.runtime or {}
  local router_cfg = capabilities.router or {}
  local queue_threshold = tonumber(router_cfg.heavyLoadQueueDepth or 0)
  local gpu_threshold = tonumber(router_cfg.heavyLoadGpuFreeMbThreshold or 0)
  if queue_threshold > 0 and total_node_queue_depth(runtime) >= queue_threshold then
    return true
  end
  if runtime.gpu and gpu_threshold > 0 and tonumber(runtime.gpu.vramFreeMb or 0) < gpu_threshold then
    return true
  end
  return false
end

local function unique_fallback_models(candidates)
  local seen = {}
  local names = {}
  for _, target in ipairs(candidates) do
    if not seen[target.model.name] then
      seen[target.model.name] = true
      names[#names + 1] = target.model.name
    end
  end
  return names
end

local function preferred_busy_target(candidates, router)
  local has_preferred = #(router.preferredModels or {}) > 0
  for _, target in ipairs(candidates) do
    local is_preferred = preferred_index(router, target.node.id, target.model.name) ~= nil
    if (has_preferred and is_preferred) or (not has_preferred and target == candidates[1]) then
      if block_reason(target, router) == "busy" then
        return target
      end
    end
  end
  return nil
end

function _M.normalize_router_metadata(default_capabilities, metadata)
  metadata = metadata or {}
  local router_cfg = (default_capabilities and default_capabilities.router) or {}
  local queue_cfg = (default_capabilities and default_capabilities.queue) or {}
  local gpu_cfg = (default_capabilities and default_capabilities.gpu) or {}
  local normalized = {
    mode = metadata.mode or router_cfg.defaultMode or "auto",
    allowAsync = metadata.allowAsync ~= false,
    taskType = metadata.taskType or "auto",
    priority = metadata.priority or queue_cfg.defaultPriority or "normal",
    preferredModels = copy_array(metadata.preferredModels),
    forbiddenModels = copy_array(metadata.forbiddenModels),
    maxQueueTimeMs = metadata.maxQueueTimeMs or router_cfg.syncMaxQueueTimeMs or 0,
    maxExecutionTimeMs = metadata.maxExecutionTimeMs or queue_cfg.timeoutMs or 120000,
  }
  if metadata.requireGpuOnly ~= nil then
    normalized.requireGpuOnly = metadata.requireGpuOnly
  else
    normalized.requireGpuOnly = gpu_cfg.requireGpuOnlyByDefault == true
  end
  return normalized
end

function _M.decide(input)
  local router = input.router or {}
  local classification = input.classification or { taskType = "unknown", complexity = "medium" }
  local nodes = input.nodes or {}
  local candidates = {}

  for _, node in ipairs(nodes) do
    local runtime = node.runtime or {}
    local capabilities = node.capabilities or {}
    if capabilities.status ~= "unavailable" and runtime.status ~= "unavailable" and (runtime.ollama == nil or runtime.ollama.reachable ~= false) then
      local node_candidates = build_candidates_for_node(node, router, classification)
      for _, target in ipairs(node_candidates) do
        candidates[#candidates + 1] = target
      end
    end
  end

  if #candidates == 0 then
    return { type = "reject", statusCode = 503, reason = "No configured node/model can satisfy this request" }
  end

  local blocked = {}
  local available = {}
  for _, target in ipairs(candidates) do
    local reason = block_reason(target, router)
    if reason then
      blocked[#blocked + 1] = { target = target, blockReason = reason }
    else
      available[#available + 1] = target
    end
  end

  local scored = {}
  for _, target in ipairs(available) do
    scored[#scored + 1] = score_target(target, router, classification)
  end
  table.sort(scored, function(a, b)
    return a.score > b.score
  end)

  local fallback_models = unique_fallback_models(candidates)

  if router.mode == "async" then
    local target = scored[1] and scored[1].target or candidates[1]
    local scored_target = scored[1] or score_target(target, router, classification)
    return {
      type = "async",
      target = target,
      model = target.model,
      fallbackModels = fallback_models,
      reason = "Request explicitly requested async mode",
      score = scored_target.score,
      position = queue_position(target),
    }
  end

  local busy_preferred = preferred_busy_target(candidates, router)
  local best = scored[1]
  local heavy = best and is_node_heavy(best.target)

  if router.mode ~= "sync" and router.allowAsync and (heavy or busy_preferred) then
    local target = busy_preferred or best.target
    local scored_target = score_target(target, router, classification)
    return {
      type = "async",
      target = target,
      model = target.model,
      fallbackModels = fallback_models,
      reason = busy_preferred and "Preferred model is busy; accepted for async processing" or "Heavy load detected",
      score = scored_target.score,
      position = queue_position(target),
    }
  end

  if best then
    return {
      type = "sync",
      target = best.target,
      model = best.target.model,
      fallbackModels = fallback_models,
      reason = best.reason,
      score = best.score,
    }
  end

  if router.allowAsync and router.mode ~= "sync" then
    for _, entry in ipairs(blocked) do
      if entry.blockReason == "busy" then
        return {
          type = "async",
          target = entry.target,
          model = entry.target.model,
          fallbackModels = fallback_models,
          reason = "Selected model is busy; accepted for async processing",
          score = 0,
          position = queue_position(entry.target),
        }
      end
    end
  end

  local reasons = {}
  for _, entry in ipairs(blocked) do
    reasons[#reasons + 1] = entry.target.key .. ": " .. entry.blockReason
  end
  return { type = "reject", statusCode = 503, reason = table.concat(reasons, "; ") ~= "" and table.concat(reasons, "; ") or "No model available" }
end

return _M
