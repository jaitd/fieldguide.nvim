-- The protocol adapter, end to end against a scripted agent.
--
--   nvim -l tests/rpc.lua
--
-- No provider, no API key, no network. The fake agent emits a realistic stream
-- including the cases that break naive clients: a 20KB delta, U+2028 inside a
-- string, an unknown event, a malformed line, and a final line with no trailing
-- newline.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local cfg = require("fieldguide.config")
local events = require("fieldguide.rpc.events")
local rpc = require("fieldguide.rpc")

cfg.setup({})

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    io.write(("  ok   %s\n"):format(name))
  else
    failed = failed + 1
    io.write(("  FAIL %s\n       %s\n"):format(name, detail or ""))
  end
end

local FAKE = root .. "/tests/fixtures/fake-agent.sh"
local DELTAS = 500

---Run the fake agent to completion, collecting every event.
---@return table[], table
local function run(deltas)
  local collected = {}
  local session, err = rpc.start({
    argv = { FAKE, tostring(deltas or DELTAS) },
    cwd = root,
  })
  assert(session, err)
  session:on_event(function(e)
    table.insert(collected, e)
  end)

  -- Answer the blocking dialog the way the renderer eventually will.
  session:on_event(function(e)
    if events.needs_reply(e) then
      session:answer_ui(e.id, "Yes")
    end
  end)

  session:prompt("hello")

  -- Generous, and free: it polls for the exit event and returns the moment it
  -- arrives. A tight ceiling only makes the suite flaky when the machine is
  -- busy running the other suites alongside it, and every assertion below
  -- depends on the run having finished.
  local done = vim.wait(60000, function()
    for _, e in ipairs(collected) do
      if e.kind == "exit" then
        return true
      end
    end
    return false
  end, 20)

  return collected, { session = session, finished = done }
end

---@param collected table[]
---@param kind string
---@return table[]
local function of_kind(collected, kind)
  return vim.tbl_filter(function(e)
    return e.kind == kind
  end, collected)
end

io.write("protocol adapter\n")

local collected, meta = run(DELTAS)
check("the process runs to completion", meta.finished == true, "timed out waiting for exit")

