-- The embedded-terminal sidebar behind :FieldguideTerm: pi running in a
-- terminal buffer, as an alternative to the chat panel.
--
-- Owned rather than delegated: a dependency here would drag in a
-- general-purpose agent framework.

local api = require("fieldguide.api")
local cfg = require("fieldguide.config")
local env = require("fieldguide.env")

local M = {}

local MIN_PI = { 0, 79, 0 }

---@type table<string, integer> job handle and window/buffer, per tab-agnostic session
local session = { job = nil, buf = nil, win = nil }

local plugin_root = env.plugin_root

---@return boolean, string?
local function check_harness()
  local cmd = cfg.options.cmd
  if vim.fn.executable(cmd) == 0 then
    return false, ("%q is not on PATH. Install pi with:\n  npm install -g @earendil-works/pi-coding-agent"):format(cmd)
  end
  local res = vim.system({ cmd, "--version" }, { text = true }):wait(5000)
  -- First line only: some tools print a banner, and the whole thing ends up in
  -- the failure message otherwise.
  local version = vim.trim(vim.split(res.stdout or "", "\n")[1] or "")
  local major, minor, patch = version:match("(%d+)%.(%d+)%.(%d+)")
  if not major then
    return true -- unparseable, but present; do not block on a cosmetic check
  end
  local have = { tonumber(major), tonumber(minor), tonumber(patch) }
  for i = 1, 3 do
    if have[i] > MIN_PI[i] then
      return true
    end
    if have[i] < MIN_PI[i] then
      return false,
        ("pi %s is older than the minimum %d.%d.%d. Update with:\n  pi update self"):format(
          version,
          MIN_PI[1],
          MIN_PI[2],
          MIN_PI[3]
        )
    end
  end
  return true
end

---@return string[]
function M.argv()
  local o = cfg.options
  local root = plugin_root()

  local tools = { "read", "edit", "write", "grep", "find", "ls" }
  for _, verb in ipairs(api.verbs()) do
    table.insert(tools, "nvim_" .. verb)
  end
  -- Named unconditionally, as the panel does: --tools is an allowlist, and the
  -- extension registers these only when an index file is present.
  vim.list_extend(tools, { "nvim_plugins", "nvim_plugin" })

  local argv = {
    o.cmd,
    -- Hermetic: our extension and nothing else. AGENTS.md discovery stays on —
    -- a config-dir AGENTS.md is a legitimate way to teach the agent this setup.
    "--no-extensions",
    "--no-skills",
    "--no-prompt-templates",
    "--append-system-prompt",
    root .. "/prompt/system.md",
    "--extension",
    root .. "/extension/nvim.ts",
    "--tools",
    table.concat(tools, ","),
  }
  if o.provider then
    vim.list_extend(argv, { "--provider", o.provider })
  end
  if o.model then
    vim.list_extend(argv, { "--model", o.model })
  end
  return argv
end

---@return table<string, string>
function M.env()
  -- One environment for both entry points, so the sidebar cannot lose a
  -- variable the panel gained (it did, once: the index path).
  return env.agent()
end

local function apply_window_opts(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = false
  vim.wo[win].list = false
end

local function open_split()
  local o = cfg.options.window
  vim.cmd(o.side == "left" and "topleft vsplit" or "botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, o.width)
  apply_window_opts(win)
  return win
end

---@return boolean
function M.is_open()
  return session.win ~= nil and vim.api.nvim_win_is_valid(session.win)
end

---@return boolean
local function alive()
  return session.buf ~= nil and vim.api.nvim_buf_is_valid(session.buf) and session.job ~= nil
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(session.win)
    return
  end

  -- Toggle hides, never kills: a killed session loses agent context, the
  -- expensive thing in the room. Re-show the same buffer if it survives.
  if alive() then
    session.win = open_split()
    vim.api.nvim_win_set_buf(session.win, session.buf)
    apply_window_opts(session.win)
    vim.cmd("startinsert")
    return
  end

  local ok, err = check_harness()
  if not ok then
    vim.notify("fieldguide: " .. err, vim.log.levels.ERROR)
    return
  end

  local p = cfg.paths()
  session.win = open_split()
  session.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(session.win, session.buf)

  session.job = vim.api.nvim_buf_call(session.buf, function()
    return vim.fn.jobstart(M.argv(), {
      term = true,
      cwd = p.config_dir,
      env = M.env(),
      on_exit = function()
        session.job = nil
      end,
    })
  end)

  if session.job <= 0 then
    vim.notify("fieldguide: failed to start " .. cfg.options.cmd, vim.log.levels.ERROR)
    return
  end

  vim.bo[session.buf].bufhidden = "hide"
  vim.b[session.buf].fieldguide = true
  apply_window_opts(session.win)

  -- <Esc> must still reach the agent's TUI, so the default terminal escape is
  -- left alone and these are added beside it.
  local sk = cfg.options.panel_keys or {}

  if sk.normal_mode and sk.normal_mode ~= "" then
    vim.keymap.set("t", sk.normal_mode, "<C-\\><C-n>", {
      buffer = session.buf,
      desc = "fieldguide: leave terminal mode",
    })
  end

  if sk.hide and sk.hide ~= "" then
    -- The global toggle is a normal-mode map, and normal mode is exactly what
    -- you are not in while typing at the agent. Bind both modes: terminal mode
    -- has to leave the terminal first, and scheduling keeps the window from
    -- being hidden underneath the mode change.
    vim.keymap.set("t", sk.hide, function()
      vim.cmd("stopinsert")
      vim.schedule(M.close)
    end, { buffer = session.buf, desc = "fieldguide: hide the sidebar" })

    vim.keymap.set("n", sk.hide, M.close, {
      buffer = session.buf,
      desc = "fieldguide: hide the sidebar",
    })
  end

  vim.api.nvim_create_autocmd("TermClose", {
    buffer = session.buf,
    callback = function()
      session.job = nil
    end,
  })

  vim.cmd("startinsert")
end

function M.close()
  if M.is_open() then
    -- :hide, not :bdelete. The job keeps running.
    vim.api.nvim_win_hide(session.win)
  end
  session.win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.focus()
  if M.is_open() then
    vim.api.nvim_set_current_win(session.win)
    vim.cmd("startinsert")
  else
    M.open()
  end
end

function M.stop()
  if session.job then
    vim.fn.jobstop(session.job)
    session.job = nil
  end
  if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    vim.api.nvim_buf_delete(session.buf, { force = true })
  end
  session = { job = nil, buf = nil, win = nil }
end

return M
