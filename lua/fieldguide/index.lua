-- Fetching the plugin index.
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

---The fetch in progress, and whoever is waiting for it. Each fetch has its
---own: a waiter is only ever released by the fetch it waited on, never by
---one that ended as it was being asked.
---@type { waiters: fun()[] }?
local current

---A fetch is over, however it went: everyone waiting on it is told.
---@param run { waiters: fun()[] }
local function release(run)
  for _, fn in ipairs(run.waiters) do
    fn()
  end
end

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

---Fetch or refresh the index. `on_done` is called once the fetch is over,
---however it went: this one, or the one already running when this was asked,
---which this one waits for rather than racing.
---@param opts? { quiet?: boolean, max_age_days?: integer, on_done?: fun() }
function M.fetch(opts)
  opts = opts or {}
  -- Two concurrent fetches would race on the same staging file. The second one
  -- is never the interesting one, and waits on the first.
  if current then
    table.insert(current.waiters, opts.on_done)
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

  local run = { waiters = { opts.on_done } }

  -- vim.system raises synchronously when the executable is missing. Under
  -- `index.auto` that would be a startup error out of setup(); and the fetch
  -- is current only once the process exists, so a failure to start does not
  -- refuse every later :FieldguideIndex as "already running".
  local started, err = pcall(vim.system, argv, { text = true }, function(res)
    vim.schedule(function()
      -- On the main loop, in the same step as the release: a fetch asked
      -- before this point still finds this one current and waits on it.
      if current == run then
        current = nil
      end
      local ok, outcome = pcall(vim.json.decode, res.stdout or "")
      if not ok or type(outcome) ~= "table" then
        if not opts.quiet then
          local why = (res.stderr or ""):gsub("%s+$", "")
          vim.notify("fieldguide: index fetch failed — " .. (why ~= "" and why or "no output"), vim.log.levels.WARN)
        end
        release(run)
        return
      end
      local msg, level = describe(outcome)
      -- A background refresh says nothing when there was nothing to do. It does
      -- speak up when it installed something, because which index a session is
      -- about to use is worth knowing.
      if not (opts.quiet and outcome.status ~= "installed") then
        vim.notify("fieldguide: " .. msg, level)
      end
      release(run)
    end)
  end)
  if not started then
    if not opts.quiet then
      vim.notify("fieldguide: cannot fetch the index — " .. tostring(err), vim.log.levels.WARN)
    end
    release(run)
    return
  end
  current = run
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
