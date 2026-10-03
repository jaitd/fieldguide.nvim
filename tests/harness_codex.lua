-- The Codex profile: the command it builds, what it keeps out, and what it
-- needs inside the agent sandbox.
--
--   nvim -l tests/harness_codex.lua
--
-- Nothing is started and Codex need not be installed: the binary is found in
-- npm- and pnpm-shaped trees built here, with a native stand-in.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

-- State goes somewhere disposable, never the real stdpath("state").
local scratch = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
scratch = vim.uv.fs_realpath(scratch)
vim.env.XDG_STATE_HOME = scratch .. "/state"

local cfg = require("fieldguide.config")
cfg.setup({})
local h = require("fieldguide.harness.codex")

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

-- A Codex home with a login in it, standing in for ~/.codex.
local user_home = scratch .. "/user-codex"
vim.fn.mkdir(user_home, "p")
vim.fn.writefile({ '{"tokens":"t"}' }, user_home .. "/auth.json")
vim.env.CODEX_HOME = user_home
for _, name in ipairs(h.inherited) do
  vim.env[name] = nil
end

local o = {
  root = root,
  config_dir = "/cfg",
  doc_roots = { "/docs" },
  system_prompt = root .. "/prompt/system.md",
  mcp_socket = "/run/fg/mcp.sock",
  model = "gpt-5.6-luna",
}

local function flag(argv, name)
  for i, a in ipairs(argv) do
    if a == name then
      return argv[i + 1]
    end
  end
