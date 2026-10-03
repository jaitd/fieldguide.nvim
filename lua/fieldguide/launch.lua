-- Which harness the panel runs, and starting it.
--
-- pi is started as it always was: its extension talks to this editor
-- directly. The others run inside the agent sandbox, where the editor's own
-- socket is out of reach on purpose, so they get fieldguide's tools from an MCP
-- server this module starts outside it (`mcp.ts --listen`), one per editor,
-- through a relay. Each launch is then:
--
--   the harness's preflight     refused before anything is spawned
--   its argv and env            from its profile in fieldguide.harness.*
--   the agent sandbox around it with the profile's needs() in reach
--   the adapter that reads it   rpc.claude, rpc.acp (opencode), rpc.codex
--
-- Codex reads through a shell no hook can see, so it never runs without the
-- sandbox. Claude and opencode carry their own gates and run without one where
-- there is none, and say so.
--
-- The choice of harness is kept in a file under the state directory, never
-- in setup(): it is the user's answer to a question asked once, not a setting
-- that belongs in their config.

local cfg = require("fieldguide.config")

local M = {}

---In the order they are offered.
M.HARNESSES = { "pi", "claude", "opencode", "codex" }

---@return string
function M.choice_path()
  return cfg.paths().state_dir .. "/harness.json"
end

---@class fieldguide.HarnessChoice
---@field name string one of M.HARNESSES
---@field model string? the model to ask that harness for; nil is its own default
---@field provider string? pi only: the provider that model belongs to

---The harness chosen, or pi when none has been, or the file names one this
---version does not know.
---@return fieldguide.HarnessChoice
function M.current()
  local decoded
  local f = io.open(M.choice_path(), "r")
  if f then
    local text = f:read("*a")
    f:close()
    local ok, value = pcall(vim.json.decode, text)
    decoded = ok and value or nil
  end
  if type(decoded) == "table" and vim.tbl_contains(M.HARNESSES, decoded.name) then
    local function str(v)
      return type(v) == "string" and v ~= "" and v or nil
    end
    return { name = decoded.name, model = str(decoded.model), provider = str(decoded.provider) }
  end
  return { name = "pi" }
end

---The model the chosen harness is asked for: the wizard's, or for pi, the
---one setup() names when the wizard gave none. nil is the harness's own.
---@return string?
function M.model()
  local c = M.current()
  if c.name == "pi" then
    return c.model or cfg.options.model
  end
  return c.model
end

---Whether a choice has been made at all, as opposed to pi by default.
---@return boolean
function M.chosen()
  return vim.uv.fs_stat(M.choice_path()) ~= nil
end

---@param choice fieldguide.HarnessChoice
---@return boolean ok, string? err
function M.choose(choice)
  if not vim.tbl_contains(M.HARNESSES, choice.name) then
    return false, ("%q is not a harness: one of %s"):format(tostring(choice.name), table.concat(M.HARNESSES, ", "))
  end
  local path = M.choice_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- Through a rename, so an editor reading it meanwhile sees the old choice or
  -- the new one, never half of either.
  local tmp = ("%s.tmp%d"):format(path, vim.uv.os_getpid())
  if
    vim.fn.writefile({ vim.json.encode({ name = choice.name, model = choice.model, provider = choice.provider }) }, tmp)
    ~= 0
  then
    return false, "could not write " .. tmp
  end
  local ok, err = vim.uv.fs_rename(tmp, path)
  if not ok then
    return false, err
  end
  return true
end

-- ---------------------------------------------------------------------------
-- The MCP server, outside the sandbox
-- ---------------------------------------------------------------------------

---@type { proc: vim.SystemObj, socket: string, dir: string, exited: boolean }?
local server

-- A unix socket path must fit in this many bytes, NUL aside: 104 on macOS,
-- 108 on Linux.
local SOCKET_PATH_MAX = 103
local SOCKET_TAIL = "/fieldguide-XXXXXX/mcp.sock"

