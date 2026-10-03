-- The launcher: which harness is chosen, the MCP server it starts outside the
-- sandbox, and a whole launch through it.
--
--   nvim -l tests/launch.lua
--
-- No agent is needed: Claude is the stand-in in fixtures/fake-claude.sh, found
-- on PATH as `claude`, and run inside the real agent sandbox when this machine
-- has one.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

-- State goes somewhere disposable, never the real stdpath("state").
local scratch = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
scratch = vim.uv.fs_realpath(scratch)
vim.env.XDG_STATE_HOME = scratch .. "/state"
local config_dir = scratch .. "/cfg"
vim.fn.mkdir(config_dir, "p")
vim.fn.writefile({ "vim.g.x = 1" }, config_dir .. "/init.lua")

local cfg = require("fieldguide.config")
cfg.setup({ cwd = config_dir, cmd = root .. "/tests/fixtures/fake-agent.sh" })
local launch = require("fieldguide.launch")

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

io.write("the choice\n")
do
  check("nothing chosen is pi", launch.current().name == "pi" and not launch.chosen())
  local ok = launch.choose({ name = "claude", model = "haiku" })
  check("a choice is kept", ok and launch.chosen())
  local c = launch.current()
  check("...and read back, with its model", c.name == "claude" and c.model == "haiku", vim.inspect(c))
  check(
    "...in the state directory",
    vim.startswith(launch.choice_path(), cfg.paths().state_dir .. "/"),
    launch.choice_path()
  )
  local refused, err = launch.choose({ name = "gpt" })
  check("a harness that does not exist is refused", not refused and (err or ""):find("pi, claude", 1, true) ~= nil, err)
  check("...and the choice before it stands", launch.current().name == "claude")
  vim.fn.writefile({ '{"name":"gpt"}' }, launch.choice_path())
  check("a file naming an unknown harness is pi", launch.current().name == "pi")
  vim.fn.writefile({ "{not json" }, launch.choice_path())
  check("...and so is one that does not parse", launch.current().name == "pi")
  vim.fn.delete(launch.choice_path())
end

io.write("pi\n")
do
  local s, err = launch.start({})
  check("pi starts as it always did", s ~= nil and s:is_running(), tostring(err))
  if s then
    s:stop()
  end
end

