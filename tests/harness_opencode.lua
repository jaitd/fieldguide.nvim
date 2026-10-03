-- The opencode profile: the policy it writes, and what it keeps out.
--
--   nvim -l tests/harness_opencode.lua
--
-- Nothing is started; opencode need not be installed. The live half — that
-- opencode accepts this config and the plugin gates under it — is a smoke run,
-- not a suite, because it needs a model.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

-- State goes somewhere disposable, never the real stdpath("state").
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
vim.env.XDG_STATE_HOME = scratch

local cfg = require("fieldguide.config")
cfg.setup({})
local h = require("fieldguide.harness.opencode")

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

local o = {
  root = root,
  config_dir = "/cfg",
  doc_roots = { "/share/lazy", "/runtime" },
  session_dir = scratch .. "/sessions",
  system_prompt = root .. "/prompt/system.md",
  mcp = { command = "node", args = { root .. "/extension/mcp.ts" }, env = {} },
}

io.write("config\n")
do
  local c = h.config(o)
  check("the harness is spoken to over ACP", h.protocol == "acp" and h.name == "opencode")

  -- v2's `plugins`, naming a directory: a file there is skipped with a log line.
  local plugin = c.plugins and c.plugins[1]
  check(
    "the gate plugin is loaded, by its directory",
    plugin == root .. "/extension/harness/opencode",
    tostring(plugin)
  )
  check(
    "...which opencode v2 enters through index.js",
    vim.uv.fs_stat(root .. "/extension/harness/opencode/index.js") ~= nil
  )
  check("never v1's `plugin` key", c.plugin == nil)
  check("the system prompt is ours", c.instructions[1] == o.system_prompt)

  -- v2's names: a shell is `shell`, a subagent is `subagent`.
  for _, tool in ipairs({ "shell", "webfetch", "websearch", "subagent", "skill", "question" }) do
    check(("%s is switched off"):format(tool), c.tools[tool] == false)
  end
  check("a shell is denied as well as hidden", c.permission.shell == "deny")
  check("edits are not asked about", c.permission.edit == "allow")
  check("formatters and language servers do not run", c.formatter == false and c.lsp == false)

  local ext = c.permission.external_directory
  check("every other directory is denied", ext["*"] == "deny")
  check(
    "doc roots are allowed, and everything under them",
    ext["/share/lazy"] == "allow" and ext["/runtime/**"] == "allow"
  )
  check("the config tree is not listed: it is the working directory", ext["/cfg"] == nil)

  check("no model means opencode's own default", c.model == nil)
  check("a model is passed through", h.config(vim.tbl_extend("force", o, { model = "openai/x" })).model == "openai/x")

  -- An empty Lua table would encode as [] and fail opencode's schema.
  local encoded = vim.json.encode(c)
  check("encodes with objects where opencode wants objects", encoded:find('"tools":{', 1, true) ~= nil, encoded)
end

