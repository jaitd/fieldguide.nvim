-- JSONL framing for the agent protocol.
--
-- Pure and stateful-but-processless, so the nasty cases can be tested without
-- spawning anything. This is where intermittent corruption lives: chunk
-- boundaries have nothing to do with line boundaries, and a JSON object split
-- across two reads is the normal case under streaming, not an edge case.
--
-- pi's docs are specific about the rules, and they matter:
--   * split on LF only
--   * tolerate a trailing CR
--   * never split on U+2028 / U+2029 — those are valid *inside* JSON strings,
--     and a generic line reader that treats them as separators will corrupt
--     any message containing one

local M = {}

---@class fieldguide.Framer
---@field private _rest string
local Framer = {}
Framer.__index = Framer

---@return fieldguide.Framer
function M.new()
  return setmetatable({ _rest = "" }, Framer)
end

---Feed one raw read. Returns whatever complete lines it completed, and keeps
---the trailing partial line for next time.
---@param chunk string?
---@return string[]
function Framer:feed(chunk)
  if not chunk or chunk == "" then
    return {}
  end

  local data = self._rest .. chunk
  local lines = {}
  local start = 1

  while true do
    local nl = data:find("\n", start, true) -- plain find: no patterns, no Unicode
    if not nl then
      break
    end
    local line = data:sub(start, nl - 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line ~= "" then
      table.insert(lines, line)
    end
    start = nl + 1
  end

  self._rest = data:sub(start)
  return lines
end

---Anything left after the process closes its stdout. A well-behaved agent ends
---on a newline and this is empty; a crashed one may not, and silently dropping
---its last message would make the crash harder to read.
---@return string?
function Framer:flush()
  local rest = self._rest
  self._rest = ""
  if rest:sub(-1) == "\r" then
    rest = rest:sub(1, -2)
  end
  return rest ~= "" and rest or nil
end

---How much is buffered but not yet a line. A number that only grows means the
---far side stopped emitting newlines.
---@return integer
function Framer:pending()
  return #self._rest
end

---Decode one framed line. Never throws: a malformed line is a fact about the
---stream, and the caller needs it as data rather than as an error.
---@param line string
---@return table?, string?
function M.decode(line)
  local ok, value = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok then
    return nil, tostring(value)
  end
  if type(value) ~= "table" then
    return nil, "expected a JSON object, got " .. type(value)
  end
  return value, nil
end

---@param value table
---@return string
function M.encode(value)
  return vim.json.encode(value) .. "\n"
end

return M
