-- The setup wizard: the checks, the questions, what is saved, and the first
-- start that asks them.
--
--   nvim -l tests/onboarding.lua
--
-- vim.ui.select and vim.ui.input are scripted, and the checks are stood in
-- for where the answer would depend on what this machine has installed.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local scratch = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
scratch = vim.uv.fs_realpath(scratch)
vim.env.XDG_STATE_HOME = scratch .. "/state"
vim.fn.mkdir(scratch .. "/cfg", "p")

local FAKE = root .. "/tests/fixtures/fake-agent.sh"
local cfg = require("fieldguide.config")
cfg.setup({ cwd = scratch .. "/cfg", cmd = FAKE })
local launch = require("fieldguide.launch")
local onboarding = require("fieldguide.onboarding")

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

-- Scripted answers, in order. A select answer is a function of the items
-- (returning the item to pick, or nil to cancel); an input answer is the text.
local answers, asked, notes = {}, {}, {}
vim.ui.select = function(items, opts, on_choice)
  table.insert(asked, { kind = "select", prompt = opts.prompt, items = items, format = opts.format_item })
  local answer = table.remove(answers, 1)
  on_choice(answer and answer(items) or nil)
end
vim.ui.input = function(opts, on_confirm)
  table.insert(asked, { kind = "input", prompt = opts.prompt, default = opts.default })
  on_confirm(table.remove(answers, 1))
end
vim.notify = function(msg, level)
  table.insert(notes, { msg = msg, level = level })
end

local function named(name)
  return function(items)
    for _, item in ipairs(items) do
      if item == name or (type(item) == "table" and item.name == name) then
        return item
      end
    end
  end
end
local function starting(prefix)
  return function(items)
    for _, item in ipairs(items) do
      if type(item) == "string" and vim.startswith(item, prefix) then
        return item
      end
    end
  end
end
local function reset(script)
  answers, asked, notes = script, {}, {}
  vim.fn.delete(launch.choice_path())
end
local function settle()
  vim.wait(200, function()
    return #answers == 0
  end, 10)
end

io.write("the checks\n")
do
  local rows = onboarding.check()
  check(
    "every harness, in order",
    vim.deep_equal(
      vim.tbl_map(function(r)
        return r.name
      end, rows),
      launch.HARNESSES
    )
  )
  check("pi is ready when its command is there", rows[1].ready and rows[1].why == nil, vim.inspect(rows[1]))
  for _, row in ipairs(rows) do
    check(("%s: ready, or says why not"):format(row.name), row.ready or (row.why or "") ~= "", vim.inspect(row))
  end
  -- A preflight that passes says nothing: that is ready, not a check that
  -- failed for no reason.
  package.loaded["fieldguide.harness.claude"] = { preflight = function() end }
  local claude = onboarding.check()[2]
  package.loaded["fieldguide.harness.claude"] = nil
  check("a harness whose preflight passes is ready", claude.ready and claude.why == nil, vim.inspect(claude))
  cfg.options.cmd = scratch .. "/no-such-pi"
  local pi = onboarding.check()[1]
  check("pi without its command is not ready, and says so", not pi.ready and pi.why:find("not on PATH", 1, true))
  -- The version the terminal sidebar has always required.
  local old_pi = scratch .. "/old-pi"
  vim.fn.writefile({ "#!/bin/sh", "echo 0.70.0" }, old_pi)
  vim.uv.fs_chmod(old_pi, tonumber("755", 8))
  cfg.options.cmd = old_pi
  pi = onboarding.check()[1]
  check(
    "a pi older than the minimum is not ready",
    not pi.ready and (pi.why or ""):find("older than the minimum 0.79.0", 1, true) ~= nil,
    vim.inspect(pi)
  )
  cfg.options.cmd = FAKE
  check(
    "a label says what is in the way, on one line",
    onboarding.label({ name = "codex", ready = false, why = "no auth.json\nmore" }, "pi")
      == "codex     Codex, sandboxed — not ready: no auth.json"
  )
end

-- From here the checks are fixed: what the wizard does with them is the test.
local real_check = onboarding.check
onboarding.check = function()
  return {
    { name = "pi", ready = true },
    { name = "claude", ready = true },
    { name = "opencode", ready = true },
    { name = "codex", ready = false, why = "Codex has no auth.json" },
  }
end

-- pi's models, as it would list them.
local pi_models = {
  { provider = "openrouter", model = "~anthropic/claude-haiku-latest" },
  { provider = "openai-codex", model = "gpt-5.5" },
}
local pi_profile = require("fieldguide.harness.pi")
pi_profile.models = function()
  return pi_models
end
local function pair(provider, model)
  return function(items)
    for _, item in ipairs(items) do
      if type(item) == "table" and item.provider == provider and item.model == model then
        return item
      end
    end
  end
end

