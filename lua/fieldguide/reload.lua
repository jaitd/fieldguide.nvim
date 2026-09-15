-- Verb: `reload` — the privileged act.
--
-- This executes agent-authored code in an unsandboxed process. That is inherent
-- to the feature and it is not gated, at the default level, by anything.
-- `verify` is not the gate: it cannot see deferred payloads.
--
-- It is also not the headline verb. In a typical config, plugin specs are most
-- of the Lua and essentially all of the churn, and plugin-spec changes do not
-- route through here — `require("lazy").reload()` re-runs a plugin's `config`
-- without undoing the previous one's autocmds, keymaps and highlight groups.
-- The honest answer to "did my treesitter change work" is a sandboxed boot.

local cfg = require("fieldguide.config")
local shadow = require("fieldguide.shadow")
local util = require("fieldguide.util")

local M = {}

---Where a loaded module came from. `package.loaded` does not record it, so ask
---the loader.
---@param name string
---@return string?
local function modpath(name)
  local ok, found = pcall(function()
    return vim.loader.find(name, { rtp = true, paths = { cfg.paths().config_dir .. "/lua" } })[1]
  end)
  if ok and found and found.modpath then
    return found.modpath
  end
  return nil
end

---The module that called `lazy.setup()` must survive: re-requiring it re-runs
---the plugin manager over every installed plugin. Detected mechanically rather
---than hardcoded to one person's layout.
---@param path string
---@return boolean
local function calls_lazy_setup(path)
  local data = util.read_file(path)
  if not data then
    return false
  end
  return data:find("require%s*%(?%s*[\"']lazy[\"']%s*%)?%s*%.%s*setup") ~= nil
end

---@return integer
local function message_count()
  local ok, res = pcall(vim.api.nvim_exec2, "messages", { output = true })
  if not ok then
    return 0
  end
  return #vim.split(res.output or "", "\n", { trimempty = false })
end

---@param from integer
---@return string[]
local function messages_since(from)
  local ok, res = pcall(vim.api.nvim_exec2, "messages", { output = true })
  if not ok then
    return {}
  end
  local lines = vim.split(res.output or "", "\n", { trimempty = false })
  local out = {}
  for i = from + 1, #lines do
    if vim.trim(lines[i]) ~= "" then
      table.insert(out, lines[i])
    end
  end
  return out
end

---@return table { candidates: string[], skipped: table[] }
function M.plan()
  local root = cfg.paths().config_dir
  local candidates, skipped = {}, {}

  for name in pairs(package.loaded) do
    if name:match("^fieldguide") then
      skipped[name] = "fieldguide itself — never unload the plugin mid-call"
    else
      local path = modpath(name)
      if path and util.is_under(util.resolve(path), root) then
        if calls_lazy_setup(path) then
          skipped[name] = "calls lazy.setup() — re-requiring it re-runs the plugin manager"
        else
          table.insert(candidates, name)
        end
      end
    end
  end

  table.sort(candidates)
  return { candidates = candidates, skipped = skipped }
end

---@param args table { force?: boolean }
function M.run(args)
  args = args or {}
  local level = cfg.options.reload.level

  if level ~= "auto" and not args.force then
    local has_ui = #vim.api.nvim_list_uis() > 0
    if not has_ui then
      return {
        ok = false,
        blocked = true,
        error = ('reload level is %q and there is no UI to prompt. Set level to "auto" or run '):format(level)
          .. ":FieldguideReload yourself.",
      }
    end
    local choice = vim.fn.confirm("fieldguide: reload config modules in this editor?", "&Yes\n&No", 2)
    if choice ~= 1 then
      return { ok = false, blocked = true, error = "declined by user" }
    end
  end

  local t0 = vim.uv.hrtime()
  local before = message_count()
  local plan = M.plan()

  for _, name in ipairs(plan.candidates) do
    package.loaded[name] = nil
  end

  local reloaded, errors = {}, {}
  for _, name in ipairs(plan.candidates) do
    local ok, err = pcall(require, name)
    if ok then
      table.insert(reloaded, name)
    else
      table.insert(errors, { module = name, error = tostring(err) })
    end
  end

  local duration_ms = math.floor((vim.uv.hrtime() - t0) / 1e4) / 100
  local checkpoint = shadow.checkpoint(("reload: %d module(s)"):format(#reloaded))

  return {
    ok = #errors == 0,
    reloaded = reloaded,
    skipped = plan.skipped,
    errors = errors,
    messages = messages_since(before),
    duration_ms = duration_ms,
    checkpoint = checkpoint.sha or (checkpoint.unchanged and "unchanged") or nil,
    checkpoint_error = checkpoint.error,
    -- Reloading a file does not remove the autocmds, keymaps or highlight
    -- groups it previously created. Named augroups with { clear = true } make
    -- this safe; a renamed keymap lhs will leak the old binding.
    caveat = "side effects do not unregister: renamed keymaps leak their old lhs, "
      .. "and autocmds outside a cleared augroup accumulate.",
  }
end

return M