io.write("the MCP server\n")
local socket
do
  local err
  socket, err = launch.mcp_socket()
  check("starts, and says where", socket ~= nil and vim.uv.fs_stat(socket) ~= nil, tostring(err))
  socket = socket or ""
  check("...on a path short enough to bind", #socket <= 103, ("%d bytes: %s"):format(#socket, socket))
  local dir = vim.uv.fs_stat(vim.fs.dirname(socket))
  check("...in a directory that is the user's alone", dir and bit.band(dir.mode, tonumber("077", 8)) == 0)
  check("the same server is used again", launch.mcp_socket() == socket)
  local relay = vim
    .system({ "node", root .. "/extension/mcp.ts", "--relay", socket }, {
      stdin = vim.json.encode({ jsonrpc = "2.0", id = 1, method = "tools/list" }) .. "\n",
      text = true,
    })
    :wait(20000)
  check(
    "...and answers through the relay",
    (relay.stdout or ""):find("nvim_state", 1, true) ~= nil,
    (relay.stdout or "") .. (relay.stderr or "")
  )
end

io.write("a launch\n")
do
  -- `claude` on PATH is the stand-in, and nothing else is but node and the
  -- system: a real Claude found further along would be started for real.
  local bin = scratch .. "/bin"
  vim.fn.mkdir(bin, "p")
  vim.uv.fs_symlink(root .. "/tests/fixtures/fake-claude.sh", bin .. "/claude")
  vim.uv.fs_symlink(vim.uv.fs_realpath(vim.fn.exepath("node")), bin .. "/node")
  vim.env.PATH = bin .. ":/usr/bin:/bin:/usr/sbin:/sbin"
  launch.choose({ name = "claude" })

  local warned = {}
  local notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(warned, { msg = msg, level = level })
  end
  local s, err = launch.start({})
  vim.notify = notify
  check("the chosen harness is the one started", s ~= nil and s.session_id ~= nil, tostring(err))
  local sandboxed = require("fieldguide.sandbox").backend(nil, "agent.sandbox", "test") ~= nil
  check(
    sandboxed and "...inside the agent sandbox, without a word" or "...without a sandbox, and saying so",
    sandboxed and #warned == 0 or (#warned == 1 and warned[1].msg:find("without the agent sandbox", 1, true) ~= nil),
    vim.inspect(warned)
  )
  if s then
    local got = {}
    s:on_event(function(e)
      table.insert(got, e)
    end)
    s:prompt("hello")
    local settled = vim.wait(20000, function()
      for _, e in ipairs(got) do
        if e.kind == "settled" or e.kind == "exit" then
          return true
        end
      end
    end, 20)
    local text = table.concat(vim.tbl_map(
      function(e)
        return e.text or ""
      end,
      vim.tbl_filter(function(e)
        return e.kind == "text_delta"
      end, got)
    ))
    check("...answers a prompt", settled and text == "you said: hello", vim.inspect(got))
    s:stop()
  end

  vim.fn.delete(bin .. "/claude")
  local none, why = launch.start({})
  check("a harness that cannot be had is refused by name", none == nil and (why or ""):find("^claude: ") ~= nil, why)
  vim.fn.delete(launch.choice_path())
end

io.write("the sandbox, or not\n")
do
  local o = { mcp_socket = socket, sandbox = "no-such-sandbox" }
  local loose = {
    needs = function()
      return { ro = {}, rw = {} }
    end,
  }
  local argv, err, why = launch.sandboxed(loose, o, { "agent" })
  check("a harness with a gate of its own runs bare when there is no sandbox", argv and argv[1] == "agent" and not err)
  check("...and is told why", (why or ""):find("not a sandbox", 1, true) ~= nil, why)
  local strict = vim.tbl_extend("force", loose, { requires_sandbox = true })
  local none, refused = launch.sandboxed(strict, o, { "agent" })
  check("one that requires the sandbox is refused", none == nil and refused ~= nil, refused)
end

io.write("refusals that are not for want of a sandbox\n")
do
  local loose = {
    needs = function()
      return { ro = {}, rw = {} }
    end,
  }
  if require("fieldguide.sandbox").backend(nil, "agent.sandbox", "test") then
    -- The editor listening inside the config tree: in the agent's reach.
    local addr = config_dir .. "/editor.sock"
    vim.fn.serverstart(addr)
    local argv, err, why = launch.sandboxed(loose, { mcp_socket = socket }, { "agent" })
    vim.fn.serverstop(addr)
    check(
      "the editor's address in reach stops the launch, even for a harness with a gate of its own",
      argv == nil and (err or ""):find("editor.sock", 1, true) ~= nil and why == nil,
      vim.inspect({ argv, err, why })
    )
  end
end

io.write("a runtime directory too long for a socket\n")
do
  local long = scratch .. "/" .. string.rep("r", 90)
  vim.fn.mkdir(long, "p")
  local saved = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = long
  launch.stop_server()
  local s, err = launch.mcp_socket()
  vim.env.XDG_RUNTIME_DIR = saved
  check(
    "is passed over for one that fits",
    s ~= nil and #s <= 103 and not vim.startswith(s, long),
    tostring(s) .. " " .. tostring(err)
  )
  socket = s or socket
end

io.write("the panel\n")
do
  local chat = require("fieldguide.chat")
  local warned = {}
  local notify = vim.notify
  vim.notify = function(msg)
    table.insert(warned, msg)
  end
  launch.choose({ name = "claude", model = "haiku" })
  chat.resume({ id = "pi-session", path = scratch .. "/no-such.jsonl" })
  vim.notify = notify
  check(
    "a pi session is not resumed in another harness",
    chat._state().session == nil and #warned == 1 and warned[1]:find("pi session", 1, true) ~= nil,
    vim.inspect(warned)
  )

  chat.open()
  local winbar = function()
    return vim.wo[chat._state().out_win].winbar
  end
  check("the title names the harness and its model", winbar():find("claude · haiku", 1, true) ~= nil, winbar())
  chat.close()
  launch.choose({ name = "pi" })
  cfg.options.model = "from/setup"
  chat.open()
  check(
    "...and for pi, setup()'s model, unnamed as before",
    winbar():find("from/setup", 1, true) ~= nil and winbar():find("pi ·", 1, true) == nil,
    winbar()
  )
  chat.close()
  cfg.options.model = nil
  vim.fn.delete(launch.choice_path())
end

io.write("stopping\n")
do
  local dir = vim.fs.dirname(socket)
  launch.stop_server()
  check(
    "the server's directory goes with it",
    vim.wait(5000, function()
      return vim.uv.fs_stat(dir) == nil
    end, 20)
  )
  local again = launch.mcp_socket()
  check("and a new one starts on demand", again ~= nil and again ~= socket and vim.uv.fs_stat(again) ~= nil)
  launch.stop_server()
end

vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
