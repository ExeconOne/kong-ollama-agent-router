local _M = {}

local function copy_object(value)
  local out = {}
  if type(value) == "table" then
    for key, item in pairs(value) do
      out[key] = item
    end
  end
  return out
end

function _M.with_router_metadata(result, router)
  local response
  if type(result) == "table" then
    response = copy_object(result)
  else
    response = { result = result }
  end
  response.router = router
  return response
end

function _M.sync_router_metadata(decision, classification, execution)
  return {
    mode = "sync",
    taskType = classification.taskType,
    nodeId = decision.target.node.id,
    selectedModel = decision.model.name,
    fallbackModels = decision.fallbackModels or {},
    queueTimeMs = execution.queueTimeMs or 0,
    executionTimeMs = execution.executionTimeMs or 0,
    decisionReason = decision.reason,
  }
end

function _M.async_response(job, decision, classification)
  return {
    id = job.id,
    object = "router.job",
    status = job.status or "queued",
    message = "Heavy load. Job accepted for asynchronous processing.",
    router = {
      mode = "async",
      taskType = classification.taskType,
      nodeId = job.nodeId or decision.target.node.id,
      preferredModel = job.selectedModel or decision.model.name,
      position = job.position or decision.position,
      estimatedClass = classification.complexity,
      decisionReason = decision.reason,
    },
  }
end

return _M
