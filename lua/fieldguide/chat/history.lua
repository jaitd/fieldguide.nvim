-- Past sessions: finding them, describing them, and reading them back.
--
-- pi keeps every session as JSONL and takes `--session <id>` to carry one on,
-- so the panel does not need a transcript format of its own — it needs to know
-- where the files are and how to turn a finished log back into the events the
-- renderer already understands.
--
-- The log is not the wire protocol. It stores whole messages where the stream
-- delivers deltas, so a text part comes back as one delta rather than a
-- thousand. Everything downstream of `on_event` cannot tell the difference,
-- which is the point: there is one renderer, not two.

local cfg = require("fieldguide.config")

local M = {}

---Where sessions live.
---
---Ours, not pi's own. `--session-dir` puts the files in a flat directory of our
---choosing, which keeps a field guide session out of the history of whatever
---else you use pi for, and keeps that history out of this picker.
---@return string
function M.dir()
  local configured = (cfg.options.chat or {}).session_dir
  if type(configured) == "string" and configured ~= "" then
    return vim.fs.normalize(configured)
  end
  return vim.fs.normalize(cfg.paths().state_dir .. "/sessions")
end

---@param text string
---@param cap integer
---@return string
local function first_line(text, cap)
  local line = vim.trim((vim.split(text, "\n", { plain = true })[1] or ""))
  if vim.fn.strchars(line) > cap then
    line = vim.fn.strcharpart(line, 0, cap - 1) .. "…"
  end
  return line
end

---@param content any
---@return string
local function text_of(content)
  if type(content) == "string" then
    return content
  end
  local out = {}
  for _, part in ipairs(type(content) == "table" and content or {}) do
    if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
      table.insert(out, part.text)
    end
  end
  return table.concat(out, "")
end

---What a session was about, without reading all of it.
---
---Stops at the first thing you said, which is both the title and the only line
---that identifies the session to the person who had it. A long session is
---megabytes; the answer is in the first few hundred bytes.
---@param path string
---@return table? { id, path, started, title }
function M.summarise(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local entry = nil
  for line in f:lines() do
    local decoded, record = pcall(vim.json.decode, line)
    if decoded and type(record) == "table" then
      if record.type == "session" then
        entry = { id = record.id, path = path, started = record.timestamp or "", title = nil }
      elseif entry and record.type == "message" and (record.message or {}).role == "user" then
        entry.title = first_line(text_of(record.message.content), 60)
        break
      end
    end
  end
  f:close()
  if entry and (entry.title == nil or entry.title == "") then
    entry.title = "(nothing was asked)"
  end
  return entry
end

---Every session we have, newest first.
---@return table[]
function M.list()
  local dir = M.dir()
  local out = {}
  if vim.fn.isdirectory(dir) == 0 then
    return out
  end
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.jsonl$") then
      local entry = M.summarise(dir .. "/" .. name)
      if entry and entry.id then
        table.insert(out, entry)
      end
    end
  end
  table.sort(out, function(a, b)
    return a.started > b.started
  end)
  return out
end

---One line naming a session in a picker.
---
---In your own time, not UTC. The log records an ISO timestamp in UTC and the
---transcript's own session marker is local, so showing the stored string
---unchanged puts two different clocks in front of the same person.
---@param entry table
---@return string
function M.label(entry)
  local y, mo, d, h, mi, sec = tostring(entry.started):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  local when = tostring(entry.started)
  if y then
    -- `os.time` reads a broken-down time as local, so the same call on this
    -- moment's own UTC fields is exactly one offset away from now. Both sides
    -- say `isdst = false` so that they read the fields the same way and the
    -- offset cancels exactly; `os.date` below is what puts summer time back.
    local now = os.time()
    local utc = os.date("!*t", now)
    utc.isdst = false
    local offset = os.difftime(now, os.time(utc))
    local at = os.time({
      year = tonumber(y),
      month = tonumber(mo),
      day = tonumber(d),
      hour = tonumber(h),
      min = tonumber(mi),
      sec = tonumber(sec),
      isdst = false,
    })
    when = os.date("%Y-%m-%d %H:%M", at + offset)
  end
  return ("%s  %s"):format(when, entry.title or "")
end

---Read a finished session back as events the renderer already handles.
---
---A user message becomes a `user` event, which nothing on the wire ever sends:
---the live path writes your turn from the prompt, and a replay has no prompt to
---write it from. Every other kind is exactly what the adapter would have
---produced, so the transcript comes back looking like the one you had.
---@param path string
---@return fieldguide.Event[]
function M.events(path)
  local out = {}
  local ok, lines = pcall(io.lines, path)
  if not ok then
    return out
  end

  -- Arguments live on the assistant's tool call and the result arrives as its
  -- own record later, exactly as on the wire. Carried across by id.
  local args = {}

  for line in lines do
    local decoded, record = pcall(vim.json.decode, line)
    local message = decoded and type(record) == "table" and record.type == "message" and record.message or nil
    if type(message) == "table" then
      if message.role == "user" then
        local text = vim.trim(text_of(message.content))
        if text ~= "" then
          table.insert(out, { kind = "user", text = text })
        end
      elseif message.role == "assistant" then
        local said = false
        for _, part in ipairs(type(message.content) == "table" and message.content or {}) do
          if part.type == "text" and vim.trim(part.text or "") ~= "" then
            table.insert(out, { kind = "text_delta", text = part.text })
            said = true
          elseif part.type == "thinking" and vim.trim(part.thinking or "") ~= "" then
            table.insert(out, { kind = "thinking_delta", text = part.thinking })
            said = true
          elseif part.type == "toolCall" then
            args[part.id or ""] = part.arguments
          end
        end
        -- Only where the agent actually said something. A message that is
        -- nothing but tool calls is the middle of a turn, and closing the block
        -- there would put a gap between a call and its own result.
        if said then
          table.insert(out, { kind = "settled" })
        end
      elseif message.role == "toolResult" then
        table.insert(out, {
          kind = "tool_end",
          tool_call_id = message.toolCallId,
          tool = message.toolName,
          args = args[message.toolCallId or ""],
          text = text_of(message.content),
          details = message.details,
          is_error = message.isError == true,
        })
      end
    end
  end
  return out
end

return M