---A directory of the editor's own for the socket, short enough to bind: the
---first of the runtime directory, the temp directory and /tmp that leaves
---room for the socket's name. The state directory rarely does. Owner-only,
---as mkdtemp makes it.
---@return string? dir, string? err
local function socket_dir()
  for _, base in ipairs({ vim.env.XDG_RUNTIME_DIR or "", vim.uv.os_tmpdir() or "", "/tmp" }) do
    -- Resolved: on macOS $TMPDIR is under /var, a link to /private/var, and
    -- the sandbox profile names the socket by its real path.
    local real = base ~= "" and vim.uv.fs_realpath(base) or nil
    if real and #real + #SOCKET_TAIL <= SOCKET_PATH_MAX then
      local dir, err = vim.uv.fs_mkdtemp(real .. "/fieldguide-XXXXXX")
      if dir then
        return dir
      end
      if base == "/tmp" then
        return nil, err
      end
    end
  end
  return nil, "the runtime and temp directories are too long for a socket path, and /tmp is not usable"
end

---Stop the MCP server, if this editor started one.
function M.stop_server()
  if not server then
    return
  end
  local s = server
  server = nil
  if not s.exited then
    pcall(function()
      s.proc:kill("sigterm")
    end)
  end
  vim.fn.delete(s.dir, "rf")
end

---The socket of this editor's MCP server, started on first use. It lives as
---long as the editor: a pipe on its stdin takes it along if the editor dies
---without a word, and VimLeavePre stops it when it does not.
---@return string? socket, string? err
function M.mcp_socket()
  if server and not server.exited and vim.uv.fs_stat(server.socket) then
    return server.socket
  end
  M.stop_server()

  local node = vim.fn.exepath("node")
  if node == "" then
    return nil, "node is not on PATH, and fieldguide's MCP server runs on it"
  end
  local dir, err = socket_dir()
  if not dir then
    return nil, "no directory for the MCP server's socket: " .. tostring(err)
  end
  local socket = dir .. "/mcp.sock"
  local stderr = {}
  local s = { socket = socket, dir = dir, exited = false }
  local ok, proc = pcall(vim.system, {
    vim.uv.fs_realpath(node) or node,
    require("fieldguide.env").plugin_root() .. "/extension/mcp.ts",
    "--listen",
    socket,
  }, {
    -- Out here with the editor, so it gets the editor's variables: the address
    -- the verbs are run through, and the config tree it fingerprints.
    env = require("fieldguide.env").agent(),
    stdin = true,
    stderr = function(_, data)
      if data then
        table.insert(stderr, data)
      end
    end,
  }, function()
    s.exited = true
  end)
  if not ok then
    vim.fn.delete(dir, "rf")
    return nil, "could not start fieldguide's MCP server: " .. tostring(proc)
  end
  s.proc = proc
  server = s

  vim.wait(10000, function()
    return s.exited or vim.uv.fs_stat(socket) ~= nil and table.concat(stderr):find("MCP on", 1, true) ~= nil
  end, 20)
  if s.exited or not vim.uv.fs_stat(socket) then
    M.stop_server()
    local said = vim.trim(table.concat(stderr))
    return nil, "fieldguide's MCP server did not start" .. (said ~= "" and (": " .. said) or "")
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("fieldguide.launch", { clear = true }),
    callback = M.stop_server,
  })
  return socket
end

-- ---------------------------------------------------------------------------
-- Launching
-- ---------------------------------------------------------------------------

---@param choice fieldguide.HarnessChoice
---@param socket string
---@param session string?
---@return fieldguide.HarnessOpts
function M.opts(choice, socket, session)
  local p = cfg.paths()
  local root = require("fieldguide.env").plugin_root()
  return {
    root = root,
    config_dir = p.config_dir,
    doc_roots = p.doc_roots,
    system_prompt = root .. "/prompt/system.md",
    mcp_socket = socket,
    model = choice.model,
    session = session,
  }
end

