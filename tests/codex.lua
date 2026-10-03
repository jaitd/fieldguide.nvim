-- Codex over `codex exec --json`: the normaliser against a recorded real run,
-- and the session (a process per prompt, a thread carried between them)
-- against a scripted stand-in.
--
--   nvim -l tests/codex.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local codex = require("fieldguide.rpc.codex")

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

local function of_kind(list, kind)
  return vim.tbl_filter(function(e)
    return e.kind == kind
  end, list)
end

---@param lines table[]
local function normalize(lines)
  local n = codex.new()
  local out = {}
  for _, raw in ipairs(lines) do
    vim.list_extend(out, n:normalize(raw))
  end
  return out, n
end

-- ---------------------------------------------------------------------------
io.write("recorded session\n")

local recorded = {}
for line in io.lines(root .. "/tests/fixtures/codex-exec.jsonl") do
  table.insert(recorded, vim.json.decode(line))
end
local events, n = normalize(recorded)

do
  local starts = of_kind(events, "run_start")
  check("the run names its thread", #starts == 1 and starts[1].session_id == n.thread_id and n.thread_id ~= nil)
  check(
    "the hook-trust warning fieldguide causes is not news",
    #of_kind(events, "error") == 0,
    vim.inspect(of_kind(events, "error"))
  )
  check("nothing is left unrecognised", #of_kind(events, "unknown") == 0, vim.inspect(of_kind(events, "unknown")))

  local ends = of_kind(events, "tool_end")
  local by = {}
  for _, e in ipairs(ends) do
    by[e.tool] = by[e.tool] or {}
    table.insert(by[e.tool], e)
  end
  local bash = by.bash or {}
  check(
    "a shell call is bash, without the login shell around it",
    bash[1] and bash[1].args.command == "cat init.lua",
    vim.inspect(bash[1] and bash[1].args)
  )
  check("...with its output", bash[1] and (bash[1].text or ""):find("vim.g.x = 1", 1, true) ~= nil)
  check(
    "...and a shell write is a bash call too",
    bash[2] and bash[2].args.command:find(">> init.lua", 1, true) ~= nil,
    vim.inspect(bash[2] and bash[2].args)
  )
  local edit = (by.edit or {})[1]
  check(
    "a patch is an edit, naming its file",
    edit and edit.args.path == "/lab/cfg/init.lua",
    vim.inspect(edit and edit.args)
  )
  local state = (by.nvim_state or {})[1]
  check("our own verb goes by its own name", state ~= nil, vim.inspect(vim.tbl_keys(by)))
  check("...with its result as text", state and (state.text or ""):find("0.12.4", 1, true) ~= nil)
  check(
    "every tool start has its end",
    #of_kind(events, "tool_start") == #ends,
    ("%d starts, %d ends"):format(#of_kind(events, "tool_start"), #ends)
  )

  local text = table.concat(
    vim.tbl_map(function(e)
      return e.text
    end, of_kind(events, "text_delta")),
    ""
  )
  check(
    "the agent's words come through",
    text:find("nvim_state", 1, true) ~= nil or text:find("1.", 1, true) ~= nil,
    text:sub(1, 200)
  )
  check(
    "each message is bracketed",
    #of_kind(events, "message_start") == #of_kind(events, "message_end") and #of_kind(events, "message_start") >= 2
  )
  local turn = of_kind(events, "turn_end")[1]
  check(
    "the turn ends cleanly, with its usage",
    turn and turn.stop_reason == "stop" and turn.usage and turn.usage.output_tokens ~= nil
  )
end

io.write("the awkward cases\n")
do
  check(
    "a double-quoted shell command unwraps too",
    codex.shell_command([[/bin/bash -lc "echo 'x' >> a"]]) == "echo 'x' >> a"
  )
  check("a command with no wrapper is left alone", codex.shell_command("ls") == "ls")

  local out = normalize({
    { type = "turn.started" },
    { type = "error", message = "model overloaded" },
    { type = "turn.failed", error = { message = "model overloaded" } },
  })
  local te = of_kind(out, "turn_end")[1]
  check(
    "a failed turn is an error the panel shows",
    te and te.stop_reason == "error" and te.error == "model overloaded"
  )
  check("...once, not again as a loose error", #of_kind(out, "error") == 0)

  out = normalize({ { type = "error", message = "not logged in" } })
  check("an error before any turn is said", #of_kind(out, "error") == 1)

  out = normalize({
    {
      type = "item.completed",
      item = {
        id = "i",
        type = "mcp_tool_call",
        server = "fieldguide",
        tool = "nvim_verify",
        arguments = {},
        result = vim.NIL,
        error = { message = "editor gone" },
      },
    },
  })
  local e = of_kind(out, "tool_end")[1]
  check(
    "a failed verb is an errored tool, with the reason",
    e and e.is_error and e.text == "editor gone",
    vim.inspect(e)
  )

  out = normalize({
    {
      type = "item.completed",
      item = {
        id = "c",
        type = "command_execution",
        command = "/bin/zsh -lc false",
        aggregated_output = "",
        exit_code = 1,
      },
    },
  })
  check("a command that failed is an errored tool", of_kind(out, "tool_end")[1].is_error == true)

  out = normalize({
    {
      type = "item.completed",
      item = { id = "w", type = "file_change", changes = { { path = "/c/new.lua", kind = "add" } } },
    },
  })
  check("a new file is a write", of_kind(out, "tool_end")[1].tool == "write")

  out = normalize({
    {
      type = "item.completed",
      item = { id = "o", type = "mcp_tool_call", server = "github", tool = "issues", arguments = {} },
    },
  })
  check("another server's tool is named with its server", of_kind(out, "tool_end")[1].tool == "github.issues")
end

-- ---------------------------------------------------------------------------
io.write("session\n")

local FAKE = root .. "/tests/fixtures/fake-codex.sh"

---@return fieldguide.CodexSession, table[] events, table[] launches
local function session(opts)
  local launches = {}
  local s = codex.start(vim.tbl_extend("force", {
    cwd = root,
    launch = function(thread)
      table.insert(launches, thread or false)
      local argv = { FAKE, "exec", "--json" }
      if thread then
        vim.list_extend(argv, { "resume", thread })
      end
      table.insert(argv, "-")
      return argv, {}
    end,
  }, opts or {}))
  local got = {}
  s:on_event(function(e)
    table.insert(got, e)
  end)
  return s, got, launches
end

local function wait_settled(got, count)
  return vim.wait(20000, function()
    return #of_kind(got, "settled") >= count
  end, 20)
end

do
  local s, got, launches = session()
  s:prompt("hello")
  check("a first prompt runs", wait_settled(got, 1))
  check("...in a new thread", launches[1] == false and s:thread_id() == "t-new", vim.inspect(launches))
  check("...and is answered", table
    .concat(
      vim.tbl_map(function(e)
        return e.text
      end, of_kind(got, "text_delta")),
      ""
    )
    :find("heard: hello", 1, true) ~= nil)
  check("a session between prompts is still alive", s:is_running() and not s:busy())

  s:prompt("again")
  wait_settled(got, 2)
  check("the next prompt resumes the same thread", launches[2] == "t-new", vim.inspect(launches))
  check("...and the agent sees it resumed", table
    .concat(
      vim.tbl_map(function(e)
        return e.text
      end, of_kind(got, "text_delta")),
      ""
    )
    :find("again (thread t-new)", 1, true) ~= nil)
  s:stop()
  check("a stopped session refuses prompts", select(2, s:prompt("late")) ~= nil)
end

do
  local s, got, launches = session({ session = "t-old" })
  s:prompt("one")
  local status = s:prompt("two")
  check("a prompt while one runs is queued", status == "queued", tostring(status))
  check("both run, one after the other", wait_settled(got, 2), vim.inspect(launches))
  check(
    "...the first resuming the thread it was given",
    launches[1] == "t-old" and launches[2] == "t-old",
    vim.inspect(launches)
  )
  s:stop()
end

do
  -- A subscriber that sends a prompt the moment a run settles, while another
  -- is already queued: never two Codex processes at once.
  local started, settled, overlap = 0, 0, false
  local s = codex.start({
    cwd = root,
    launch = function(thread)
      if started > settled then
        overlap = true
      end
      started = started + 1
      local argv = { FAKE, "exec", "--json" }
      if thread then
        vim.list_extend(argv, { "resume", thread })
      end
      table.insert(argv, "-")
      return argv, {}
    end,
  })
  local sent_extra = false
  s:on_event(function(e)
    if e.kind == "settled" then
      settled = settled + 1
      if not sent_extra then
        sent_extra = true
        s:prompt("three")
      end
    end
  end)
  s:prompt("one")
  s:prompt("two")
  vim.wait(20000, function()
    return settled >= 3
  end, 20)
  check(
    "a prompt sent as a run settles waits its turn behind the queue",
    not overlap and settled == 3,
    ("overlap=%s settled=%d"):format(tostring(overlap), settled)
  )
  s:stop()
end

do
  -- Stopped by a subscriber as a run settles, with a prompt already queued:
  -- nothing more is started.
  local launched = 0
  local s = codex.start({
    cwd = root,
    launch = function()
      launched = launched + 1
      return { FAKE, "exec", "--json", "-" }, {}
    end,
  })
  local settled = 0
  s:on_event(function(e)
    if e.kind == "settled" then
      settled = settled + 1
      s:stop()
    end
  end)
  s:prompt("one")
  s:prompt("two")
  vim.wait(5000, function()
    return settled >= 1
  end, 20)
  vim.wait(500)
  check("a session stopped as a run settles starts nothing more", launched == 1, ("launched=%d"):format(launched))
end

do
  -- The stream never names the model; the thread's log does, once a turn has
  -- begun, and the session says it the way an ACP agent does.
  local asked = {}
  local s, got = session({
    model_of = function(thread)
      table.insert(asked, thread)
      return "gpt-6-luna"
    end,
  })
  s:prompt("one")
  wait_settled(got, 1)
  s:prompt("two")
  wait_settled(got, 2)
  local models = of_kind(got, "model")
  check(
    "the model the thread runs on is said, once a run",
    #models == 2 and models[1].model == "gpt-6-luna",
    vim.inspect(vim.tbl_map(function(e)
      return e.model
    end, models))
  )
  check("...asked of the thread Codex started", asked[1] == "t-new", vim.inspect(asked))
  s:stop()
end

do
  -- A launch with no command to give says why, and nothing is run in its
  -- place: rpc.start with no argv would start pi.
  local s = codex.start({
    cwd = root,
    launch = function()
      return nil, "the agent sandbox is gone"
    end,
  })
  local got = {}
  s:on_event(function(e)
    table.insert(got, e)
  end)
  s:prompt("one")
  local ok = wait_settled(got, 1)
  local errors = vim.tbl_filter(function(e)
    return e.kind == "error" and e.source == "codex"
  end, got)
  check(
    "a launch that answers nil says why, and runs nothing",
    ok and #errors == 1 and errors[1].message == "the agent sandbox is gone" and #of_kind(got, "run_start") == 0,
    vim.inspect(errors)
  )
  s:stop()
end

do
  -- A queued prompt whose launch fails is reported, and the queue moves on.
  local n = 0
  local s = codex.start({
    cwd = root,
    launch = function()
      n = n + 1
      if n == 2 then
        return { root .. "/no-such-codex", "exec", "--json", "-" }, {}
      end
      return { FAKE, "exec", "--json", "-" }, {}
    end,
  })
  local got = {}
  s:on_event(function(e)
    table.insert(got, e)
  end)
  s:prompt("one")
  s:prompt("two")
  s:prompt("three")
  local ok = vim.wait(20000, function()
    return #of_kind(got, "settled") >= 3
  end, 20)
  check(
    "a launch that fails does not strand the prompts behind it",
    ok and n == 3,
    ("launches=%d settled=%d"):format(n, #of_kind(got, "settled"))
  )
  check("...and says why it failed", #vim.tbl_filter(function(e)
    return e.kind == "error" and e.source == "codex"
  end, got) == 1)
  s:stop()
end

do
  local s, got = session()
  s:prompt("be slow")
  vim.wait(3000, function()
    return #of_kind(got, "turn_start") >= 1
  end, 20)
  s:interrupt()
  check("an interrupted prompt settles", wait_settled(got, 1))
  local te = of_kind(got, "turn_end")[1]
  check("...as aborted, not as an error", te and te.stop_reason == "aborted", vim.inspect(te))
  check("...and the session takes the next prompt", s:is_running())
  s:stop()
end

do
  local s, got = session()
  s:prompt("please fail")
  wait_settled(got, 1)
  local te = of_kind(got, "turn_end")
  check("a failed turn reaches the panel once", #te == 1 and te[1].stop_reason == "error", vim.inspect(te))
  s:stop()
end

do
  local s, got = session()
  s:prompt("hello")
  wait_settled(got, 1)
  local loose = vim.tbl_filter(function(e)
    return e.kind == "error"
  end, got)
  check("Codex's own log on stderr is not an error in the panel", #loose == 0, vim.inspect(loose))

  s:prompt("please refuse this")
  wait_settled(got, 2)
  local gate = vim.tbl_filter(function(e)
    return e.kind == "error" and e.source == "gate"
  end, got)
  check("a refusal Codex only logs reaches the panel as the gate's", #gate == 1, vim.inspect(gate))
  check(
    "...in fieldguide's words, without Codex's log around them",
    gate[1] and gate[1].message == "blocked by fieldguide: the doc zone is read-only: /docs/x.txt",
    gate[1] and gate[1].message
  )

  s:prompt("now die")
  wait_settled(got, 3)
  local died = vim.tbl_filter(function(e)
    return e.kind == "error" and e.source == "codex"
  end, got)
  check("a run that dies before saying anything is reported", #died == 1, vim.inspect(died))
  check(
    "...with what it said on stderr",
    died[1] and (died[1].message or ""):find("cannot load auth", 1, true) ~= nil,
    died[1] and died[1].message
  )
  s:stop()
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
