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
  check("credentials are not redirected: a refreshed token lands in the real file", env.XDG_DATA_HOME == nil)
end

io.write("inherited environment\n")
do
  -- This suite may itself be running under opencode or Claude Code, which is
  -- exactly the leak under test; start from a clean slate.
  for name in pairs(vim.fn.environ()) do
    if name:match("^OPENCODE_") or name == "CLAUDECODE" or name:match("^CLAUDE_CODE_") then
      vim.env[name] = nil
    end
  end
  check("nothing to unset, no wrapper", vim.deep_equal(h.argv(o), { "opencode", "acp" }), vim.inspect(h.argv(o)))

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
      "opencode",
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

vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
