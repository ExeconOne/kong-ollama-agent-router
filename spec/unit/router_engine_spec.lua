local engine = require "kong.plugins.kong-ollama-router.router_engine"

local function model(name, opts)
  opts = opts or {}
  return {
    name = name,
    sizeGb = opts.sizeGb or 4,
    purpose = opts.purpose or {},
    priority = opts.priority or 50,
    maxConcurrent = opts.maxConcurrent or 1,
    defaultContext = 4096,
    maxContext = 8192,
    timeoutMs = 120000,
    costClass = opts.costClass or "medium",
    exclusive = opts.exclusive or false,
    allowWhenBusy = opts.allowWhenBusy ~= false,
    tags = opts.tags or {},
  }
end

local function capabilities(node_id)
  return {
    nodeId = node_id,
    status = "ok",
    version = "test",
    router = {
      defaultMode = "auto",
      syncMaxQueueTimeMs = 250,
      heavyLoadQueueDepth = 4,
      heavyLoadGpuFreeMbThreshold = 2048,
      defaultTaskType = "unknown",
    },
    gpu = {
      requireGpuOnlyByDefault = true,
      vramSafetyReserveMb = 1024,
    },
    queue = {
      defaultPriority = "normal",
      timeoutMs = 120000,
    },
    models = {
      model("B-A-M-N/vibethinker:1.5b", {
        sizeGb = 2,
        purpose = { "simple_chat", "summarize", "triage" },
        priority = 10,
        costClass = "low",
        maxConcurrent = 4,
      }),
      model("qwen2.5-coder:7b", {
        sizeGb = 4.7,
        purpose = { "code_generate", "code_fix", "tool_use" },
        priority = 20,
        maxConcurrent = 2,
        tags = { "code", "fast" },
      }),
      model("deepseek-coder:6.7b", {
        sizeGb = 3.8,
        purpose = { "code_review", "code_generate", "code_fix" },
        priority = 30,
        maxConcurrent = 2,
        tags = { "code", "review" },
      }),
      model("gpt-oss:20b", {
        sizeGb = 14,
        purpose = { "agentic_reasoning", "large_context", "tool_use" },
        priority = 100,
        costClass = "high",
        exclusive = true,
        allowWhenBusy = false,
      }),
    },
    routes = {
      simple_chat = { "B-A-M-N/vibethinker:1.5b", "qwen2.5-coder:7b" },
      code_generate = { "qwen2.5-coder:7b", "deepseek-coder:6.7b" },
      code_review = { "deepseek-coder:6.7b", "qwen2.5-coder:7b" },
      agentic_reasoning = { "gpt-oss:20b", "qwen2.5-coder:7b" },
      unknown = { "B-A-M-N/vibethinker:1.5b" },
    },
  }
end

local function runtime(node_id, opts)
  opts = opts or {}
  local queued = opts.queued or {}
  local running = opts.running or {}
  return {
    nodeId = node_id,
    status = opts.status or "ok",
    timestamp = "2026-05-06T10:00:00.000Z",
    ollama = { baseUrl = "http://127.0.0.1:11434", reachable = opts.reachable ~= false },
    gpu = opts.gpu or {
      provider = "nvidia",
      name = "test gpu",
      vramTotalMb = 20480,
      vramUsedMb = 4096,
      vramFreeMb = opts.freeMb or 16000,
      utilizationPct = 20,
    },
    loadedModels = opts.loadedModels or {},
    queues = {
      globalQueued = opts.globalQueued or 0,
      globalRunning = opts.globalRunning or 0,
      byModel = {
        { model = "B-A-M-N/vibethinker:1.5b", queued = queued["B-A-M-N/vibethinker:1.5b"] or 0, running = running["B-A-M-N/vibethinker:1.5b"] or 0, concurrency = 4 },
        { model = "qwen2.5-coder:7b", queued = queued["qwen2.5-coder:7b"] or 0, running = running["qwen2.5-coder:7b"] or 0, concurrency = 2 },
        { model = "deepseek-coder:6.7b", queued = queued["deepseek-coder:6.7b"] or 0, running = running["deepseek-coder:6.7b"] or 0, concurrency = 2 },
        { model = "gpt-oss:20b", queued = queued["gpt-oss:20b"] or 0, running = running["gpt-oss:20b"] or 0, concurrency = 1 },
      },
    },
  }
