-- The buffer appender. Where "every token became its own line" lives.
--
--   nvim -l tests/sink.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local sink = require("fieldguide.chat.sink")

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

local function fresh()
  local buf = vim.api.nvim_create_buf(false, true)
  return buf, sink.new(buf)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

io.write("streaming into a buffer\n")

do
  local buf, s = fresh()
  -- The shape a real stream arrives in: fragments that ignore line boundaries.
  s:write("hel")
  s:write("lo\nwor")
  s:write("ld")
  s:flush()
  check(
    "fragments reassemble across line boundaries",
    vim.deep_equal(lines(buf), { "hello", "world" }),
    vim.inspect(lines(buf))
  )
end

do
  local buf, s = fresh()
  for _, tok in ipairs({ "The ", "quick ", "brown ", "fox" }) do
    s:write(tok)
    s:flush() -- flush per token: the pathological case
  end
  check(
    "flushing per token still yields one line",
    vim.deep_equal(lines(buf), { "The quick brown fox" }),
    vim.inspect(lines(buf))
  )
end

do
  local buf, s = fresh()
  s:write("a\nb\nc\n")
  s:flush()
  check(
    "a trailing newline leaves an empty final line",
    vim.deep_equal(lines(buf), { "a", "b", "c", "" }),
    vim.inspect(lines(buf))
  )
  s:write("d")
  s:flush()
  check(
    "...which the next write continues",
    vim.deep_equal(lines(buf), { "a", "b", "c", "d" }),
    vim.inspect(lines(buf))
  )
end

do
  local buf, s = fresh()
  check("flushing nothing is a no-op", s:flush() == false)
  check("...and leaves the buffer alone", vim.deep_equal(lines(buf), { "" }), vim.inspect(lines(buf)))
  check("dirty is false when idle", s:dirty() == false)
  s:write("x")
  check("...and true once written to", s:dirty() == true)
end

do
  local buf, s = fresh()
  s:write("first")
  s:ensure_newline()
  s:write("second")
  s:flush()
  check("ensure_newline breaks the line", vim.deep_equal(lines(buf), { "first", "second" }), vim.inspect(lines(buf)))

  s:ensure_newline()
  s:ensure_newline()
  s:write("third")
  s:flush()
  check(
    "...and does not stack blank lines",
    vim.deep_equal(lines(buf), { "first", "second", "third" }),
    vim.inspect(lines(buf))
  )
end

do
  local buf, s = fresh()
  s:flush()
  s:ensure_newline()
  s:write("x")
  s:flush()
  check(
    "ensure_newline on an empty buffer adds no leading blank",
    vim.deep_equal(lines(buf), { "x" }),
    vim.inspect(lines(buf))
  )
end

io.write("large and awkward payloads\n")

do
  local buf, s = fresh()
  local big = string.rep("y", 20000)
  s:write(big)
  s:flush()
  check("a 20KB single-line write lands intact", #(lines(buf)[1] or "") == 20000, tostring(#(lines(buf)[1] or "")))
end

do
  local buf, s = fresh()
  for i = 1, 500 do
    s:write(("line %d\n"):format(i))
  end
  s:flush()
  local l = lines(buf)
  check("500 lines in one flush", #l == 501, tostring(#l))
  check("...in order", l[1] == "line 1" and l[500] == "line 500", ("%s / %s"):format(l[1], l[500]))
end

do
  local buf, s = fresh()
  -- CRLF from a tool that shells out on a Windows-ish target: must not become
  -- a stray ^M line of its own.
  s:write("a\r\nb")
  s:flush()
  check("CRLF does not create an extra line", #lines(buf) == 2, vim.inspect(lines(buf)))
end

io.write("windows and the reading user\n")

do
  local buf, s = fresh()
  local win = vim.api.nvim_open_win(buf, false, { relative = "editor", width = 40, height = 10, row = 1, col = 1 })

  s:write("one\ntwo\nthree\n")
  s:flush()
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })

  s:write("four\n")
  s:flush()
  check(
    "a window at the tail follows new output",
    vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf),
    vim.inspect(vim.api.nvim_win_get_cursor(win))
  )

  -- Scroll back, as someone re-reading would.
  vim.api.nvim_win_set_cursor(win, { 2, 0 })
  s:write("five\nsix\n")
  s:flush()
  check(
    "a window scrolled back is left alone",
    vim.api.nvim_win_get_cursor(win)[1] == 2,
    vim.inspect(vim.api.nvim_win_get_cursor(win))
  )

  vim.api.nvim_win_close(win, true)
end

io.write("buffer protection\n")

do
  local buf, s = fresh()
  vim.bo[buf].modifiable = false
  s:write("written anyway\n")
  s:flush()
  check("a nomodifiable buffer is still written", lines(buf)[1] == "written anyway", vim.inspect(lines(buf)))
  check("...and left nomodifiable afterwards", vim.bo[buf].modifiable == false)
end

do
  local buf, s = fresh()
  vim.api.nvim_buf_delete(buf, { force = true })
  s:write("into the void")
  local ok = pcall(function()
    return s:flush()
  end)
  check("writing to a deleted buffer does not throw", ok)
  check("...and drops the pending text", s:dirty() == false)
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
