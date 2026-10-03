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

  local plugin = c.plugin[1]
  check("the gate plugin is loaded", plugin == "file://" .. root .. "/extension/harness/opencode-plugin.ts", plugin)
  check("...and exists", vim.uv.fs_stat(plugin:sub(#"file://" + 1)) ~= nil)
  check("the system prompt is ours", c.instructions[1] == o.system_prompt)

  for _, tool in ipairs({ "bash", "webfetch", "websearch", "task", "skill" }) do
    check(("%s is switched off"):format(tool), c.tools[tool] == false)
  end
  check("a shell is denied as well as hidden", c.permission.bash == "deny")
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

  check("sessions live in fieldguide's own database", env.OPENCODE_DB == h.state_dir() .. "/opencode.db")
  check("opencode's UI state is kept apart", vim.startswith(env.XDG_STATE_HOME, h.state_dir()))
  check(
    "project config, Claude Code's files and external skills are off",
    env.OPENCODE_DISABLE_PROJECT_CONFIG == "1"
      and env.OPENCODE_DISABLE_CLAUDE_CODE == "1"
      and env.OPENCODE_DISABLE_EXTERNAL_SKILLS == "1"
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
    not vim.tbl_contains(argv, "OPENCODE_CONFIG") and not vim.tbl_contains(argv, "OPENCODE_DB")
  )
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

vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