end
local function config(argv, key)
  for i, a in ipairs(argv) do
    if a == "-c" and vim.startswith(argv[i + 1] or "", key .. "=") then
      return argv[i + 1]:sub(#key + 2)
    end
  end
end

io.write("argv\n")
do
  local argv = h.argv(o)
  check("one prompt per process, as JSON", argv[2] == "exec" and vim.tbl_contains(argv, "--json"))
  check("the prompt comes on stdin", argv[#argv] == "-")
  for _, f in ipairs({
    "--ignore-user-config",
    "--ignore-rules",
    "--skip-git-repo-check",
    "--dangerously-bypass-hook-trust",
  }) do
    check(("%s"):format(f), vim.tbl_contains(argv, f))
  end
  check("Codex's own sandbox is off: ours is the boundary", config(argv, "sandbox_mode") == '"danger-full-access"')
  check("nothing waits on an approval nobody will see", config(argv, "approval_policy") == '"never"')
  check("no web", config(argv, "web_search") == '"disabled"')
  check("no AGENTS.md from the config tree", config(argv, "project_doc_max_bytes") == "0")
  check("the model is passed through", flag(argv, "-m") == "gpt-5.6-luna")

  local prompt = table.concat(vim.fn.readfile(o.system_prompt), "\n")
  local di = config(argv, "developer_instructions") or ""
  check("the system prompt is ours, as a TOML string", vim.startswith(di, '"') and di:find("\\n", 1, true) ~= nil)
  check("...not a line of it lost", #di >= #prompt, ("%d < %d"):format(#di, #prompt))

  local pre, post = config(argv, "hooks.PreToolUse") or "", config(argv, "hooks.PostToolUse") or ""
  check(
    "the gate runs before every tool",
    pre:find("codex-hook.ts", 1, true) and pre:find(" pre ", 1, true) and pre:find('matcher=".*"', 1, true),
    pre
  )
  check("...and a gate that cannot start blocks", pre:find("|| exit 2", 1, true) ~= nil, pre)
  check("...on an absolute node", pre:find("command=\"'/", 1, true) ~= nil, pre)
  check("checkpoint and verify after every tool", post:find(" post ", 1, true) ~= nil, post)
  check(
    "Codex waits out the hooks' own waits on the server",
    pre:find("timeout=90", 1, true) and post:find("timeout=150", 1, true),
    pre .. post
  )

  local args = config(argv, "mcp_servers.fieldguide.args") or ""
  check(
    "our MCP server is the relay to the socket",
    args:find('"--relay"', 1, true) and args:find(o.mcp_socket, 1, true),
    args
  )

  local resumed = h.argv(vim.tbl_extend("force", o, { session = "t-42" }))
  check(
    "a later prompt resumes the thread",
    resumed[3] == "resume" and resumed[#resumed - 1] == "t-42" and resumed[#resumed] == "-",
    vim.inspect({ resumed[3], resumed[#resumed - 1] })
  )
  check(
    "...with the same posture",
    vim.tbl_contains(resumed, "--ignore-user-config") and config(resumed, "hooks.PreToolUse") == pre
  )
end

io.write("toml strings\n")
do
  check("quotes and backslashes are escaped", h.toml_string([[a "b" \c]]) == [["a \"b\" \\c"]])
  check("newlines and tabs too", h.toml_string("a\nb\tc") == [["a\nb\tc"]])
  check("other control characters by code", h.toml_string("a\1b") == [["a\u0001b"]])
end

io.write("environment\n")
do
  local env = h.env(o)
  check("a CODEX_HOME of fieldguide's own", vim.startswith(env.CODEX_HOME, h.state_dir() .. "/"), env.CODEX_HOME)
  check(
    "...whose login is a link to the user's, not a copy",
    vim.uv.fs_readlink(env.CODEX_HOME .. "/auth.json") == user_home .. "/auth.json"
  )
  check(
    "...and nothing else of the user's in it",
    #vim.fn.readdir(env.CODEX_HOME) == 1,
    vim.inspect(vim.fn.readdir(env.CODEX_HOME))
  )
  check("the write hooks are pointed at the socket", env.FIELDGUIDE_MCP_SOCKET == o.mcp_socket)
  check("and nothing in Codex's tree gets the editor's address", env.FIELDGUIDE_ADDR == "")
  check("a parent Codex session's variables are emptied", env.CODEX_THREAD_ID == "" and env.CODEX_SANDBOX == "")
  check("the hook has somewhere to keep the tree's fingerprint", env.FIELDGUIDE_HOOK_STATE ~= nil)
  -- Codex walks ~/.agents/skills, and its shell is a login shell that reads
  -- ~/.zshrc: a HOME of its own has neither.
  check(
    "a HOME of its own, empty",
    vim.startswith(env.HOME or "", h.state_dir() .. "/") and vim.uv.fs_stat(env.HOME) ~= nil,
    env.HOME
  )
  check("...which the sandbox lets it write", vim.tbl_contains(h.needs(o).rw, env.HOME))

  -- A login kept in the system keyring is keyed by the home's path.
  vim.fn.delete(user_home .. "/auth.json")
  check("with no auth.json, the user's own home", h.env(o).CODEX_HOME == user_home)
  vim.fn.writefile({ '{"tokens":"t"}' }, user_home .. "/auth.json")
end

io.write("sandbox needs\n")
do
  local needs = h.needs(o)
  local home = h.env(o).CODEX_HOME
  check("its home is writable: sessions, the thread store", vim.tbl_contains(needs.rw, home))
  check("...and the login file itself, written in place", vim.tbl_contains(needs.rw, user_home .. "/auth.json"))
  check(
    "not the rest of the user's Codex home",
    not vim.tbl_contains(needs.rw, user_home) and not vim.tbl_contains(needs.ro, user_home)
  )
  check("the hook's state is writable", vim.tbl_contains(needs.rw, h.hook_state()))
  local node = vim.uv.fs_realpath(vim.fn.exepath("node"))
  if node then
    check(
      "the node the hooks and the relay run on",
      vim.tbl_contains(needs.ro, vim.fs.dirname(vim.fs.dirname(node))),
      vim.inspect(needs.ro)
    )
  end
end

io.write("finding the binary\n")
do
  -- A native stand-in: any real executable will do for finding, not running.
  local native = vim.uv.fs_realpath("/bin/echo") or "/bin/echo"
  local uname = vim.uv.os_uname()
  local plats = {
    ["Darwin arm64"] = { "aarch64-apple-darwin", "codex-darwin-arm64" },
    ["Darwin x86_64"] = { "x86_64-apple-darwin", "codex-darwin-x64" },
    ["Linux x86_64"] = { "x86_64-unknown-linux-musl", "codex-linux-x64" },
    ["Linux aarch64"] = { "aarch64-unknown-linux-musl", "codex-linux-arm64" },
  }
  local plat = plats[uname.sysname .. " " .. uname.machine]
  if plat then
    local nm = scratch .. "/npm/node_modules/@openai"
    vim.fn.mkdir(nm .. "/codex/bin", "p")
    vim.fn.writefile({ "#!/usr/bin/env node" }, nm .. "/codex/bin/codex.js")
    local vendor = ("%s/%s/vendor/%s/bin"):format(nm, plat[2], plat[1])
    vim.fn.mkdir(vendor, "p")
    vim.uv.fs_copyfile(native, vendor .. "/codex")
    vim.uv.fs_chmod(vendor .. "/codex", tonumber("755", 8))

    local found = h.binary({ codex = nm .. "/codex/bin/codex.js" })
    check(
      "behind npm's codex.js, the native binary beside it",
      found == vim.uv.fs_realpath(vendor .. "/codex"),
      tostring(found)
    )
    check(
      "...and the sandbox binds its package",
      vim.tbl_contains(h.needs({ codex = nm .. "/codex/bin/codex.js" }).ro, vim.uv.fs_realpath(nm .. "/" .. plat[2]))
    )

    -- pnpm's shell wrapper names the script relative to itself.
    vim.fn.mkdir(scratch .. "/pnpm/bin", "p")
    local wrapper = scratch .. "/pnpm/bin/codex"
    vim.fn.writefile({
      "#!/bin/sh",
      'basedir=$(dirname "$0")',
      'exec node  "$basedir/../../npm/node_modules/@openai/codex/bin/codex.js" "$@"',
    }, wrapper)
    vim.uv.fs_chmod(wrapper, tonumber("755", 8))
    check("behind pnpm's wrapper too", h.binary({ codex = wrapper }) == found, tostring(h.binary({ codex = wrapper })))
  end
  check("a native binary is itself", h.binary({ codex = native }) == native)
  check("nothing to be found is nil", h.binary({ codex = scratch .. "/no-such-codex" }) == nil)
end

io.write("preflight\n")
do
  check(
    "refused without the MCP socket, the one way to the tools from inside",
    (h.preflight(vim.tbl_extend("force", o, { mcp_socket = false })) or ""):find("mcp_socket", 1, true) ~= nil
  )
  check(
    "refused with no sandbox to run in",
    (h.preflight(vim.tbl_extend("force", o, { sandbox = "none" })) or ""):find("not a sandbox", 1, true) ~= nil
  )
  local native = vim.uv.fs_realpath("/bin/echo") or "/bin/echo"
  check(
    "refused when the binary cannot say which Codex it is",
    (h.preflight(vim.tbl_extend("force", o, { codex = native })) or ""):find("cannot tell", 1, true) ~= nil
  )
end

vim.fn.delete(scratch, "rf")
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
