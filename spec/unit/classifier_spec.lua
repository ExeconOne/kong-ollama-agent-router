local classifier = require "kong.plugins.kong-ollama-router.classifier"

local function request(content)
  return {
    model = "auto",
    messages = {
      { role = "user", content = content },
    },
  }
end

it("classifies code review prompts", function()
  local result = classifier.classify(request("Review this TypeScript code ```const x = 1```"))
  assert_equal(result.taskType, "code_review")
  assert_equal(result.complexity, "medium")
end)

it("classifies code generation prompts", function()
  local result = classifier.classify(request("Write a JavaScript function that debounces calls"))
  assert_equal(result.taskType, "code_generate")
end)

it("respects explicit task type", function()
  local result = classifier.classify(request("hello"), "agentic_reasoning")
  assert_equal(result.taskType, "agentic_reasoning")
  assert_equal(result.complexity, "heavy")
  assert_equal(result.confidence, 1)
end)

it("extracts multimodal text parts", function()
  local result = classifier.classify({
    messages = {
      {
        role = "user",
        content = {
          { type = "text", text = "Summarize this document" },
          { type = "image_url", image_url = "ignored" },
        },
      },
    },
  })
  assert_equal(result.taskType, "summarize")
end)