io.write("environment\n")
do
  local env = h.env(o)
  check("the config is written where the profile says", vim.startswith(env.OPENCODE_CONFIG, h.state_dir() .. "/"))
  local text = table.concat(vim.fn.readfile(env.OPENCODE_CONFIG), "\n")
  check(
    "...and is the config above",
    vim.deep_equal(vim.json.decode(text), vim.json.decode(vim.json.encode(h.config(o))))
  )
  check("a second start reuses it", h.env(o).OPENCODE_CONFIG == env.OPENCODE_CONFIG)
  check(
    "a different config gets a different file",
    h.env(vim.tbl_extend("force", o, { model = "openai/y" })).OPENCODE_CONFIG ~= env.OPENCODE_CONFIG
  )

  -- v2 keeps the login in the sessions database: a private one has no login.
  check("sessions live in the user's own opencode database, where the login is", env.OPENCODE_DB == nil)
  check("opencode's UI state is kept apart", vim.startswith(env.XDG_STATE_HOME, h.state_dir()))
  check("project config is off", env.OPENCODE_DISABLE_PROJECT_CONFIG == "1")
  check(
    "no switch v2 does not read",
    env.OPENCODE_DISABLE_CLAUDE_CODE == nil and env.OPENCODE_DISABLE_EXTERNAL_SKILLS == nil
  )
  -- opencode v2 no longer reads OPENCODE_DISABLE_CLAUDE_CODE: it finds
  -- ~/.claude, ~/.agents and CLAUDE.md through $HOME, so $HOME is its own.
  check(
    "opencode's $HOME is its own, so ~/.claude and ~/.agents are not there to find",
    vim.startswith(env.HOME, h.state_dir() .. "/") and vim.uv.fs_stat(env.HOME) ~= nil,
    env.HOME
  )
  -- Its own directories are named outright, so the private $HOME moves none.
  local real_home = vim.uv.os_homedir()
  check(
    "credentials are not redirected: a refreshed token lands in the real file",
    env.XDG_DATA_HOME == (vim.env.XDG_DATA_HOME or (real_home .. "/.local/share")),
    env.XDG_DATA_HOME
  )
  check(
    "nor are the user's providers, or the ripgrep opencode keeps in its cache",
    env.XDG_CONFIG_HOME == (vim.env.XDG_CONFIG_HOME or (real_home .. "/.config"))
      and env.XDG_CACHE_HOME == (vim.env.XDG_CACHE_HOME or (real_home .. "/.cache"))
  )
end

-- The launch is by opencode's real path, which the sandbox binds; on a machine
-- without opencode it stays the bare name.
local OPENCODE = vim.uv.fs_realpath(vim.fn.exepath("opencode")) or "opencode"

io.write("inherited environment\n")
do
  -- This suite may itself be running under opencode or Claude Code, which is
  -- exactly the leak under test; start from a clean slate.
  for name in pairs(vim.fn.environ()) do
    if name:match("^OPENCODE_") or name == "CLAUDECODE" or name:match("^CLAUDE_CODE_") then
      vim.env[name] = nil
    end
  end
  check("nothing to unset, no wrapper", vim.deep_equal(h.argv(o), { OPENCODE, "acp" }), vim.inspect(h.argv(o)))

  vim.env.OPENCODE_PURE = "1"
  vim.env.OPENCODE_PERMISSION = '{"bash":"allow"}'
  vim.env.OPENCODE_DB = "/elsewhere/opencode.db"
  vim.env.CLAUDECODE = "1"
  vim.env.CLAUDE_CODE_ENTRYPOINT = "cli"
  local argv = h.argv(o)
  check(
    "a parent's opencode and Claude Code variables are unset, not inherited",
    vim.deep_equal(argv, {
      "env",
      "-u",
      "CLAUDECODE",
      "-u",
      "CLAUDE_CODE_ENTRYPOINT",
      "-u",
      "OPENCODE_PERMISSION",
      "-u",
      "OPENCODE_PURE",
      OPENCODE,
      "acp",
    }),
    vim.inspect(argv)
  )
  check(
    "what the profile sets itself is never unset",
    not vim.tbl_contains(argv, "OPENCODE_CONFIG") and not vim.tbl_contains(argv, "XDG_DATA_HOME")
  )
  check("nor is the user's own OPENCODE_DB, which is where their login is", not vim.tbl_contains(argv, "OPENCODE_DB"))
  vim.env.OPENCODE_DB = nil
  vim.env.OPENCODE_PURE = nil
  vim.env.OPENCODE_PERMISSION = nil
  vim.env.CLAUDECODE = nil
  vim.env.CLAUDE_CODE_ENTRYPOINT = nil
end

