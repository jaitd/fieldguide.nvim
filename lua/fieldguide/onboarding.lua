-- The setup wizard: which agent the panel runs, with which model, and whether
-- to fetch the plugin index. Run by the first `:Fieldguide` with nothing
-- chosen yet, and by `:FieldguideSetup` whenever asked.
--
-- Every harness is checked first, by the preflight its launch would run, so
-- the list says which are ready here and why the others are not, before
-- anything is picked. The questions are vim.ui.select and vim.ui.input, which
-- whatever picker the user has installed takes over.

local launch = require("fieldguide.launch")

local M = {}

---What each harness is, for the list.
M.DESCRIPTIONS = {
  pi = "pi, the default",
  claude = "Claude Code",
  opencode = "opencode 2",
  codex = "Codex, sandboxed",
}

---Examples for a model typed by hand. pi and opencode list their own instead.
local MODEL_HINTS = {
  claude = "sonnet, opus, haiku",
  codex = "gpt-5.6-luna",
}

-- Each question on a clean screen. With the built-in vim.ui, a question is
-- printed on the command line straight after the answer to the one before,
-- with no newline between them, and the lists pile up until Neovim stops for
-- "Press ENTER". So a question is asked on the next turn of the main loop,
-- once the last one's prompt is done with, and the message area is cleared
-- first. A picker plugin that takes over vim.ui loses nothing by it.

---@param fn fun()
local function fresh(fn)
  vim.schedule(function()
    vim.cmd("redraw")
    fn()
  end)
end

---@param items any[]
---@param opts table
---@param on_choice fun(item: any?)
local function select(items, opts, on_choice)
  fresh(function()
    vim.ui.select(items, opts, on_choice)
  end)
end

---@param opts table
---@param on_confirm fun(text: string?)
local function input(opts, on_confirm)
  fresh(function()
    vim.ui.input(opts, on_confirm)
  end)
end

---A line that is progress, not news: shown now, kept out of :messages, and
---gone at the next question.
---@param text string
local function say(text)
  vim.api.nvim_echo({ { text } }, false, {})
  vim.cmd("redraw")
end

---@class fieldguide.HarnessCheck
---@field name string
---@field ready boolean
---@field why string? what stands in the way, when not ready

---Each harness checked by its own preflight, pi's version included. Nothing
---is started: a placeholder stands in for the MCP server's socket, which only
---Codex asks after, and only for being set.
---@return fieldguide.HarnessCheck[]
function M.check()
  local rows = {}
  for _, name in ipairs(launch.HARNESSES) do
    local h = require("fieldguide.harness." .. name)
    local ok, refused = pcall(h.preflight, launch.opts({ name = name }, "(not started)"))
    local why
    if ok then
      why = refused
    else
      why = "the check itself failed: " .. tostring(refused)
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

---@param current fieldguide.HarnessChoice
---@param done fun(model: string?, provider: string?)
local function ask_pi_model(current, done)
  -- A pair, never a model alone: pi needs the provider to agree with it, and
  -- a model typed by hand would run under whatever provider setup() names.
  local models = require("fieldguide.harness.pi").models()
  if #models == 0 then
    -- No provider pi can use yet; its own default is all there is to pick.
    done(nil, nil)
    return
  end
  local default = { label = "pi's own default" }
  local items = vim.list_extend({ default }, models)
  select(items, {
    prompt = "fieldguide: which model should pi use?",
    format_item = function(item)
      if item == default then
        return item.label
      end
      local text = ("%s  %s"):format(item.provider, item.model)
      local chosen = current.name == "pi" and current.model == item.model and current.provider == item.provider
      return chosen and (text .. " (current)") or text
    end,
  }, function(item)
    if not item or item == default then
      done(nil, nil)
    else
      done(item.model, item.provider)
    end
  end)
end

---@param name string
---@param current fieldguide.HarnessChoice
---@param done fun(model: string?, provider: string?)
local function ask_model(name, current, done)
  local previous = current.name == name and current.model or nil
  if name == "pi" then
    ask_pi_model(current, done)
    return
  end
  if name == "opencode" then
    -- No "opencode's own default": it can be a provider with no login (its
    -- free Zen models, for one), which the list does not show and the first
    -- prompt would refuse. The model is picked by name, the current one first.
    local models = M.opencode_models()
    if #models > 0 then
      if previous and vim.tbl_contains(models, previous) then
        models = vim.list_extend(
          { previous },
          vim.tbl_filter(function(m)
            return m ~= previous
          end, models)
        )
      end
      select(models, {
        prompt = "fieldguide: which model should opencode use? (it must be one your opencode is logged in for)",
        format_item = function(item)
          return item == previous and (item .. " (current)") or item
        end,
      }, function(item)
        done(item)
      end)
      return
    end
  end
  input({
    prompt = ("fieldguide: model for %s (%s; empty for its default): "):format(name, MODEL_HINTS[name] or "its name"),
    default = previous or "",
  }, function(text)
    text = text and vim.trim(text) or ""
    done(text ~= "" and text or nil)
  end)
end

---With a download asked for, `done` waits for it: a session started first
---would begin without the index it was just promised, and keep that for its
---whole life.
---@param done fun()
local function offer_index(done)
  if require("fieldguide.env").plugin_index() ~= "" then
    done()
    return
  end
  local fetch = "Download it now (a few megabytes, from GitHub)"
  select({ fetch, "Not now (:FieldguideIndex fetches it later)" }, {
    prompt = "fieldguide: fetch the plugin index, so the agent can answer about plugins you have not installed?",
  }, function(item)
    if item == fetch then
      -- Its "fetching" line on a clean screen, not under the list.
      fresh(function()
        require("fieldguide.index").fetch({ on_done = done })
      end)
      return
    end
    done()
  end)
end

---@param rows fieldguide.HarnessCheck[]
---@param current fieldguide.HarnessChoice
---@param done fun(row: fieldguide.HarnessCheck?)
---@param refused fieldguide.HarnessCheck? the one just picked that is not ready
local function pick(rows, current, done, refused)
  local prompt = "fieldguide: which agent should the panel run?"
  if refused then
    -- In the question asked again, in full: the list shows only its first
    -- line, and a message said before it would be cleared with the screen.
    prompt = ("fieldguide: %s is not ready: %s\nWhich agent should the panel run?"):format(refused.name, refused.why)
  end
  select(rows, {
    prompt = prompt,
    format_item = function(row)
      return M.label(row, current.name)
    end,
  }, function(row)
    if row and not row.ready then
      pick(rows, current, done, row)
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
  -- Shown before the checks, which take a moment and block while they run.
  say("fieldguide: checking which agents are ready…")
  local rows = M.check()
  pick(rows, current, function(row)
    if not row then
      vim.cmd("redraw")
      vim.notify("fieldguide: setup cancelled; nothing changed", vim.log.levels.INFO)
      return
    end
    ask_model(row.name, current, function(model, provider)
      local choice = { name = row.name, model = model, provider = provider }
      local ok, err = launch.choose(choice)
      if not ok then
        vim.notify("fieldguide: could not save the choice: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      offer_index(function()
        vim.cmd("redraw")
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