---The harness's argv inside the agent sandbox. On a machine with no sandbox
---at all, a harness that can do without one runs bare and the caller is told
---why. Any other refusal stops the launch: the planner refuses when the
---editor's own address would be in reach, and running bare would put it in
---reach all the same.
---@param h table the harness profile
---@param o fieldguide.HarnessOpts
---@param argv string[]
---@return string[]? argv, string? err, string? unsandboxed why it runs without the sandbox
function M.sandboxed(h, o, argv)
  local sandbox = require("fieldguide.sandbox")
  local backend, missing = sandbox.backend(o.sandbox, "agent.sandbox", "fieldguide runs this harness sandboxed")
  if not backend then
    if h.requires_sandbox then
      return nil, missing
    end
    return argv, nil, missing
  end
  local p = cfg.paths()
  local needs = h.needs(o)
  local wrapped, err = sandbox.agent_plan(argv, {
    config_dir = p.config_dir,
    config_dir_declared = p.config_dir_declared,
    doc_roots = p.doc_roots,
    extra_ro = needs.ro,
    extra_rw = needs.rw,
    mcp_socket = o.mcp_socket,
    sandbox = o.sandbox,
  })
  if wrapped then
    return wrapped
  end
  return nil, err
end

---@param why string
local function bare(name, why)
  vim.notify(
    ("fieldguide: %s runs without the agent sandbox, on its own gate alone: %s"):format(name, why),
    vim.log.levels.WARN
  )
end

local starters = {}

function starters.claude(h, o, env)
  local argv, err, unsandboxed = M.sandboxed(h, o, h.argv(o))
  if not argv then
    return nil, err
  end
  if unsandboxed then
    bare("Claude", unsandboxed)
  end
  return require("fieldguide.rpc.claude").start({ argv = argv, cwd = o.config_dir, env = env, session = o.session })
end

function starters.opencode(h, o, env)
  local argv, err, unsandboxed = M.sandboxed(h, o, h.argv(o))
  if not argv then
    return nil, err
  end
  if unsandboxed then
    bare("opencode", unsandboxed)
  end
  local ready = env.FIELDGUIDE_GATE_READY
  return require("fieldguide.rpc.acp").start({
    argv = argv,
    cwd = o.config_dir,
    env = env,
    mcp = h.mcp(o),
    session = o.session,
    -- A session whose gate plugin never loaded is refused, not run ungated.
    ready = function()
      return h.gate_ready(ready)
    end,
  })
end

function starters.codex(h, o, env)
  -- Planned once here, so a sandbox that cannot be had is said at start
  -- rather than on the first prompt.
  local _, err = M.sandboxed(h, o, h.argv(o))
  if err then
    return nil, err
  end
  return require("fieldguide.rpc.codex").start({
    cwd = o.config_dir,
    session = o.session,
    -- One process per prompt, each resuming the thread the last one started.
    launch = function(thread)
      local each = vim.tbl_extend("force", o, { session = thread })
      local argv, why = M.sandboxed(h, each, h.argv(each))
      if not argv then
        return nil, why
      end
      return argv, vim.tbl_extend("force", require("fieldguide.env").agent(), h.env(each))
    end,
  })
end

---Start the chosen harness. The same signature as `rpc.start`, which is what
---pi still goes through.
---@param start_opts table? { session?: string } an existing session to carry on
---@return table? session, string? err
function M.start(start_opts)
  start_opts = start_opts or {}
  local choice = M.current()
  -- An explicit argv is a pi command line, as rpc.start takes it.
  if start_opts.argv then
    return require("fieldguide.rpc").start(start_opts)
  end
  if choice.name == "pi" then
    return require("fieldguide.rpc").start(
      vim.tbl_extend("keep", start_opts, { model = choice.model, provider = choice.provider })
    )
  end

  local socket, err = M.mcp_socket()
  if not socket then
    return nil, err
  end
  local h = require("fieldguide.harness." .. choice.name)
  local o = M.opts(choice, socket, start_opts.session)
  local refused = h.preflight(o)
  if refused then
    return nil, ("%s: %s"):format(choice.name, refused)
  end
  if choice.name == "codex" then
    return starters.codex(h, o)
  end
  -- The editor's variables the hooks read (the config tree, the doc roots, the
  -- verbs), with the profile's over them: an empty FIELDGUIDE_ADDR among them,
  -- so nothing in the harness's process tree is handed the editor's address.
  local env = vim.tbl_extend("force", require("fieldguide.env").agent(), h.env(o))
  return starters[choice.name](h, o, env)
end

return M
