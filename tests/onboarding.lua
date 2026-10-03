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
-- Each question is asked on the next turn of the main loop, so the wizard
-- runs on after `run` returns: let it, until the script is used up and what
-- it set off has finished.
local function settle()
  vim.wait(2000, function()
    return #answers == 0
  end, 10)
  vim.wait(100)
end
-- The wizard's progress line, kept out of the test's own output.
vim.api.nvim_echo = function() end

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
  check(
    "...and why is said in full in the question asked again",
    asked[2] and asked[2].prompt:find("codex is not ready: Codex has no auth.json", 1, true) ~= nil,
    vim.inspect(asked[2] and asked[2].prompt)
  )
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
  settle()
  local first = asked[1]
  check("the current choice is marked", first.format(first.items[2]):find("(current)", 1, true) ~= nil)
  check("...and its model offered as the default", asked[2].default == "haiku", vim.inspect(asked[2]))
  check("an empty model is the harness's own default", launch.current().model == nil)

  local models = onboarding.opencode_models
  onboarding.opencode_models = function()
    return { "opencode/fledge-alpha-free", "opencode-go/kimi-k3", "opencode-go/glm-5.3" }
  end
  reset({ named("opencode"), named("opencode-go/kimi-k3") })
  onboarding.run()
  settle()
  -- Its own default can be a provider with no login, which nothing shows.
  check(
    'opencode\'s models are offered by name, with no "own default" to fall into',
    asked[2].kind == "select"
      and #asked[2].items == 3
      and not vim.tbl_contains(asked[2].items, "opencode's own default"),
    vim.inspect(asked[2] and asked[2].items)
  )
  check("...and the one picked is kept", launch.current().model == "opencode-go/kimi-k3")
  reset({ named("opencode"), named("opencode-go/glm-5.3") })
  vim.fn.writefile({ vim.json.encode({ name = "opencode", model = "opencode-go/kimi-k3" }) }, launch.choice_path())
  onboarding.run()
  settle()
  check("the current model is offered first", asked[2].items[1] == "opencode-go/kimi-k3", vim.inspect(asked[2].items))
  check("...and another can be picked", launch.current().model == "opencode-go/glm-5.3")
  onboarding.opencode_models = models

  local called = false
  reset({})
  onboarding.run(function()
    called = true
  end)
  settle()
  check("cancelled at the first question, nothing is saved", not launch.chosen())
  check("...and nothing is started", not called)
end

io.write("a clean screen for each question\n")
do
  -- The built-in vim.ui prints each question straight after the last answer,
  -- with no newline, until Neovim stops for "Press ENTER". Each one must come
  -- after a redraw, on its own turn of the main loop.
  local trail = {}
  local cmd = vim.cmd
  vim.cmd = function(c)
    if c == "redraw" then
      table.insert(trail, "redraw")
    end
    return cmd(c)
  end
  local select, input = vim.ui.select, vim.ui.input
  local inside = false
  vim.ui.select = function(items, opts, on_choice)
    table.insert(trail, inside and "asked inside an answer" or "ask")
    inside = true
    select(items, opts, function(item)
      on_choice(item)
    end)
    inside = false
  end
  vim.ui.input = function(opts, on_confirm)
    table.insert(trail, inside and "asked inside an answer" or "ask")
    inside = true
    input(opts, on_confirm)
    inside = false
  end
  reset({ named("claude"), "haiku", starting("Not now") })
  onboarding.run()
  settle()
  vim.cmd, vim.ui.select, vim.ui.input = cmd, select, input
  local asks, clean = 0, true
  for i, step in ipairs(trail) do
    if step ~= "redraw" then
      asks = asks + 1
      clean = clean and step == "ask" and trail[i - 1] == "redraw"
    end
  end
  check("every question is asked after a redraw, on a turn of its own", asks == 3 and clean, vim.inspect(trail))
end

