-- Resolved paths and user options.
--
-- Everything downstream compares *resolved* paths: `stdpath("config")`
-- is routinely a symlink into a dotfile-manager tree, and a prefix test on the
-- unresolved path fails open.

local M = {}

---@param p string?
---@return string?
local function real(p)
  if not p or p == "" then
    return nil
  end
  return vim.uv.fs_realpath(p) or p
end

M.defaults = {
  -- nil = whatever pi resolves from its own settings. Set to e.g.
  -- "openrouter/anthropic/claude-sonnet-4.5" to pin one.
  model = nil,
  provider = nil,
  cmd = "pi",
  cwd = nil, -- default: resolve(stdpath("config"))
  window = { side = "right", width = 80 },
  -- Subtractive only: the set can shrink from config, never grow.
  verbs = { "state", "docs", "explain_keymap", "verify", "reload" },
  state = { default = { "nvim", "buffers", "diagnostics", "plugins", "keymaps" } },
  -- "auto" picks by OS: bwrap on Linux, seatbelt (`sandbox-exec`) on macOS.
  -- Pin one with "bwrap" or "seatbelt". There is no "none": verify will not
  -- fall back to an unsandboxed boot, and reports itself unavailable instead.
  verify = { timeout_ms = 15000, sandbox = "auto" },

  -- The buffer-rendered panel. No terminal, no emulator.
  chat = {
    -- Buffer writes are batched at this rate rather than applied per token.
    -- Below ~10Hz streaming looks chunky; above ~30Hz costs more than the eye
    -- collects.
    flush_hz = 20,
    prompt_height = 5,
    show_thinking = false,
    -- Who your turns are attributed to in the transcript. nil resolves the
    -- login name from the passwd database, which is `whoami` without a
    -- subprocess. Set it to whatever you would rather be called.
    user_name = nil,
    -- A bar down the side of the message you are reading. Costs the two
    -- columns of a sign column, permanently reserved so the transcript cannot
    -- jump sideways when the bar appears. Set false to have neither.
    mark_current = true,
    -- Where past sessions are kept. Ours rather than pi's own default, so a
    -- field guide session stays out of the history of whatever else you use pi
    -- for, and that history stays out of this panel's picker. nil resolves to
    -- <state_dir>/sessions.
    session_dir = nil,
    -- Cap on a *collapsed* tool body. Truncation is reported with a count
    -- rather than silently swallowed.
    max_tool_lines = 40,
  },
  reload = { level = "auto" }, -- auto | verify-only | manual
  -- The plugin index: one SQLite file describing the ecosystem, so the
  -- agent can answer about plugins that are *not* installed. Absent is fine —
  -- the two tools it backs are simply not offered. nil resolves to
  -- <state_dir>/nvim-plugins.db; `:FieldguideIndex` fetches one.
  --
  -- `auto` is off because this is a multi-megabyte download from a GitHub
  -- release, and a plugin that reaches for the network at startup without being
  -- asked has made a decision that was not its to make. Turned on, a refresh
  -- runs in the background at most every max_age_days, and a session already
  -- open keeps the index it started with either way.
  index = { path = nil, repo = nil, auto = false, max_age_days = 14 },
  -- Empty on purpose. The plugins that claim a global key by default are the
  -- ones where the keystroke *is* the feature — an operator, a motion, a
  -- navigation pair. Panel plugins ship commands and let you bind them, and
  -- this is a panel. Set any of toggle/focus/reload to opt in; lazy.nvim's own
  -- `keys` spec field is the other route, and it lazy-loads for free.
  keys = {},

  -- Buffer-local, inside fieldguide's own windows only. These *do* get
  -- defaults: claiming a key in a buffer you own is what every panel plugin
  -- does.
  panel_keys = {
    hide = "<C-q>", -- put the panel away
    history = "<C-o>", -- past sessions, from either half of the panel
    normal_mode = "<C-;>", -- leave terminal mode, in the terminal sidebar only
  },
}

M.options = vim.deepcopy(M.defaults)

--- Absolute, symlink-resolved paths. Computed once at setup; `paths()` is the
--- only thing that should ever be used for zone comparisons.
local paths

---@return table
function M.paths()
  if paths then
    return paths
  end

  -- The unresolved path matters too: it is where nvim expects to find the
  -- config, so it is the *destination* the verify sandbox binds onto.
  local declared = M.options.cwd or vim.fn.stdpath("config")
  local config_dir = real(declared)

  local data = vim.fn.stdpath("data")
  local lazy_root = real(data .. "/lazy")

  local doc_roots = {}
  if lazy_root then
    table.insert(doc_roots, lazy_root)
  end
  local runtime = real(vim.env.VIMRUNTIME)
  if runtime then
    table.insert(doc_roots, runtime)
  end

  -- nvim may live under $HOME (a tarball install), in which case the verify
  -- sandbox must bind its prefix back in after tmpfs'ing $HOME.
  local progpath = real(vim.v.progpath)
  local nvim_prefix = progpath and vim.fn.fnamemodify(progpath, ":h:h") or nil

  paths = {
    config_dir = config_dir,
    config_dir_declared = declared,
    lazy_root = lazy_root,
    mason_root = real(data .. "/mason"),
    data_dir = real(data),
    doc_roots = doc_roots,
    runtime = runtime,
    nvim_prefix = nvim_prefix,
    nvim_bin = progpath,
    state_dir = vim.fn.stdpath("state") .. "/fieldguide",
    home = real(vim.uv.os_homedir()),
  }
  return paths
end

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  -- `verbs` is subtractive: intersect with the defaults rather than union.
  local allowed = {}
  for _, v in ipairs(M.defaults.verbs) do
    allowed[v] = true
  end
  local verbs = {}
  for _, v in ipairs(M.options.verbs) do
    if allowed[v] then
      table.insert(verbs, v)
    end
  end
  M.options.verbs = verbs

  paths = nil
  return M.options
end

return M