io.write("the questions\n")
do
  local got
  reset({ named("codex"), named("claude"), "  haiku  ", starting("Not now") })
  onboarding.run(function(choice)
    got = choice
  end)
  settle()
  check("a harness that is not ready is not taken", got and got.name == "claude", vim.inspect(got))
  check("...and why is said in full before asking again", #vim.tbl_filter(function(n)
    return n.msg:find("codex is not ready: Codex has no auth.json", 1, true) ~= nil
  end, notes) == 1)
  check("the model is asked for, and trimmed", got and got.model == "haiku", vim.inspect(got))
  check(
    "...and kept",
    vim.deep_equal(launch.current(), { name = "claude", model = "haiku" }),
    vim.inspect(launch.current())
  )
  check(
    "the plugin index is offered when there is none",
    asked[#asked].kind == "select" and asked[#asked].prompt:find("plugin index", 1, true) ~= nil
  )

  -- Asked again: what was chosen is marked, and its model is the default.
  reset({ named("claude"), "" })
  vim.fn.writefile({ vim.json.encode({ name = "claude", model = "haiku" }) }, launch.choice_path())
  onboarding.run()
  local first = asked[1]
  check("the current choice is marked", first.format(first.items[2]):find("(current)", 1, true) ~= nil)
  check("...and its model offered as the default", asked[2].default == "haiku", vim.inspect(asked[2]))
  check("an empty model is the harness's own default", launch.current().model == nil)

  reset({ named("opencode"), named("opencode's own default") })
  local models = onboarding.opencode_models
  onboarding.opencode_models = function()
    return { "opencode-go/kimi-k3", "opencode-go/glm-5.3" }
  end
  onboarding.run()
  check("opencode's models are offered as a list", asked[2].kind == "select" and #asked[2].items == 3)
  check("...its own default first, and saved as no model", launch.current().model == nil)
  reset({ named("opencode"), named("opencode-go/kimi-k3") })
  onboarding.run()
  check("...or the one picked", launch.current().model == "opencode-go/kimi-k3")
  onboarding.opencode_models = models

  local called = false
  reset({})
  onboarding.run(function()
    called = true
  end)
  check("cancelled at the first question, nothing is saved", not launch.chosen())
  check("...and nothing is started", not called)
end

io.write("the first start\n")
do
  local chat = require("fieldguide.chat")
  reset({})
  chat.start()
  check("with nothing chosen, the first start asks", #asked == 1 and asked[1].prompt:find("which agent", 1, true))
  check("...and cancelled, starts nothing", not chat._state().session)

  reset({ named("pi"), pair("openai-codex", "gpt-5.5") })
  chat.start()
  settle()
  local s = chat._state().session
  check("answered, it starts what was chosen", s ~= nil and s:is_running())
  if s then
    chat.stop()
  end
  reset({})
  vim.fn.writefile({ vim.json.encode({ name = "pi" }) }, launch.choice_path())
  chat.start()
  check("once chosen, a start does not ask again", #asked == 0 and chat._state().session ~= nil)
  chat.stop()
end

io.write("pi's model\n")
do
  reset({ named("pi"), pair("openai-codex", "gpt-5.5"), starting("Not now") })
  onboarding.run()
  check("pi's models are offered from its own list", asked[2].kind == "select" and #asked[2].items == 3)
  check(
    "...and the provider is kept with the model",
    vim.deep_equal(launch.current(), { name = "pi", provider = "openai-codex", model = "gpt-5.5" }),
    vim.inspect(launch.current())
  )

  local argv_of = function(opts)
    local argv = require("fieldguide.rpc").argv(opts)
    local function flag(name)
      local i = vim.fn.index(argv, name)
      return i >= 0 and argv[i + 2] or nil
    end
    return flag("--provider"), flag("--model")
  end
  cfg.options.provider, cfg.options.model = "openrouter", "from/setup"
  local provider, model = argv_of({ provider = "openai-codex", model = "gpt-5.5" })
  check(
    "the wizard's pair is passed whole, never under setup()'s provider",
    provider == "openai-codex" and model == "gpt-5.5",
    vim.inspect({ provider, model })
  )
  provider, model = argv_of({})
  check("...and setup()'s pair when the wizard gave none", provider == "openrouter" and model == "from/setup")
  cfg.options.provider, cfg.options.model = nil, nil

  pi_models = {}
  reset({ named("pi"), starting("Not now") })
  onboarding.run()
  check(
    "a pi that lists no models is not asked for one",
    #asked == 2 and asked[2].prompt:find("plugin index", 1, true) ~= nil and launch.current().model == nil,
    vim.inspect(vim.tbl_map(function(a)
      return a.prompt
    end, asked))
  )
end

io.write("the plugin index\n")
do
  local index = require("fieldguide.index")
  local fetch = index.fetch
  local pending
  index.fetch = function(opts)
    pending = opts.on_done
  end
  local started = false
  reset({ named("claude"), "", starting("Download") })
  onboarding.run(function()
    started = true
  end)
  check("a download asked for is started", pending ~= nil)
  check("...and the session waits for it", not started)
  if pending then
    pending()
  end
  check("...then starts, with the index in place", started)
  index.fetch = fetch
end

onboarding.check = real_check
vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
