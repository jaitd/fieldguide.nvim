-- The bridge. A single RPC entry point over a closed table.
--
-- Narrow is enforced here, in Neovim, not requested in a prompt. The client
-- invokes this with the verb name as *data*; there is no path from agent input
-- to arbitrary Lua through this door. A skill that says "please don't run :qa"
-- enforces nothing. A dispatch table with no `quit` verb enforces something.

local cfg = require("fieldguide.config")

local M = {}

---Exposed to the agent as tools. `checkpoint` is deliberately not among them:
---the extension calls it after a write, the agent never asks for it.
M.agent_verbs = { "state", "docs", "explain_keymap", "verify", "reload" }

local VERBS = {
  state = function(args)
    return require("fieldguide.state").run(args)
  end,
  docs = function(args)
    return require("fieldguide.docs").run(args)
  end,
  explain_keymap = function(args)
    return require("fieldguide.keymap").run(args)
  end,
  verify = function(args)
    return require("fieldguide.verify").run(args)
  end,
  reload = function(args)
    return require("fieldguide.reload").run(args)
  end,
  checkpoint = function(args)
    return require("fieldguide.shadow").checkpoint(args.label or "agent write")
  end,
  -- Internal halves of `verify`: the CLI plans and interprets, but spawns and
  -- waits on the sandboxed boot itself, so the boot never blocks the editor's
  -- RPC handler (see bin/fieldguide). Not in agent_verbs: the agent
  -- only ever sees the combined `verify` verb.
  verify_plan = function(args)
    return require("fieldguide.verify").plan(args)
  end,
  verify_interpret = function(args)
    return require("fieldguide.verify").interpret(args.res or {}, {
      duration_ms = args.duration_ms,
      timeout_ms = args.timeout_ms,
      sandbox = args.sandbox,
    })
  end,
}

---@param verb string
---@return boolean
local function enabled(verb)
  if not vim.tbl_contains(M.agent_verbs, verb) then
    return true -- internal verbs are not user-configurable
  end
  return vim.tbl_contains(cfg.options.verbs, verb)
end

---@param verb string
---@param args table?
---@return table
function M.call(verb, args)
  local fn = VERBS[verb]
  if not fn then
    return {
      ok = false,
      error = "unknown verb: " .. tostring(verb) .. " (have: " .. table.concat(vim.tbl_keys(VERBS), ", ") .. ")",
    }
  end
  if not enabled(verb) then
    return { ok = false, error = ("verb %q is disabled in this setup"):format(verb) }
  end
  -- Every verb pcalls: a broken verb must never leave the user's editor wedged.
  local ok, res = pcall(fn, args or {})
  if ok then
    return { ok = true, result = res }
  end
  return { ok = false, error = tostring(res) }
end

---@return string[]
function M.verbs()
  local out = {}
  for _, v in ipairs(M.agent_verbs) do
    if enabled(v) then
      table.insert(out, v)
    end
  end
  return out
end

return M
