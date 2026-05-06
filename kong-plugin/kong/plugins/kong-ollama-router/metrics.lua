local _M = {}

function _M.decision_labels(decision, classification)
  return {
    type = decision and decision.type or "unknown",
    task_type = classification and classification.taskType or "unknown",
    node = decision and decision.target and decision.target.node and decision.target.node.id or "none",
    model = decision and decision.model and decision.model.name or "none",
  }
end

return _M