end

local function node(node_id, opts)
  opts = opts or {}
  return {
    id = node_id,
    base_url = "http://" .. node_id,
    weight = opts.weight or 100,
    capabilities = opts.capabilities or capabilities(node_id),
    runtime = opts.runtime or runtime(node_id, opts.runtime_opts),
  }
end

local function normalized(metadata)
  return engine.normalize_router_metadata(capabilities("defaults"), metadata)
end

it("normalizes metadata without duplicating node-router config in plugin config", function()
  local router = normalized({ allowAsync = false, requireGpuOnly = false, priority = "high" })
  assert_equal(router.mode, "auto")
  assert_equal(router.allowAsync, false)
  assert_equal(router.requireGpuOnly, false)
  assert_equal(router.priority, "high")
end)

it("selects the less busy node for the same model", function()
  local decision = engine.decide({
    router = normalized({ taskType = "code_review", allowAsync = false }),
    classification = { taskType = "code_review", complexity = "medium" },
    nodes = {
      node("gex44-a", { runtime_opts = { queued = { ["deepseek-coder:6.7b"] = 4 } } }),
      node("gex44-b"),
    },
  })

  assert_equal(decision.type, "sync")
  assert_equal(decision.target.node.id, "gex44-b")
  assert_equal(decision.model.name, "deepseek-coder:6.7b")
end)

it("supports qualified preferred model with node id", function()
  local decision = engine.decide({
    router = normalized({ taskType = "code_generate", preferredModels = { "gex44-b/qwen2.5-coder:7b" }, allowAsync = false }),
    classification = { taskType = "code_generate", complexity = "medium" },
    nodes = {
      node("gex44-a"),
      node("gex44-b"),
    },
  })

  assert_equal(decision.type, "sync")
  assert_equal(decision.target.node.id, "gex44-b")
  assert_equal(decision.model.name, "qwen2.5-coder:7b")
end)

it("returns async when preferred exclusive model is busy and async is allowed", function()
  local decision = engine.decide({
    router = normalized({ taskType = "agentic_reasoning", preferredModels = { "gpt-oss:20b" }, allowAsync = true }),
    classification = { taskType = "agentic_reasoning", complexity = "heavy" },
    nodes = {
      node("gex44-a", { runtime_opts = { running = { ["gpt-oss:20b"] = 1 } } }),
    },
  })

  assert_equal(decision.type, "async")
  assert_equal(decision.target.node.id, "gex44-a")
  assert_equal(decision.model.name, "gpt-oss:20b")
  assert_equal(decision.position, 1)
end)

it("rejects CPU/GPU split loaded model when GPU-only is required", function()
  local decision = engine.decide({
    router = normalized({
      taskType = "agentic_reasoning",
      requireGpuOnly = true,
      preferredModels = { "gpt-oss:20b" },
      forbiddenModels = { "qwen2.5-coder:7b" },
      allowAsync = false,
    }),
    classification = { taskType = "agentic_reasoning", complexity = "heavy" },
    nodes = {
      node("gex44-a", { runtime_opts = { loadedModels = { { name = "gpt-oss:20b", processor = "50%/50% CPU/GPU" } } } }),
    },
  })

  assert_equal(decision.type, "reject")
  assert_match(decision.reason, "gpu_only")
end)

it("returns async on heavy node load in auto mode", function()
  local decision = engine.decide({
    router = normalized({ taskType = "code_review", allowAsync = true }),
    classification = { taskType = "code_review", complexity = "medium" },
    nodes = {
      node("gex44-a", { runtime_opts = { globalQueued = 4 } }),
    },
  })

  assert_equal(decision.type, "async")
  assert_equal(decision.target.node.id, "gex44-a")
end)