io.write("the first start\n")
do
  local chat = require("fieldguide.chat")
  reset({})
  chat.start()
  settle()
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
  settle()
  -- The wizard's questions only: the stand-in pi raises a dialog of its own.
  local wizard = vim.tbl_filter(function(a)
    return vim.startswith(a.prompt or "", "fieldguide:")
  end, asked)
  check(
    "once chosen, a start does not ask again",
    #wizard == 0 and chat._state().session ~= nil,
    vim.inspect({ asked = wizard, session = chat._state().session ~= nil })
  )
  chat.stop()
end

io.write("pi's model\n")
do
  reset({ named("pi"), pair("openai-codex", "gpt-5.5"), starting("Not now") })
  onboarding.run()
  settle()
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
  settle()
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
  settle()
  check("a download asked for is started", pending ~= nil)
  check("...and the session waits for it", not started)
  if pending then
    pending()
  end
  check("...then starts, with the index in place", started)
  index.fetch = fetch
end

io.write("index fetches\n")
do
  -- A `node` that takes a moment and reports the index current, so a fetch
  -- is running while a second is asked for.
  local bin = scratch .. "/slow-node"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({ "#!/bin/sh", "sleep 1", [[echo '{"status":"current"}']] }, bin .. "/node")
  vim.uv.fs_chmod(bin .. "/node", tonumber("755", 8))
  local path = vim.env.PATH
  vim.env.PATH = bin .. ":" .. path
  local index = require("fieldguide.index")
  local first, second = false, false
  index.fetch({
    quiet = true,
    on_done = function()
      first = true
    end,
  })
  index.fetch({
    quiet = true,
    on_done = function()
      second = true
    end,
  })
  check("asked while one runs, the second waits for it", not first and not second)
  vim.wait(10000, function()
    return first and second
  end, 20)
  check("...and both are told when it is over", first and second)
  vim.env.PATH = path
end

io.write("a fetch that ends as another is asked\n")
do
  -- The process's exit and the main loop's turn are moments apart. A fetch
  -- asked in between must not be released by the one that just ended while a
  -- download of its own is still going.
  local index = require("fieldguide.index")
  local system = vim.system
  local exits = {}
  vim.system = function(_, _, on_exit)
    table.insert(exits, on_exit)
    return {}
  end
  local a_done, b_done = false, false
  index.fetch({
    quiet = true,
    on_done = function()
      a_done = true
    end,
  })
  -- A's process exits: libuv calls back at once, off the main loop.
  exits[1]({ code = 0, stdout = '{"status":"current"}', stderr = "" })
  index.fetch({
    quiet = true,
    on_done = function()
      b_done = true
    end,
  })
  vim.wait(200, function()
    return a_done
  end, 10)
  local own = exits[2]
  check(
    "a waiter is never released while a download it waits on is going",
    a_done and (own == nil and b_done or (own ~= nil and not b_done)),
    vim.inspect({ a_done = a_done, b_done = b_done, spawned = #exits })
  )
  if own then
    own({ code = 0, stdout = '{"status":"current"}', stderr = "" })
    vim.wait(200, function()
      return b_done
    end, 10)
  end
  check("...and is released once it is over", b_done)
  vim.system = system
end

io.write("pi's model list\n")
do
  local real_models = require("fieldguide.harness.pi").models
  package.loaded["fieldguide.harness.pi"] = nil
  local fresh = require("fieldguide.harness.pi")
  local fake = scratch .. "/list-pi"
  local function lists(lines)
    vim.fn.writefile(vim.list_extend({ "#!/bin/sh", "cat <<'OUT'" }, vim.list_extend(lines, { "OUT" })), fake)
    vim.uv.fs_chmod(fake, tonumber("755", 8))
    cfg.options.cmd = fake
    return fresh.models()
  end
  check('"No models available." is no model', #lists({ "No models available." }) == 0)
  local models = lists({
    "provider    model                     context",
    "openrouter  ~anthropic/claude-haiku-latest  200K",
    "openai-codex  gpt-5.5  400K",
  })
  check(
    "a table's rows are its models, each with its provider",
    #models == 2 and models[2].provider == "openai-codex" and models[2].model == "gpt-5.5",
    vim.inspect(models)
  )
  cfg.options.cmd = FAKE
  package.loaded["fieldguide.harness.pi"] = nil
  require("fieldguide.harness.pi").models = real_models
end

onboarding.check = real_check
vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
