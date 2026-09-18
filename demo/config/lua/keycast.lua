-- Shows the keys being pressed, bottom left, so a viewer can tell what drove
-- the demo. Demo furniture: it is not part of fieldguide, and it lives here
-- rather than in a plugin so that "which plugins do I have installed" answers
-- with the config's real plugins and not with the recording's scaffolding.
--
-- Insert and command-line mode are skipped on purpose: the questions typed
-- into the panel are already on screen as text, and echoing them a character
-- at a time would be noise.
local M = {}

local HOLD_MS = 2500
local MAX = 8

local keys = {}
local buf, win, timer

local function close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
  keys = {}
end

local function render()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
  end
  local line = " " .. table.concat(keys, " ") .. " "
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })

  local config = {
    relative = "editor",
    anchor = "SW",
    row = vim.o.lines - 2,
    col = 1,
    width = #line,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 250,
  }
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, config)
  else
    win = vim.api.nvim_open_win(buf, false, config)
    vim.wo[win].winhighlight = "Normal:DiffText,FloatBorder:DiffText"
  end
end

function M.setup()
  vim.on_key(function(_, typed)
    if typed == nil or typed == "" then
      return
    end
    local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
    if mode == "i" or mode == "c" or mode == "R" or mode == "t" then
      return
    end

    -- keytrans turns a raw byte sequence into what a person would call it:
    -- <Space>, <C-w>, <Esc>.
    local ok, pretty = pcall(vim.fn.keytrans, typed)
    if not ok or pretty == "" then
      return
    end

    keys[#keys + 1] = pretty
    while #keys > MAX do
      table.remove(keys, 1)
    end

    pcall(render)
    if timer then
      timer:stop()
    end
    timer = vim.defer_fn(close, HOLD_MS)
  end)
end

return M
