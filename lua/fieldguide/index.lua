-- Fetching the plugin index (§12).
--
-- Opt-in, always. The index is a multi-megabyte download from a GitHub release
-- and nothing here touches the network until someone runs `:FieldguideIndex`
-- or sets `index.auto`. A Neovim plugin that phones home on startup because it
-- felt like it is not one worth installing.
--
-- The work itself is `extension/index-fetch.ts`, because verifying a download
-- means opening it with the same reader the extension uses, and that reader is
-- node. Blue-green, so an update cannot break a session already in progress:
-- see the comment at the top of that file.

local cfg = require("fieldguide.config")
local env = require("fieldguide.env")

local M = {}

local running = false

---@return string the index path, whether or not anything is there yet
function M.path()
  return env.index_path()
end

---@param outcome table decoded from the fetcher
---@return string, integer message and log level
local function describe(outcome)
  if outcome.status == "installed" then
    return ("plugin index updated — %d plugins, built %s (new sessions will use it)"):format(
      outcome.plugins,
      (outcome.built_at or ""):sub(1, 10)
    ),
      vim.log.levels.INFO
  elseif outcome.status == "current" then
    return "plugin index is current — " .. (outcome.reason or ""), vim.log.levels.INFO
  end
  return "plugin index: " .. (outcome.reason or "fetch failed"), vim.log.levels.WARN
end

---Fetch or refresh the index.
---@param opts? { quiet?: boolean, max_age_days?: integer }
function M.fetch(opts)
  opts = opts or {}
  -- Two concurrent fetches would race on the same staging file. The second one
  -- is never the interesting one.
  if running then
    if not opts.quiet then
      vim.notify("fieldguide: an index fetch is already running", vim.log.levels.INFO)
    end
    return
  end

  local root = env.plugin_root()
  local argv = { "node", root .. "/extension/index-fetch.ts", M.path() }
  if opts.max_age_days then
    table.insert(argv, "--max-age-days")
    table.insert(argv, tostring(opts.max_age_days))
  end
  if cfg.options.index.repo then
    table.insert(argv, "--repo")
    table.insert(argv, cfg.options.index.repo)
  end

  -- vim.system raises synchronously when the executable is missing. Under
  -- `index.auto` that would be a startup error out of setup(); and `running`
  -- is claimed only once the process exists, so a failure to start does not
  -- refuse every later :FieldguideIndex as "already running".
  local started, err = pcall(vim.system, argv, { text = true }, function(res)
    running = false
    vim.schedule(function()
      local ok, outcome = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(outcome) ~= "table" then
        if not opts.quiet then
          local why = (res.stderr or ""):gsub("%s+$", "")
          vim.notify("fieldguide: index fetch failed — " .. (why ~= "" and why or "no output"), vim.log.levels.WARN)
        end
        return
      end
      local msg, level = describe(outcome)
      -- A background refresh says nothing when there was nothing to do. It does
      -- speak up when it installed something, because which index a session is
      -- about to use is worth knowing.
      if opts.quiet and outcome.status ~= "installed" then
        return
      end
      vim.notify("fieldguide: " .. msg, level)
    end)
  end)
  if not started then
    if not opts.quiet then
      vim.notify("fieldguide: cannot fetch the index — " .. tostring(err), vim.log.levels.WARN)
    end
    return
  end
  running = true
  if not opts.quiet then
    vim.notify("fieldguide: fetching the plugin index…", vim.log.levels.INFO)
  end
end

---Called once at startup. Does nothing at all unless asked to.
function M.maybe_refresh()
  local index = cfg.options.index
  if not index.auto then
    return
  end
  M.fetch({ quiet = true, max_age_days = index.max_age_days })
end

return M
