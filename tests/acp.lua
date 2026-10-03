-- The ACP adapter: pure encoders and normaliser, then end to end against a
-- scripted agent.
--
--   nvim -l tests/acp.lua
--
-- No provider, no API key, no network. The fake agent streams, asks for
-- permission, asks for a file the client never offered, replays a session, and
-- sends the same awkward lines the pi fake does.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local cfg = require("fieldguide.config")
local acp = require("fieldguide.rpc.acp")

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

---@param collected table[]
---@param kind string
---@return table[]
local function of_kind(collected, kind)
  return vim.tbl_filter(function(e)
    return e.kind == kind
  end, collected)
end

---@param collected table[]
---@return string[]
local function kinds(collected)
  return vim.tbl_map(function(e)
    return e.kind
  end, collected)
end

-- ---------------------------------------------------------------------------
io.write("encoders\n")
-- ---------------------------------------------------------------------------
do
  local init = vim.json.encode(acp.initialize(1))
  -- An empty Lua table encodes as `[]`; an agent validating its input would
  -- reject the handshake outright.
  check("no client capabilities, encoded as an object", init:find('"clientCapabilities":{}', 1, true) ~= nil, init)
  check("fs is never advertised", init:find("fs", 1, true) == nil and init:find("terminal", 1, true) == nil, init)

  local new = acp.session_new(2, "/cfg", { command = "node", args = { "mcp.ts" }, env = { B = "2", A = "1" } })
  local server = new.params.mcpServers[1]
  check("mcp servers are named fieldguide", server.name == "fieldguide", vim.inspect(server))
  check(
    "mcp env is a sorted list of pairs",
    vim.deep_equal(server.env, { { name = "A", value = "1" }, { name = "B", value = "2" } }),
    vim.inspect(server.env)
  )
  check("no mcp means an empty list", vim.json.encode(acp.mcp_servers(nil)) == "[]")

  local cancel = acp.session_cancel("s")
  check("cancel is a notification", cancel.id == nil and cancel.method == "session/cancel", vim.inspect(cancel))

  local reply = vim.json.encode(acp.result(7, nil))
  check("a null result is still a result", reply:find('"result":null', 1, true) ~= nil, reply)
end

