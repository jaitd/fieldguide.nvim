-- fieldguide.nvim — a field guide to *your* Neovim.
--
-- You consult it; it does not interrupt you. There is no hint engine, no idle
-- timer, no autocmd that fires on your fourth `j`.

local cfg = require("fieldguide.config")

local M = {}

---Semver, and coupled to the index schema in one direction only.
---
---A breaking index schema change is breaking for a user — their tools stop
---working until they fetch a current index — so it moves this major too. The
---reverse does not hold: a breaking config change is a major here and leaves
---the schema alone. At 0.x both are moot, since 0.x may break freely.
---
---`READS_SCHEMA` in extension/plugins.ts is the index half of the contract.
M.version = "0.1.0"

M.setup = function(opts)
  cfg.setup(opts)
  local o = cfg.options

  local function cmd(name, fn, cmd_opts)
    vim.api.nvim_create_user_command(name, fn, cmd_opts or {})
  end

  local function show(title, value)
    local text = type(value) == "string" and value or vim.inspect(value)
    vim.notify(("fieldguide %s:\n%s"):format(title, text), vim.log.levels.INFO)
  end

  cmd("Fieldguide", function()
    require("fieldguide.chat").toggle()
  end, { desc = "Toggle the fieldguide panel" })

  cmd("FieldguideFocus", function()
    require("fieldguide.chat").open()
    require("fieldguide.chat").focus_prompt()
  end, { desc = "Focus the fieldguide prompt" })

  cmd("FieldguideHistory", function()
    require("fieldguide.chat").history()
  end, { desc = "Pick a past session and carry it on" })

  cmd("FieldguideStop", function()
    require("fieldguide.chat").stop()
  end, { desc = "Stop the agent session (loses its context)" })

  -- The embedded-terminal sidebar. The panel does everything it does without
  -- an emulator in the path; this remains as a fallback.
  cmd("FieldguideTerm", function()
    require("fieldguide.ui").toggle()
  end, { desc = "Toggle the legacy embedded-terminal sidebar" })

  cmd("FieldguideVerify", function()
    local res = require("fieldguide.verify").run({})
    show("verify", require("fieldguide.verify").summary(res))
    if not res.ok and res.errors and #res.errors > 0 then
      show("verify errors", table.concat(res.errors, "\n"))
    end
  end, { desc = "Sandboxed headless boot of the config as it is on disk" })

  cmd("FieldguideReload", function()
    local res = require("fieldguide.reload").run({ force = true })
    show("reload", {
      ok = res.ok,
      reloaded = res.reloaded,
      errors = res.errors,
      duration_ms = res.duration_ms,
      checkpoint = res.checkpoint,
    })
  end, { desc = "Purge and re-require config modules in this editor" })

  cmd("FieldguideLog", function()
    local log = require("fieldguide.shadow").log(20)
    local lines = {}
    for _, e in ipairs(log.entries) do
      table.insert(lines, ("%s  %-16s %s"):format(e.sha, e.when, e.subject))
    end
    show("checkpoints", #lines > 0 and table.concat(lines, "\n") or "(none yet)")
  end, { desc = "List shadow-repo checkpoints" })

  cmd("FieldguideUndo", function(args)
    local ref = args.args ~= "" and args.args or "HEAD~1"
    local res = require("fieldguide.shadow").restore(ref)
    if res.ok then
      show("undo", "restored work tree to " .. ref .. " (" .. res.sha .. "). Reload buffers with :checktime")
      vim.cmd("checktime")
    else
      vim.notify("fieldguide undo failed: " .. tostring(res.error), vim.log.levels.ERROR)
    end
  end, { nargs = "?", desc = "Restore the config tree to a checkpoint (default HEAD~1)" })

  cmd("FieldguideDocs", function(args)
    show("docs", require("fieldguide.docs").run({ query = args.args }))
  end, { nargs = 1, desc = "Resolve a helptag or plugin name against what is installed" })

  cmd("FieldguideKeymap", function(args)
    show("explain_keymap", require("fieldguide.keymap").run({ lhs = args.args }))
  end, { nargs = 1, desc = "Explain a keymap: mapping, definition site, owning plugin, docs" })

  cmd("FieldguideState", function(args)
    show("state", require("fieldguide.state").run({ what = args.args ~= "" and args.args or nil }))
  end, { nargs = "?", desc = "Dump live state (comma-separated sections)" })

  cmd("FieldguideChat", function()
    require("fieldguide.chat").start()
  end, { desc = "Open the buffer-rendered agent panel" })

  cmd("FieldguideChatStop", function()
    require("fieldguide.chat").stop()
  end, { desc = "Stop the panel's agent session" })

  -- The normalised event stream, unrendered. For working on the protocol
  -- itself, or for telling a rendering bug apart from a transport one.
  cmd("FieldguideRpc", function()
    require("fieldguide.rpc.log").start()
  end, { desc = "Start an RPC session and open the raw event log" })

  cmd("FieldguideRpcSay", function(args)
    require("fieldguide.rpc.log").prompt(args.args)
  end, { nargs = "+", desc = "Send a prompt to the RPC session" })

  cmd("FieldguideRpcStop", function()
    require("fieldguide.rpc.log").stop()
  end, { desc = "Stop the RPC session and report stream stats" })

  cmd("FieldguideLevel", function(args)
    local level = args.args
    if not vim.tbl_contains({ "auto", "verify-only", "manual" }, level) then
      vim.notify("fieldguide: level must be auto | verify-only | manual", vim.log.levels.ERROR)
      return
    end
    -- Runtime toggle rather than setup-only, because the level you want depends
    -- on whether you are paying attention right now.
    cfg.options.reload.level = level
    show("reload level", level)
  end, {
    nargs = 1,
    complete = function()
      return { "auto", "verify-only", "manual" }
    end,
    desc = "Set the reload level for this session",
  })

  cmd("FieldguideIndex", function()
    require("fieldguide.index").fetch({})
  end, { desc = "Fetch or refresh the plugin index" })

  do
    -- Nothing is bound unless asked for. `false` is accepted as well as nil, so
    -- a key can be switched off without knowing what the default was.
    local map = function(lhs, rhs, desc)
      if type(lhs) == "string" and lhs ~= "" then
        vim.keymap.set("n", lhs, rhs, { desc = desc })
      end
    end
    local keys = o.keys or {}
    map(keys.toggle, "<cmd>Fieldguide<cr>", "fieldguide: toggle panel")
    map(keys.focus, "<cmd>FieldguideFocus<cr>", "fieldguide: focus prompt")
    map(keys.reload, "<cmd>FieldguideReload<cr>", "fieldguide: reload config modules")
    map(keys.history, "<cmd>FieldguideHistory<cr>", "fieldguide: past sessions")
  end

  -- Returns immediately unless index.auto was asked for, and that fetch is
  -- backgrounded and rate-limited by max_age_days. Everything else — the shadow
  -- repo, the agent, the sandbox — is created on first use. Nothing here should
  -- cost a user who never opens the panel.
  require("fieldguide.index").maybe_refresh()
  return M
end

setmetatable(M, {
  __index = function(_, key)
    -- `require("fieldguide").verify()` and friends, without a require per verb.
    if vim.tbl_contains({ "state", "docs", "explain_keymap", "verify", "reload" }, key) then
      return function(args)
        return require("fieldguide.api").call(key, args)
      end
    end
    if key == "toggle" or key == "open" or key == "close" then
      return function(...)
        return require("fieldguide.chat")[key](...)
      end
    end
    if key == "focus" then
      return function()
        require("fieldguide.chat").open()
        return require("fieldguide.chat").focus_prompt()
      end
    end
    return nil
  end,
})

return M
