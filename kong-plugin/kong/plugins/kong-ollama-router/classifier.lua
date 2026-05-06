local _M = {}

local code_markers = {
  "typescript",
  "javascript",
  "node.js",
  "python",
  "function",
  "class ",
  "stack trace",
  "exception",
  "compile",
  "refactor",
  "pull request",
  "diff --git",
  "```",
}

local tool_markers = { "tool", "function call", "json schema", "api call", "webhook", "bash", "shell command" }
local reasoning_markers = { "plan", "architecture", "design", "debug", "investigate", "root cause", "step by step" }
local summarize_markers = { "summarize", "summary", "tl;dr", "extract key points" }
local review_markers = { "review", "audit", "risks", "find bugs", "code review" }
local fix_markers = { "fix", "bug", "failing test", "patch", "regression" }
local generate_markers = { "write", "implement", "create", "generate", "build" }

local explicit_heavy_tasks = {
  agentic_reasoning = true,
  large_context = true,
}

local function contains_any(text, markers)
  for _, marker in ipairs(markers) do
    if string.find(text, marker, 1, true) then
      return true
    end
  end
  return false
end

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local max_index = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    if key > max_index then
      max_index = key
    end
  end
  return max_index > 0
end

local function content_to_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return tostring(content or "")
  end
  if is_array(content) then
    local parts = {}
    for _, part in ipairs(content) do
      if type(part) == "string" then
        parts[#parts + 1] = part
      elseif type(part) == "table" and part.text ~= nil then
        parts[#parts + 1] = tostring(part.text)
      end
    end
    return table.concat(parts, "\n")
  end
  if content.text ~= nil then
    return tostring(content.text)
  end
  return ""
end

function _M.extract_message_text(request)
  local messages = request and request.messages or {}
  local parts = {}
  for _, message in ipairs(messages) do
    parts[#parts + 1] = content_to_text(message.content)
  end
  return table.concat(parts, "\n")
end

local function classify_complexity(text, task_type, token_estimate)
  if task_type == "large_context" or task_type == "agentic_reasoning" or token_estimate > 12000 then
    return "heavy"
  end
  if token_estimate > 3000 or string.find(text, "architecture", 1, true) or string.find(text, "debug", 1, true) then
    return "medium"
  end
  if string.sub(task_type, 1, 5) == "code_" or task_type == "tool_use" then
    return "medium"
  end
  return "light"
end

function _M.classify(request, explicit_task_type)
  if explicit_task_type and explicit_task_type ~= "auto" then
    return {
      taskType = explicit_task_type,
      complexity = explicit_heavy_tasks[explicit_task_type] and "heavy" or "medium",
      requiresLargeContext = explicit_task_type == "large_context",
      requiresToolUse = explicit_task_type == "tool_use",
      confidence = 1,
    }
  end

  local text = string.lower(_M.extract_message_text(request))
  local token_estimate = math.ceil(#text / 4)
  local has_code = contains_any(text, code_markers)
  local requires_tool_use = contains_any(text, tool_markers)
  local requires_large_context = token_estimate > 12000
    or string.find(text, "large context", 1, true) ~= nil
    or string.find(text, "entire repository", 1, true) ~= nil

  local task_type = "simple_chat"
  local confidence = 0.55

  if requires_large_context then
    task_type = "large_context"
    confidence = 0.8
  elseif requires_tool_use then
    task_type = "tool_use"
    confidence = 0.75
  elseif contains_any(text, review_markers) and has_code then
    task_type = "code_review"
    confidence = 0.82
  elseif contains_any(text, fix_markers) and has_code then
    task_type = "code_fix"
    confidence = 0.8
  elseif contains_any(text, generate_markers) and has_code then
    task_type = "code_generate"
    confidence = 0.78
  elseif contains_any(text, summarize_markers) then
    task_type = "summarize"
    confidence = 0.86
  elseif contains_any(text, reasoning_markers) and (#text > 1200 or string.find(text, "multi-step", 1, true)) then
    task_type = "agentic_reasoning"
    confidence = 0.72
  elseif #text < 180 and (string.find(text, "classify", 1, true) or string.find(text, "route", 1, true) or string.find(text, "triage", 1, true)) then
    task_type = "triage"
    confidence = 0.7
  end

  return {
    taskType = task_type,
    complexity = classify_complexity(text, task_type, token_estimate),
    requiresLargeContext = requires_large_context,
    requiresToolUse = requires_tool_use,
    confidence = confidence,
  }
end

return _M
