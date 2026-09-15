-- JSONL framing. The suite that decides whether the renderer ever sees a
-- corrupt message.
--
--   nvim -l tests/framing.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local framing = require("fieldguide.rpc.framing")

local passed, failed = 0, 0
local function check(name, ok, detail)
  if ok then
    passed = passed + 1
    io.write(("  ok   %s\n"):format(name))
  else
    failed = failed + 1
    io.write(("  FAIL %s\n       %s\n"):format(name, detail or ""))
  end
end

---Feed a whole payload in fixed-size slices, to simulate arbitrary read sizes.
---@param payload string
---@param size integer
---@return string[]
local function feed_in_slices(payload, size)
  local f = framing.new()
  local out = {}
  for i = 1, #payload, size do
    vim.list_extend(out, f:feed(payload:sub(i, i + size - 1)))
  end
  local rest = f:flush()
  if rest then
    table.insert(out, rest)
  end
  return out
end

io.write("framing\n")

do
  local f = framing.new()
  check("a whole line in one chunk", #f:feed('{"a":1}\n') == 1)
  check("nothing buffered afterwards", f:pending() == 0, tostring(f:pending()))
end

do
  local f = framing.new()
  local first = f:feed('{"type":"mess')
  check("a partial line yields nothing", #first == 0, vim.inspect(first))
  check("...and is held", f:pending() > 0)
  local second = f:feed('age_update"}\n')
  check("the completion joins across the boundary", #second == 1, vim.inspect(second))
  check("...into the original object", second[1] == '{"type":"message_update"}', second[1] or "")
end

do
  local f = framing.new()
  local lines = f:feed('{"a":1}\n{"b":2}\n{"c":3}\n')
  check("several lines in one chunk", #lines == 3, vim.inspect(lines))
end

do
  local f = framing.new()
  f:feed('{"a":1}\n{"b"')
  local lines = f:feed(":2}\n")
  check("a chunk that both completes and starts a line", #lines == 1 and lines[1] == '{"b":2}', vim.inspect(lines))
end

do
  local f = framing.new()
  local lines = f:feed('{"a":1}\r\n{"b":2}\r\n')
  check("CRLF is tolerated", #lines == 2 and lines[1] == '{"a":1}', vim.inspect(lines))
end

do
  local f = framing.new()
  local lines = f:feed('\n\n{"a":1}\n\n')
  check("blank lines are dropped, not decoded", #lines == 1, vim.inspect(lines))
end

-- The reason pi's docs call out framing at all. U+2028 and U+2029 are valid
-- inside JSON strings; a line reader that splits on them corrupts the message.
do
  local u2028 = "\226\128\168"
  local u2029 = "\226\128\169"
  local payload = '{"delta":"before' .. u2028 .. "mid" .. u2029 .. 'after"}\n'
  local f = framing.new()
  local lines = f:feed(payload)
  check("U+2028 / U+2029 are not line separators", #lines == 1, vim.inspect(lines))
  local decoded = framing.decode(lines[1] or "")
  check(
    "...and the string survives decoding",
    decoded and decoded.delta:find("mid", 1, true) ~= nil,
    vim.inspect(decoded)
  )
end

-- An escaped \n inside a JSON string is two bytes, not a newline; a literal one
-- would be invalid JSON. Guard the common confusion anyway.
do
  local f = framing.new()
  local lines = f:feed('{"text":"line one\\nline two"}\n')
  check("an escaped newline inside a string is not a break", #lines == 1, vim.inspect(lines))
  local decoded = framing.decode(lines[1])
  check("...and decodes to a real newline", decoded and decoded.text == "line one\nline two", vim.inspect(decoded))
end

-- The load case: one big message, every possible slice size.
do
  local big = string.rep("x", 20000)
  local payload = '{"type":"message_update","delta":"' .. big .. '"}\n'
  for _, size in ipairs({ 1, 2, 3, 7, 64, 997, 4096, 65536 }) do
    local lines = feed_in_slices(payload, size)
    local ok = #lines == 1
    local decoded = ok and framing.decode(lines[1]) or nil
    check(
      ("a 20KB message survives %d-byte reads"):format(size),
      ok and decoded ~= nil and #decoded.delta == #big,
      ("lines=%d"):format(#lines)
    )
  end
end

-- Many messages, byte at a time. This is the shape of a real streaming turn.
do
  local parts = {}
  for i = 1, 200 do
    table.insert(
      parts,
      ('{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"tok%d"}}'):format(
        i
      )
    )
  end
  local payload = table.concat(parts, "\n") .. "\n"
  local lines = feed_in_slices(payload, 1)
  check("200 messages reassemble from 1-byte reads", #lines == 200, ("got %d"):format(#lines))
  local last = lines[200] and framing.decode(lines[200])
  check("...in order, intact", last and last.assistantMessageEvent.delta == "tok200", vim.inspect(last))
end

do
  local f = framing.new()
  f:feed('{"truncated":')
  local rest = f:flush()
  check("flush surfaces a trailing partial line", rest == '{"truncated":', tostring(rest))
  check("...and clears it", f:flush() == nil)
end

io.write("decode\n")
do
  local value, err = framing.decode('{"type":"agent_start"}')
  check("a good line decodes", value ~= nil and value.type == "agent_start", tostring(err))

  local bad, bad_err = framing.decode("{not json")
  check("a malformed line returns an error, never throws", bad == nil and bad_err ~= nil, tostring(bad_err))

  local scalar, scalar_err = framing.decode("42")
  check("a non-object is rejected", scalar == nil and scalar_err ~= nil, tostring(scalar_err))

  -- vim.json turns JSON null into vim.NIL by default, which silently poisons
  -- table lookups downstream. luanil makes absent mean absent.
  local nulled = framing.decode('{"a":null,"b":1}')
  check("JSON null becomes nil, not vim.NIL", nulled ~= nil and nulled.a == nil and nulled.b == 1, vim.inspect(nulled))
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