io.write("sandbox needs\n")
do
  local needs = h.needs()
  check("the plugin's own tree is readable", vim.tbl_contains(needs.ro, require("fieldguide.env").plugin_root()))
  check("the profile's state is writable", vim.tbl_contains(needs.rw, h.state_dir()))
  local data = vim.tbl_filter(function(p)
    return p:match("/opencode$") and p:find("share", 1, true)
  end, needs.rw)
  check("opencode's data directory, with its credentials, is writable in place", #data == 1, vim.inspect(needs.rw))
end

io.write("through the MCP socket\n")
do
  -- Sandboxed: the server runs outside on a socket, and opencode gets the relay.
  local so = vim.tbl_extend("force", o, { mcp_socket = "/run/fg/mcp.sock" })
  local relay = h.mcp(so)
  check(
    "with a socket, the MCP server opencode is given is the relay to it",
    relay.args[2] == "--relay" and relay.args[3] == "/run/fg/mcp.sock" and relay.args[1]:find("mcp.ts$") ~= nil,
    vim.inspect(relay)
  )
  check("…which is handed none of the editor's variables", vim.tbl_isempty(relay.env), vim.inspect(relay.env))
  check("without one, the server in the options is used as it is", vim.deep_equal(h.mcp(o), o.mcp))
  local env = h.env(so)
  check("the write hooks are pointed at the socket", env.FIELDGUIDE_MCP_SOCKET == "/run/fg/mcp.sock")
  check("and nothing in opencode's tree gets the editor's address", env.FIELDGUIDE_ADDR == "")
  check("without a socket, neither is set", h.env(o).FIELDGUIDE_MCP_SOCKET == nil and h.env(o).FIELDGUIDE_ADDR == nil)
end

io.write("node\n")
do
  -- The plugin runs mcp.ts on node for every write. Unbound, every write hook
  -- fails to start in the sandbox and every write is refused.
  local custom = scratch .. "/custom-node"
  vim.fn.mkdir(custom .. "/bin", "p")
  vim.fn.writefile({ "#!/bin/sh" }, custom .. "/bin/node")
  vim.uv.fs_chmod(custom .. "/bin/node", tonumber("755", 8))
  local co = vim.tbl_extend("force", o, { node = custom .. "/bin/node" })
  local real = vim.uv.fs_realpath(custom .. "/bin/node")
  check(
    "the plugin is told which node to run the hooks on",
    h.env(co).FIELDGUIDE_NODE == real,
    h.env(co).FIELDGUIDE_NODE
  )
  check(
    "…and that node's install is what the sandbox binds",
    vim.tbl_contains(h.needs(co).ro, vim.uv.fs_realpath(custom)),
    vim.inspect(h.needs(co).ro)
  )
  check("the relay runs on it too", h.mcp(vim.tbl_extend("force", co, { mcp_socket = "/s" })).command == real)
end

io.write("gate readiness\n")
do
  -- One file per launch: a second session's plugin must never vouch for a
  -- first session whose own plugin did not load.
  local a = h.env(o).FIELDGUIDE_GATE_READY
  local b = h.env(o).FIELDGUIDE_GATE_READY
  check("each launch gets its own readiness file", a ~= b and a ~= nil and b ~= nil, vim.inspect({ a, b }))
  vim.fn.writefile({ "1" }, b)
  check("another launch's file does not vouch for this one", h.gate_ready(a) ~= nil)
  check("this launch's own file does", h.gate_ready(b) == nil)
  vim.fn.writefile({ "1" }, a)
  check("...and so does the first's, once its plugin writes it", h.gate_ready(a) == nil)
  check("no file named at all is not ready", h.gate_ready(nil) ~= nil)
end

io.write("preflight\n")
do
  -- A stand-in opencode on PATH that reports the version under test.
  local bin = scratch .. "/bin"
  vim.fn.mkdir(bin, "p")
  local path = vim.env.PATH
  vim.env.PATH = bin .. ":" .. path
  local function with_version(v)
    vim.fn.writefile({ "#!/bin/sh", ('echo "%s"'):format(v) }, bin .. "/opencode")
    vim.uv.fs_chmod(bin .. "/opencode", tonumber("755", 8))
    return h.preflight(o)
  end
  check("opencode 2 is accepted", with_version("2.0.22") == nil)
  check("...with a v in front too", with_version("opencode v2.1.0") == nil)
  check(
    "opencode 1 is refused, with the version it found",
    (with_version("1.18.34") or ""):find("1.18.34", 1, true) ~= nil
  )
  check("a version that cannot be read is refused", with_version("garbage") ~= nil)
  vim.fn.delete(bin .. "/opencode")
  vim.env.PATH = bin
  check("no opencode at all is refused", h.preflight(o) ~= nil)
  vim.env.PATH = path
end

vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