-- ---------------------------------------------------------------------------
io.write("the model\n")
do
  local n = acp.normalizer()
  n:expect(2, "session/new")
  local options = {
    { id = "model", category = "model", type = "select", currentValue = "opencode-go/kimi-k3", options = {} },
  }
  local out = n:normalize({ jsonrpc = "2.0", id = 2, result = { sessionId = "s-1", configOptions = options } })
  check(
    "the model a new session reports is said, before the response",
    #out == 2 and out[1].kind == "model" and out[1].model == "opencode-go/kimi-k3" and out[2].kind == "response",
    vim.inspect(kinds(out))
  )
  options[1].currentValue = "opencode-go/glm-5.3"
  out = n:normalize({
    jsonrpc = "2.0",
    method = "session/update",
    params = { sessionId = "s-1", update = { sessionUpdate = "config_option_update", configOptions = options } },
  })
  check("...and a change to it", #out == 1 and out[1].kind == "model" and out[1].model == "opencode-go/glm-5.3")
  out = n:normalize({
    jsonrpc = "2.0",
    method = "session/update",
    params = { sessionId = "s-1", update = { sessionUpdate = "config_option_update", configOptions = {} } },
  })
  check("an update with no model in it is still quiet", #out == 0, vim.inspect(kinds(out)))
end

-- ---------------------------------------------------------------------------
io.write("permission policy\n")
-- ---------------------------------------------------------------------------
do
  local options = {
    { optionId = "a", kind = "allow_always" },
    { optionId = "o", kind = "allow_once" },
    { optionId = "r", kind = "reject_once" },
  }
  local outcome, granted = acp.permission_outcome({ toolCall = { kind = "edit" }, options = options })
  check("an edit is allowed once, never always", granted and outcome.optionId == "o", vim.inspect(outcome))

  for _, kind in ipairs({ "execute", "fetch", "switch_mode" }) do
    outcome, granted = acp.permission_outcome({ toolCall = { kind = kind }, options = options })
    check(("%s is refused"):format(kind), not granted and outcome.optionId == "r", vim.inspect(outcome))
  end

  -- Only "always" on offer for a kind that is granted: still not granted,
  -- because an "always" answer outlives the session inside the harness.
  outcome, granted = acp.permission_outcome({ toolCall = { kind = "edit" }, options = { options[1], options[3] } })
  check(
    "an edit offered only allow_always is cancelled, not granted for good",
    not granted and outcome.outcome == "cancelled",
    vim.inspect(outcome)
  )

  outcome, granted = acp.permission_outcome({ toolCall = { kind = "execute" }, options = { options[1] } })
  check(
    "no reject option: cancelled, never granted",
    not granted and outcome.outcome == "cancelled",
    vim.inspect(outcome)
  )
end

-- ---------------------------------------------------------------------------
io.write("tool names\n")
-- ---------------------------------------------------------------------------
do
  local cases = {
    { { title = "fieldguide_nvim_state" }, false, "nvim_state", "opencode's MCP namespace" },
    { { title = "mcp__fieldguide__nvim_docs" }, false, "nvim_docs", "Claude's MCP namespace" },
    {
      { title = "Read init.lua", _meta = { claudeCode = { toolName = "Read" } } },
      false,
      "Read",
      "claude-agent-acp's _meta",
    },
    { { title = "glob" }, false, "find", "glob renders as find" },
    { { title = "read" }, true, "read", "a known name survives a replay" },
    { { title = "Makefile" }, true, nil, "a bare file name in a replay is not a tool" },
    { { title = "tmp/cfg/init.lua" }, false, nil, "a path is never a tool" },
  }
  for _, c in ipairs(cases) do
    local got = acp.tool_name(c[1], c[2])
    check(("%s -> %s"):format(c[4], tostring(c[3])), got == c[3], tostring(got))
  end
end

-- ---------------------------------------------------------------------------
io.write("stop reasons\n")
-- ---------------------------------------------------------------------------
do
  local stop = acp.stop_reason("max_tokens")
  check("max_tokens reads as a cut-off reply", stop == "length")
  local s, err = acp.stop_reason("refusal")
  check("a refusal is an error, and says so", s == "error" and err ~= nil)
  check("cancelled is an abort", acp.stop_reason("cancelled") == "aborted")
  check("end_turn is a plain stop", acp.stop_reason("end_turn") == "stop")
end

-- ---------------------------------------------------------------------------
-- End to end.
-- ---------------------------------------------------------------------------

local FAKE = root .. "/tests/fixtures/fake-acp-agent.mjs"
local DELTAS = 300

---@param opts table? { session?: string, env?: table, prompts?: string[] }
---@return table[] events, table[] what the client sent, table meta
local function run(opts)
  opts = opts or {}
  local log = vim.fn.tempname()
  local collected = {}
  local session, err = acp.start({
    argv = { "node", FAKE, log, tostring(DELTAS) },
    cwd = root,
    env = opts.env,
    session = opts.session,
    mcp = { command = "node", args = { "mcp.ts" }, env = {} },
    ready = opts.ready,
    ready_timeout_ms = opts.ready_timeout_ms,
  })
  assert(session, err)
  session:on_event(function(e)
    table.insert(collected, e)
  end)
  for _, text in ipairs(opts.prompts or {}) do
    session:prompt(text)
  end

  local want = #(opts.prompts or {})
  local finished = vim.wait(30000, function()
    if opts.done then
      return opts.done(collected)
    end
    if want == 0 then
      return #of_kind(collected, "response") >= 2
    end
    return #of_kind(collected, "run_end") >= want
  end, 20)

  if opts.before_stop then
    opts.before_stop(session)
  end
  -- Let the last replies reach the fake's log before closing its stdin.
  vim.wait(200)
  local sent = {}
  for _, line in ipairs(vim.fn.readfile(log)) do
    local ok, msg = pcall(vim.json.decode, line)
    if ok then
      table.insert(sent, msg)
    end
  end
  session:stop()
  vim.wait(5000, function()
    return #of_kind(collected, "exit") > 0
  end, 20)
  return collected, sent, { finished = finished, session = session }
end

---@param sent table[]
---@param pred fun(m: table): boolean
---@return table?
local function find_sent(sent, pred)
  for _, m in ipairs(sent) do
    if pred(m) then
      return m
    end
  end
end

io.write("a live session\n")
local collected, sent, meta = run({
  prompts = { "hello", "again" },
  before_stop = function(s)
    s:interrupt()
  end,
})
check("both runs complete", meta.finished == true, "timed out")

do
  local order = vim.tbl_map(function(m)
    return m.method or "reply"
  end, sent)
  check(
    "handshake: initialize, then session/new, before any prompt",
    order[1] == "initialize" and order[2] == "session/new" and order[3] == "session/prompt",
    table.concat(order, ", ")
  )
  check("the resumed id is the new session's", meta.session:session_id() == "sess-new")
  local prompt = find_sent(sent, function(m)
    return m.method == "session/prompt"
  end)
  check("the prompt names the session", prompt and prompt.params.sessionId == "sess-new")

  -- The second prompt was queued while the first was running, and must wait
  -- for it: ACP has no steering, and an agent is free to reject a second one.
  local prompts, replies_before_second = 0, 0
  for _, m in ipairs(sent) do
    if m.method == "session/prompt" then
      prompts = prompts + 1
    elseif prompts == 1 and m.method == nil then
      replies_before_second = replies_before_second + 1
    end
  end
  check("a second prompt waits for the first run", prompts == 2 and replies_before_second == 3, replies_before_second)
end

do
  local deltas = of_kind(collected, "text_delta")
  -- the load, the big one, the separators, the one after the tools, the second turn
  check(("no deltas lost (%d)"):format(#deltas), #deltas == DELTAS + 4, #deltas)
  local ordered = true
  for i = 1, DELTAS do
    if deltas[i].text ~= ("tok%d "):format(i) then
      ordered = false
      break
    end
  end
  check("...in order, intact", ordered)
  check("a 20KB chunk survives", deltas[DELTAS + 1] and #deltas[DELTAS + 1].text == 20000)
  local uni = deltas[DELTAS + 2]
  check("U+2028 / U+2029 do not split a message", uni and uni.text:find("after", 1, true) ~= nil)
  check("thinking arrives as thinking", #of_kind(collected, "thinking_delta") == 1)
end

do
  local starts = of_kind(collected, "tool_start")
  local ends = of_kind(collected, "tool_end")
  check("every call starts once and ends once", #starts == 4 and #ends == 4, ("%d/%d"):format(#starts, #ends))

  local read = ends[1]
  check("the read keeps its name, not its result's title", read.tool == "read", read.tool)
  check("...with the arguments that came after it", read.args.path == "/cfg/init.lua", vim.inspect(read.args))
  check("...and its output", read.text == "vim.g.x = 1", read.text)

  check("an MCP tool renders as fieldguide's own", ends[2].tool == "nvim_state", ends[2].tool)
  check("an apply_patch reports the file it touched", ends[3].args.path == "/cfg/init.lua", vim.inspect(ends[3].args))
  check("an allowed edit completes", ends[3].is_error == false)
  check("a failed call is an error", ends[4].is_error == true and ends[4].text:find("zones", 1, true) ~= nil)
end

do
  local grant = find_sent(sent, function(m)
    return m.id == 0 and m.method == nil
  end)
  check("an edit's permission is granted once", grant and grant.result.outcome.optionId == "once", vim.inspect(grant))
  local refuse = find_sent(sent, function(m)
    return m.id == 1 and m.method == nil
  end)
  check("a shell's permission is refused", refuse and refuse.result.outcome.optionId == "reject", vim.inspect(refuse))
  local refused = vim.tbl_filter(function(e)
    return e.source == "permission"
  end, of_kind(collected, "error"))
  check("...and the refusal is said out loud", #refused == 1 and refused[1].message:find("execute", 1, true) ~= nil)

  local fs = find_sent(sent, function(m)
    return m.id == 2 and m.method == nil
  end)
  check(
    "a file read the client never offered is answered, with method-not-found",
    fs and fs.error and fs.error.code == -32601,
    vim.inspect(fs)
  )
end

do
  local unknown = of_kind(collected, "unknown")
  check(
    "a newer update surfaces as unknown",
    #unknown == 1 and unknown[1].note == "session/update.some_future_update",
    vim.inspect(vim.tbl_map(function(e)
      return e.note
    end, unknown))
  )
  local protocol = vim.tbl_filter(function(e)
    return e.source == "protocol"
  end, of_kind(collected, "error"))
  check("a malformed line is reported, not thrown", #protocol == 1)
  check("bookkeeping updates stay quiet", #of_kind(collected, "status") == 0)
end

do
  local ends = of_kind(collected, "turn_end")
  check("each prompt's response ends a turn", #ends == 2)
  check("an ordinary turn stops", ends[1] and ends[1].stop_reason == "stop")
  check("a cut-off turn says so", ends[2] and ends[2].stop_reason == "length")
  check(
    "each outcome is distinguishable from the last",
    ends[1] and ends[2] and ends[1].message.timestamp ~= ends[2].message.timestamp
  )

  -- The panel's contract: run_start opens, settled closes, and the next run's
  -- start never overtakes the last one's end.
  local seq = vim.tbl_filter(function(k)
    return k == "run_start" or k == "run_end" or k == "settled"
  end, kinds(collected))
  check(
    "run_start, run_end, settled, twice, in that order",
    table.concat(seq, " ") == "run_start run_end settled run_start run_end settled",
    table.concat(seq, " ")
  )

  local cancel = find_sent(sent, function(m)
    return m.method == "session/cancel"
  end)
  check("interrupt sends a cancel notification", cancel and cancel.id == nil and cancel.params.sessionId == "sess-new")
end

do
  local s = meta.session
  check("pi's abort is accepted as a cancel", select(2, s:send({ type = "abort" })) == nil)
  check("other pi commands are refused, not sent", select(2, s:send({ type = "get_state" })) ~= nil)
end

io.write("a resumed session\n")
do
  local events, sent2 = run({ session = "sess-old" })
  local load = find_sent(sent2, function(m)
    return m.method == "session/load"
  end)
  check("resuming loads the session", load and load.params.sessionId == "sess-old", vim.inspect(load))
  check("...rather than starting one", find_sent(sent2, function(m)
    return m.method == "session/new"
  end) == nil)

  local replayed = vim.tbl_filter(function(k)
    return k == "user" or k == "text_delta" or k == "tool_end" or k == "settled"
  end, kinds(events))
  check(
    "the replay reads as turns: user, answer, tool, closed; user, answer, closed",
    table.concat(replayed, " ") == "user text_delta tool_end settled user text_delta settled",
    table.concat(replayed, " ")
  )
  local users = of_kind(events, "user")
  check("a user message split across chunks is one message", users[1] and users[1].text == "first question")
  local tool = of_kind(events, "tool_end")[1]
  check("a replayed call is named by its shape, not its title", tool and tool.tool == "read", tool and tool.tool)
end

do
  local events, sent2 = run({ session = "sess-old", env = { FAKE_NO_LOAD = "1" } })
  check("an agent that cannot load gets a new session", find_sent(sent2, function(m)
    return m.method == "session/new"
  end) ~= nil)
  local said = vim.tbl_filter(function(e)
    return e.source == "acp"
  end, of_kind(events, "error"))
  check("...and the reader is told", #said == 1)
end

do
  -- Advertises session/load, then rejects it: the prompt waiting behind the
  -- handshake must still run, in a new session, and the reader is told.
  local events, sent3 = run({ session = "sess-gone", env = { FAKE_LOAD_FAILS = "1" }, prompts = { "still there?" } })
  check("a failed load falls back to a new session", find_sent(sent3, function(m)
    return m.method == "session/new"
  end) ~= nil)
  check("...and the queued prompt runs in it", find_sent(sent3, function(m)
    return m.method == "session/prompt" and m.params.sessionId == "sess-new"
  end) ~= nil)
  local said = vim.tbl_filter(function(e)
    return e.source == "acp" and e.message:find("session not found", 1, true) ~= nil
  end, of_kind(events, "error"))
  check("...and the reader is told why", #said == 1, vim.inspect(of_kind(events, "error")))
end

do
  -- No session to be had at all: the queued prompt is not left waiting on a
  -- handshake that will never finish. It is reported, and the run settles.
  local events = run({
    session = "sess-gone",
    env = { FAKE_LOAD_FAILS = "1", FAKE_NEW_FAILS = "1" },
    prompts = { "anyone?" },
    done = function(collected)
      return #of_kind(collected, "settled") >= 1
    end,
  })
  local said = vim.tbl_filter(function(e)
    return e.source == "acp" and e.message:find("no model configured", 1, true) ~= nil
  end, of_kind(events, "error"))
  check("no session at all is said, with the agent's reason", #said >= 1, vim.inspect(of_kind(events, "error")))
  check("...and the waiting prompt is settled, not stranded", #of_kind(events, "settled") >= 1)
end

do
  -- The harness says its gate is not in place: no prompt may reach the agent.
  local asked, again = 0, {}
  local events, sent4 = run({
    prompts = { "ungated?" },
    ready_timeout_ms = 300,
    ready = function()
      asked = asked + 1
      return "the gate plugin did not load"
    end,
    done = function(collected)
      return #of_kind(collected, "settled") >= 1
    end,
    before_stop = function(session)
      again = { session:prompt("now?") }
    end,
  })
  check("the harness is asked, until it gives up, once its session exists", asked >= 2, tostring(asked))
  check("a session that is not ready gets no prompt", find_sent(sent4, function(m)
    return m.method == "session/prompt"
  end) == nil)
  local said = vim.tbl_filter(function(e)
    return e.source == "acp" and e.message:find("gate plugin did not load", 1, true) ~= nil
  end, of_kind(events, "error"))
  check("...and the reader is told why", #said >= 1, vim.inspect(of_kind(events, "error")))
  check("...and the waiting prompt is settled", #of_kind(events, "settled") >= 1)
  check(
    "...and a later prompt is refused",
    again[1] == nil and (again[2] or ""):find("gate plugin", 1, true) ~= nil,
    vim.inspect(again)
  )
end

do
  -- Stopped on purpose while the harness is still getting ready: that is a
  -- stop, not a session that failed to start, and says nothing of the kind.
  local polls = 0
  local events = run({
    prompts = { "never mind" },
    ready_timeout_ms = 5000,
    ready = function()
      polls = polls + 1
      return "still loading"
    end,
    done = function()
      return polls >= 2
    end,
    before_stop = function(session)
      session:stop()
    end,
  })
  local refusals = vim.tbl_filter(function(e)
    return e.source == "acp" and (e.message or ""):find("still loading", 1, true) ~= nil
  end, of_kind(events, "error"))
  check("a session stopped while getting ready is not reported as refused", #refusals == 0, vim.inspect(refusals))
  check("...nor settled as a failed start", #of_kind(events, "settled") == 0, vim.inspect(of_kind(events, "settled")))
end

do
  local events = run({ prompts = { "gated" }, ready = function() end })
  check("a ready harness runs its prompt as usual", #of_kind(events, "run_end") >= 1)
end

do
  -- opencode v2 sets its plugins up a little after the session exists: a gate
  -- that is ready a moment later is waited for, not refused.
  local calls = 0
  local events, sent5 = run({
    prompts = { "soon" },
    ready = function()
      calls = calls + 1
      if calls < 4 then
        return "not yet"
      end
    end,
  })
  check("a harness ready a moment later is waited for", #of_kind(events, "run_end") >= 1, tostring(calls))
  check("...and its prompt goes in only then", find_sent(sent5, function(m)
    return m.method == "session/prompt"
  end) ~= nil and calls >= 4)
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
