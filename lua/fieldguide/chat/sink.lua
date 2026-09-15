-- Append streamed text into a normal buffer.
--
-- The whole difficulty is that deltas do not respect lines. A token arrives as
-- `"hel"`, then `"lo\nwor"`, then `"ld"`. Appending each one as a line gives you
-- three lines and the wrong text; the incomplete last line has to be rewritten
-- in place instead.
--
-- Writes are accumulated and flushed on a timer rather than applied per token:
-- at streaming rates a buffer write per delta is both slow and, with a window
-- attached, visibly janky.

local M = {}

---@class fieldguide.Sink
---@field buf integer
---@field private _pending string
---@field private _flushes integer
local Sink = {}
Sink.__index = Sink

---@param buf integer
---@return fieldguide.Sink
function M.new(buf)
  return setmetatable({ buf = buf, _pending = "", _flushes = 0 }, Sink)
end

---Is the cursor sitting on the last line? Only then should a write scroll the
---view — otherwise it yanks the page out from under someone reading back.
---@param buf integer
---@return integer[] windows that were following the tail
local function following_windows(buf)
  local out = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      local cursor = vim.api.nvim_win_get_cursor(win)
      if cursor[1] >= vim.api.nvim_buf_line_count(buf) then
        table.insert(out, win)
      end
    end
  end
  return out
end

---Queue text. Cheap; does not touch the buffer.
---@param text string?
function Sink:write(text)
  if text and text ~= "" then
    self._pending = self._pending .. text
  end
end

---Queue text followed by a newline.
---@param text string?
function Sink:writeln(text)
  self:write((text or "") .. "\n")
end

---@return boolean
function Sink:dirty()
  return self._pending ~= ""
end

---Apply everything queued. Safe to call when there is nothing to do.
---@return boolean whether anything was written
function Sink:flush()
  if self._pending == "" then
    return false
  end
  if not vim.api.nvim_buf_is_valid(self.buf) then
    self._pending = ""
    return false
  end

  local text = self._pending
  self._pending = ""

  local follow = following_windows(self.buf)

  -- The last buffer line is by definition incomplete — the next delta may
  -- continue it — so it is re-emitted with the new text joined onto it rather
  -- than left alone.
  local last = vim.api.nvim_buf_get_lines(self.buf, -2, -1, false)[1] or ""
  local lines = vim.split(last .. text, "\n", { plain = true })

  local was_modifiable = vim.bo[self.buf].modifiable
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, -2, -1, false, lines)
  vim.bo[self.buf].modifiable = was_modifiable

  local count = vim.api.nvim_buf_line_count(self.buf)
  for _, win in ipairs(follow) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { count, 0 })
    end
  end

  self._flushes = self._flushes + 1
  return true
end

---Ensure the next write starts on a fresh line, without leaving a blank one
---when the buffer is already at a line boundary.
function Sink:ensure_newline()
  if self._pending ~= "" then
    if self._pending:sub(-1) ~= "\n" then
      self._pending = self._pending .. "\n"
    end
    return
  end
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  local last = vim.api.nvim_buf_get_lines(self.buf, -2, -1, false)[1] or ""
  if last ~= "" then
    self._pending = "\n"
  end
end

---The last line of the buffer, ignoring the empty one a trailing newline
---leaves behind. What a reader would call "the line above here".
---@return string
function Sink:last_written_line()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  local n = vim.api.nvim_buf_line_count(self.buf)
  local last = vim.api.nvim_buf_get_lines(self.buf, -2, -1, false)[1] or ""
  if last ~= "" or n < 2 then
    return last
  end
  return vim.api.nvim_buf_get_lines(self.buf, n - 2, n - 1, false)[1] or ""
end

---@return integer
function Sink:flushes()
  return self._flushes
end

return M
