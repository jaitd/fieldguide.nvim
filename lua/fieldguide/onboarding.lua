-- The setup wizard: which agent the panel runs, with which model, and whether
-- to fetch the plugin index. Run by the first `:Fieldguide` with nothing
-- chosen yet, and by `:FieldguideSetup` whenever asked.
--
-- Every harness is checked first, by the preflight its launch would run, so
-- the list says which are ready here and why the others are not, before
-- anything is picked. The questions are vim.ui.select and vim.ui.input, which
-- whatever picker the user has installed takes over.

local cfg = require("fieldguide.config")
local launch = require("fieldguide.launch")

local M = {}

---What each harness is, for the list.
M.DESCRIPTIONS = {
  pi = "pi, the default",
  claude = "Claude Code",
  opencode = "opencode 2",
  codex = "Codex, sandboxed",
}

---Examples for a model typed by hand. opencode lists its own instead.
local MODEL_HINTS = {
  pi = "provider/model",
  claude = "sonnet, opus, haiku",
  codex = "gpt-5.6-luna",
}

---@class fieldguide.HarnessCheck
---@field name string
---@field ready boolean
---@field why string? what stands in the way, when not ready

---Each harness checked by its own preflight. Nothing is started: a placeholder
---stands in for the MCP server's socket, which only Codex asks after, and only
---for being set.
---@return fieldguide.HarnessCheck[]
function M.check()
  local rows = {}
  for _, name in ipairs(launch.HARNESSES) do
    local why
    if name == "pi" then
      local cmd = cfg.options.cmd or "pi"
      if vim.fn.executable(cmd) == 0 then
        why = ("%q is not on PATH"):format(cmd)
      end
    else
      local h = require("fieldguide.harness." .. name)
      local ok, refused = pcall(h.preflight, launch.opts({ name = name }, "(not started)"))
      if ok then
        why = refused
      else
        why = "the check itself failed: " .. tostring(refused)
      end
    end
    table.insert(rows, { name = name, ready = why == nil, why = why })
  end
  return rows
end

---@param row fieldguide.HarnessCheck
---@param current string the harness chosen now
---@return string
function M.label(row, current)
  local text = ("%-9s %s"):format(row.name, M.DESCRIPTIONS[row.name] or "")
  if row.name == current and launch.chosen() then
    text = text .. " (current)"
  end
  if row.ready then
    return text .. " — ready"
  end
  -- The first line only: a picker shows one line per item.
  return text .. " — not ready: " .. vim.split(row.why or "", "\n", { plain = true })[1]
end

---opencode's models, as it lists them: only the providers it has a login for
---and the ones it bundles, so a pick from here is one it can run.
---@return string[]
function M.opencode_models()
  local bin = vim.fn.exepath("opencode")
  if bin == "" then
    return {}
  end
  local ok, r = pcall(function()
    return vim.system({ bin, "models" }, { text = true }):wait(20000)
  end)
  if not ok or r.code ~= 0 then
    return {}
  end
  local models = {}
  for line in vim.gsplit(r.stdout or "", "\n", { plain = true }) do
    line = vim.trim(line)
    if line:match("^[%w%._%-]+/[%w%._%-/:]+$") then
      table.insert(models, line)
    end
  end
  return models
end

---@param name string
---@param current fieldguide.HarnessChoice
---@param done fun(model: string?)
local function ask_model(name, current, done)
  local previous = current.name == name and current.model or nil
  if name == "opencode" then
    local models = M.opencode_models()
    if #models > 0 then
      local default = "opencode's own default"
      local items = vim.list_extend({ default }, models)
      vim.ui.select(items, {
        prompt = "fieldguide: which model should opencode use?",
        format_item = function(item)
          return item == previous and (item .. " (current)") or item
        end,
      }, function(item)
        done(item ~= default and item or nil)
      end)
      return
    end
  end
  vim.ui.input({
    prompt = ("fieldguide: model for %s (%s; empty for its default): "):format(name, MODEL_HINTS[name] or "its name"),
    default = previous or "",
  }, function(text)
    text = text and vim.trim(text) or ""
    done(text ~= "" and text or nil)
  end)
end

---@param done fun()
local function offer_index(done)
  if require("fieldguide.env").plugin_index() ~= "" then
    done()
    return
  end
  local fetch = "Download it now (a few megabytes, from GitHub)"
  vim.ui.select({ fetch, "Not now (:FieldguideIndex fetches it later)" }, {
    prompt = "fieldguide: fetch the plugin index, so the agent can answer about plugins you have not installed?",
  }, function(item)
    if item == fetch then
      require("fieldguide.index").fetch({})
    end
    done()
  end)
end

---@param rows fieldguide.HarnessCheck[]
---@param current fieldguide.HarnessChoice
---@param done fun(row: fieldguide.HarnessCheck?)
local function pick(rows, current, done)
  vim.ui.select(rows, {
    prompt = "fieldguide: which agent should the panel run?",
    format_item = function(row)
      return M.label(row, current.name)
    end,
  }, function(row)
    if row and not row.ready then
      -- Said in full, then asked again: the list shows only its first line.
      vim.notify(("fieldguide: %s is not ready: %s"):format(row.name, row.why), vim.log.levels.WARN)
      vim.schedule(function()
        pick(rows, current, done)
      end)
      return
    end
    done(row)
  end)
end

---Ask, save, and call `done` with the choice. Cancelled at the first question,
---nothing changes and `done` is not called.
---@param done fun(choice: fieldguide.HarnessChoice)?
function M.run(done)
  local current = launch.current()
  vim.notify("fieldguide: checking which agents are ready…", vim.log.levels.INFO)
  local rows = M.check()
  pick(rows, current, function(row)
    if not row then
      vim.notify("fieldguide: setup cancelled; nothing changed", vim.log.levels.INFO)
      return
    end
    ask_model(row.name, current, function(model)
      local choice = { name = row.name, model = model }
      local ok, err = launch.choose(choice)
      if not ok then
        vim.notify("fieldguide: could not save the choice: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      offer_index(function()
        local running = require("fieldguide.chat")._state().session
        vim.notify(
          ("fieldguide: the panel runs %s%s%s"):format(
            row.name,
            model and (" with " .. model) or "",
            running and running:is_running() and ", from the next session (:FieldguideStop ends this one)" or ""
          ),
          vim.log.levels.INFO
        )
        if done then
          done(choice)
        end
      end)
    end)
  end)
end

return M
