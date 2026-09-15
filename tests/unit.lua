-- Dispatch table, launch flags and reload planning. No live config needed.
--
--   nvim -l tests/unit.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local api = require("fieldguide.api")
local cfg = require("fieldguide.config")
local reload = require("fieldguide.reload")
local ui = require("fieldguide.ui")
local util = require("fieldguide.util")

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

io.write("dispatch table\n")
do
  cfg.setup({})

  local r = api.call("definitely_not_a_verb", {})
  check("unknown verb is refused", r.ok == false and r.error:find("unknown verb") ~= nil, vim.inspect(r))

  -- The injection path that matters: the verb arrives as data, so there is no
  -- path from agent input to arbitrary Lua through it.
  local injected = api.call("os.exit(1) --", {})
  check("a verb name that is Lua source is just a missing key", injected.ok == false, vim.inspect(injected))

  -- Every verb pcalls: a broken verb must not leave the editor wedged.
  local bad_args = api.call("docs", { query = 12345 })
  check("a verb given nonsense returns, never throws", type(bad_args) == "table", vim.inspect(bad_args))

  -- `verbs` is subtractive: it can shrink from config, never grow.
  cfg.setup({ verbs = { "state", "docs", "exec_lua", "bash" } })
  check("verbs cannot grow from config", #cfg.options.verbs == 2, vim.inspect(cfg.options.verbs))
  local disabled = api.call("reload", {})
  check("a disabled verb is refused at the dispatch table", disabled.ok == false, vim.inspect(disabled))
  check("...and says why", (disabled.error or ""):find("disabled") ~= nil, tostring(disabled.error))
  cfg.setup({})
end

io.write("launch flags\n")
do
  cfg.setup({})
  local argv = table.concat(ui.argv(), " ")

  check("no bash in the tool allowlist", not argv:find("bash"), argv)
  check("no --no-tools escape", not argv:find("no%-tools"), argv)
  for _, flag in ipairs({ "--no-extensions", "--no-skills", "--no-prompt-templates" }) do
    check("hermetic: " .. flag, argv:find(flag, 1, true) ~= nil, argv)
  end
  -- AGENTS.md discovery stays *on*: a config-dir AGENTS.md is a legitimate way
  -- to teach the agent a particular setup.
  check("AGENTS.md discovery is not disabled", not argv:find("no%-context%-files"), argv)
  check("our extension is loaded explicitly", argv:find("extension/nvim.ts", 1, true) ~= nil, argv)
  for _, verb in ipairs(api.verbs()) do
    check("tool registered: nvim_" .. verb, argv:find("nvim_" .. verb, 1, true) ~= nil, argv)
  end

  -- The index tools are allowlisted on this entry point too; the extension
  -- decides whether to register them.
  check("index tools allowlisted in the sidebar", argv:find("nvim_plugins", 1, true) ~= nil, argv)

  local env = ui.env()
  check("the socket is handed over explicitly", env.FIELDGUIDE_ADDR ~= nil, vim.inspect(env))
  check("the sidebar env is the panel env", env.FIELDGUIDE_PLUGIN_INDEX ~= nil, vim.inspect(env))
  check("$NVIM is cleared for the child", env.NVIM == "", vim.inspect(env))
  check("no API key is passed through config", vim.inspect(cfg.options):find("KEY") == nil, "found a key field")
end

io.write("keymaps\n")
do
  -- Panel plugins ship commands and let you bind them. Installing this must not
  -- claim a global key, in the way nvim-tree's toggle does not.
  cfg.setup({})
  check("a bare install binds nothing", vim.tbl_isempty(cfg.options.keys), vim.inspect(cfg.options.keys))

  -- ...and opting into one must not drag the others along through the deep
  -- merge, which is what a non-empty default would do.
  cfg.setup({ keys = { toggle = "<leader>fg" } })
  check(
    "opting into one key does not bind the others",
    vim.tbl_count(cfg.options.keys) == 1,
    vim.inspect(cfg.options.keys)
  )
  check("...and it is the one asked for", cfg.options.keys.toggle == "<leader>fg", vim.inspect(cfg.options.keys))

  -- Keys inside fieldguide's own buffers are a different question from global
  -- ones: claiming a key in a buffer you created is what every panel plugin
  -- does.
  cfg.setup({})
  check(
    "the panel's own buffers do get default keys",
    cfg.options.panel_keys.hide ~= nil,
    vim.inspect(cfg.options.panel_keys)
  )

  -- `hide` is also bound in the terminal sidebar, where every keystroke belongs
  -- to pi's TUI. It claims every ctrl letter except i, m and q.
  local claimed_by_pi = "abcdefghjklnoprstuvwxyz"
  local letter = (cfg.options.panel_keys.hide:match("^<C%-(%a)>$") or ""):lower()
  check(
    "...and hide stays clear of the keys pi's TUI claims",
    letter ~= "" and not claimed_by_pi:find(letter, 1, true),
    cfg.options.panel_keys.hide
  )
end

io.write("rpc launch flags\n")
do
  cfg.setup({})
  local argv = table.concat(require("fieldguide.rpc").argv(), " ")

  check("rpc mode is requested", argv:find("--mode rpc", 1, true) ~= nil, argv)
  check("no bash in the tool allowlist", not argv:find("bash"), argv)
  for _, flag in ipairs({ "--no-extensions", "--no-skills", "--no-prompt-templates" }) do
    check("hermetic: " .. flag, argv:find(flag, 1, true) ~= nil, argv)
  end
  check("AGENTS.md discovery is not disabled", not argv:find("no%-context%-files"), argv)
  -- Without the extension the panel runs a plain agent with none of the verbs,
  -- and the failure is silent: the tools simply do not exist.
  check("the extension is loaded", argv:find("extension/nvim.ts", 1, true) ~= nil, argv)
  for _, verb in ipairs(api.verbs()) do
    check("verb exposed over rpc: nvim_" .. verb, argv:find("nvim_" .. verb, 1, true) ~= nil, argv)
  end

  local env = require("fieldguide.env").agent()
  check("the socket is handed over explicitly", env.FIELDGUIDE_ADDR ~= nil)
  check("$NVIM is cleared for the child", env.NVIM == "")
end

io.write("path helpers\n")
do
  check("is_under: exact root", util.is_under("/a/b", "/a/b"))
  check("is_under: child", util.is_under("/a/b/c", "/a/b"))
  check("is_under: sibling sharing a prefix is not under", not util.is_under("/a/bc", "/a/b"))
  check("is_under: parent is not under", not util.is_under("/a", "/a/b"))
  check("is_under: empty root matches nothing", not util.is_under("/a/b", ""))
  check("relative: strips the root", util.relative("/a/b/c.lua", "/a/b") == "c.lua")
  check("relative: leaves outsiders absolute", util.relative("/x/y", "/a/b") == "/x/y")
end

io.write("reload planning\n")
do
  cfg.setup({})
  local plan = reload.plan()
  local names = vim.tbl_keys(plan.skipped)
  local guards_self = false
  for _, name in ipairs(names) do
    if name:match("^fieldguide") then
      guards_self = true
    end
  end
  check("fieldguide.* is never unloaded mid-call", guards_self, vim.inspect(names))
  for _, name in ipairs(plan.candidates) do
    check("candidate is not fieldguide: " .. name, not name:match("^fieldguide"), name)
  end
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