-- Loss is the failure that matters, and the one that only shows up under load.
do
  local deltas = of_kind(collected, "text_delta")
  -- 500 small ones, one 20KB one, one with the Unicode separators, and one more
  -- after the tool call.
  check(
    ("no deltas lost under load (%d)"):format(#deltas),
    #deltas == DELTAS + 3,
    ("got %d, want %d"):format(#deltas, DELTAS + 3)
  )

  local ordered = true
  for i = 1, DELTAS do
    if deltas[i].text ~= ("tok%d "):format(i) then
      ordered = false
      break
    end
  end
  check("...and they arrive in order, intact", ordered, "sequence broke")

  local big = deltas[DELTAS + 1]
  check("a 20KB delta survives the read boundary", big and #big.text == 20000, big and #big.text or "missing")

  local uni = deltas[DELTAS + 2]
  check(
    "U+2028 / U+2029 inside a string do not split the message",
    uni and uni.text:find("mid", 1, true) ~= nil and uni.text:find("after", 1, true) ~= nil,
    uni and uni.text or "missing"
  )
end

io.write("normalisation\n")
do
  check("agent_start becomes run_start", #of_kind(collected, "run_start") == 1)
  check(
    "agent_settled becomes settled",
    #of_kind(collected, "settled") == 1,
    "the no-trailing-newline line was dropped"
  )
  check("turn boundaries survive", #of_kind(collected, "turn_start") == 1 and #of_kind(collected, "turn_end") == 1)
  check(
    "message boundaries survive",
    #of_kind(collected, "message_start") == 1 and #of_kind(collected, "message_end") == 1
  )

  local starts = of_kind(collected, "tool_start")
  local ends = of_kind(collected, "tool_end")
  check("tool execution is paired", #starts == 1 and #ends == 1, ("%d/%d"):format(#starts, #ends))
  check("...and carries the tool name", starts[1] and starts[1].tool == "nvim_state", vim.inspect(starts[1]))
  check("...and its call id, for matching", starts[1] and starts[1].tool_call_id == ends[1].tool_call_id)

  local status = of_kind(collected, "status")
  check(
    "compaction folds into status events",
    #status == 2,
    vim.inspect(vim.tbl_map(function(s)
      return s.what
    end, status))
  )
end

io.write("the awkward cases\n")
do
  -- An unrecognised event must surface as a question, not as silence.
  local unknown = of_kind(collected, "unknown")
  check("an unknown event is surfaced, not dropped", #unknown == 1, vim.inspect(unknown))
  check(
    "...naming the type so it can be added",
    unknown[1] and unknown[1].note == "some_future_event",
    vim.inspect(unknown[1])
  )

  -- A malformed line is a fact about the stream, not an exception.
  local errors = vim.tbl_filter(function(e)
    return e.kind == "error" and e.source == "protocol"
  end, collected)
  check("a malformed line is reported as data", #errors == 1, vim.inspect(errors))
  check("...and the stream continues past it", #of_kind(collected, "message_end") == 1)

  check("the session counts what it dropped", meta.session.stats.decode_errors == 1, vim.inspect(meta.session.stats))
end

io.write("a reply that ended badly\n")
do
  -- Nothing about a refusal looks like an error on the wire: the message ends
  -- normally and carries the reason as a field. Pulled out here so the renderer
  -- never has to know pi's field names to say what went wrong.
  local refused = events.normalize({
    type = "message_end",
    message = {
      role = "assistant",
      content = {},
      stopReason = "error",
      errorMessage = "Codex error: that model is not available on this account.",
    },
  })
  check("an errored message says so", refused.stop_reason == "error", tostring(refused.stop_reason))
  check(
    "...and carries the reason the provider gave",
    (refused.error or ""):find("not available", 1, true) ~= nil,
    tostring(refused.error)
  )

  local ok = events.normalize({ type = "message_end", message = { role = "assistant", stopReason = "stop" } })
  check("an ordinary reply carries no error", ok.error == nil and ok.stop_reason == "stop")

  local turn = events.normalize({
    type = "turn_end",
    message = { role = "assistant", stopReason = "length" },
    toolResults = {},
  })
  check("a turn reports its outcome too", turn.stop_reason == "length", tostring(turn.stop_reason))

  -- A backoff with nothing said is indistinguishable from a slow model.
  local retry = events.normalize({ type = "auto_retry_start", attempt = 2, maxAttempts = 3, delayMs = 4000 })
  check(
    "a retry says which attempt and how long",
    retry.text:find("2/3", 1, true) ~= nil and retry.text:find("4", 1, true) ~= nil,
    retry.text
  )
end

io.write("commands\n")
do
  local responses = of_kind(collected, "response")
  check("a sent command gets a correlated response", #responses >= 1, vim.inspect(responses))
  check(
    "...matched by id",
    responses[1] and responses[1].id ~= nil and responses[1].success == true,
    vim.inspect(responses[1])
  )
  check("...and clears from pending", #meta.session:pending() == 0, vim.inspect(meta.session:pending()))

  local ui = of_kind(collected, "ui_request")
  check("a dialog request surfaces", #ui == 1, vim.inspect(ui))
  check("...and is recognised as blocking", ui[1] and events.needs_reply(ui[1]) == true, vim.inspect(ui[1]))
  check("...while fire-and-forget would not be", not events.needs_reply({ kind = "ui_request", method = "notify" }))
end

io.write("lifecycle\n")
do
  local exits = of_kind(collected, "exit")
  check("exit is reported once", #exits == 1, vim.inspect(exits))
  check("the session knows it stopped", meta.session:is_running() == false)
  local sent, err = meta.session:prompt("too late")
  check("sending after exit fails clearly", sent == nil and err ~= nil, tostring(err))

  local start_err = select(2, rpc.start({ argv = { "definitely-not-a-real-agent-binary" } }))
  check(
    "a missing binary fails with a readable message",
    start_err ~= nil and start_err:find("PATH") ~= nil,
    tostring(start_err)
  )
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
