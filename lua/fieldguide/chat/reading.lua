-- Reading the transcript: moving through it, and acting on what is in it.
--
-- The transcript is not a file you are editing, it is a page you are reading,
-- and the two want different keys. This module owns the two places that
-- difference shows: `j`/`k`, which advance through an answer rather than
-- through a line, and the commands the agent writes, which are worth being one
-- keystroke from the command line instead of retyped.
--
-- Both are driven off extmarks so that expanding a tool block, which inserts
-- lines into the middle of the buffer, moves everything with it.

local M = {}

-- Where each turn starts. Separate from the fold and paint namespaces: this one
-- is queried for *the nearest mark before a row*, which is a question the
-- others would answer wrongly.
local NS_TURN = vim.api.nvim_create_namespace("fieldguide.chat.turn")
local NS_RUN = vim.api.nvim_create_namespace("fieldguide.chat.run")
local NS_CUR = vim.api.nvim_create_namespace("fieldguide.chat.current")

-- Fences whose contents are Ex commands, and so worth offering to run. Anything
-- else in the transcript is prose, code for a config file, or shell — none of
-- which belongs on the command line.
local RUN_LANGS = { vim = true, viml = true, vimscript = true, ex = true }

---Mark a row as the start of a turn.
---
---Left gravity, which is the whole difference between this working and not. The
---agent's reply is marked on the empty line it is about to start on, and the
---sink writes by replacing that line with everything joined onto it — so a mark
---with the default gravity is carried to the *end* of the answer, and `j` lands
---on the bottom of a reply instead of its top. Your own turns are marked on
---lines that already have text and are never rewritten, which is why they
---looked fine while replies did not.
---@param buf integer
---@param row integer 0-indexed
function M.mark_turn(buf, row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local last = math.max(0, vim.api.nvim_buf_line_count(buf) - 1)
  vim.api.nvim_buf_set_extmark(buf, NS_TURN, math.min(row, last), 0, { right_gravity = false })
end

---@param buf integer
---@return integer[] 0-indexed rows, ascending
local function turn_rows(buf)
  local rows, seen = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS_TURN, 0, -1, {})) do
    if not seen[mark[2]] then
      seen[mark[2]] = true
      table.insert(rows, mark[2])
    end
  end
  table.sort(rows)
  return rows
end

---Which turn a row belongs to, and where that turn ends.
---@param rows integer[]
---@param row integer
---@param last integer
---@return integer index 0 when the row is above the first turn
---@return integer start
---@return integer stop
local function turn_at(rows, row, last)
  local idx = 0
  for i, r in ipairs(rows) do
    if r <= row then
      idx = i
    else
      break
    end
  end
  local start = idx > 0 and rows[idx] or 0
  local stop = rows[idx + 1] and rows[idx + 1] - 1 or last
  return idx, start, stop
end

---`j` and `k`, for reading rather than editing.
---
---The page moves only when it has to. An answer taller than the window has to
---be scrolled to be read at all, so that is what the key does while there is
---more of it below the fold; once its end is on screen there is nothing further
---to scroll to and the same key moves on. Landing on a turn that is already
---whole on the page moves the cursor and leaves the page where it is — a reply
---you can already see should not jump under you just because you pressed `j`.
---
---There is no mode to be in: the arrow keys, `gj` and `<C-e>` are all still
---ordinary motion.
---@param buf integer
---@param win integer
---@param delta 1|-1
---@return boolean moved
---@return integer[]? rows the turn starts computed along the way, for callers
---  (`mark_current`) that would otherwise have to fetch every mark again
function M.step_turn(buf, win, delta)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  local rows = turn_rows(buf)
  if #rows == 0 then
    return false
  end

  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  local height = math.max(1, vim.api.nvim_win_get_height(win))
  local step = math.max(1, math.floor(height / 2))
  local last = math.max(0, vim.api.nvim_buf_line_count(buf) - 1)
  local top = view.topline - 1
  local bot = math.min(last, top + height - 1)
  local idx, start, stop = turn_at(rows, view.lnum - 1, last)

  ---Put the cursor on a row with the page at a chosen line. `topline` is always
  ---passed, including when it is the one already showing: leaving it out lets
  ---`scrolloff` move the page on its own, which is the thing being avoided.
  ---@param row integer
  ---@param new_top integer
  local function place(row, new_top)
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = new_top + 1, lnum = row + 1, col = 0 })
    end)
  end

  -- More of the turn you are on than the window can hold: read it, do not leave
  -- it. Clamped so the last screenful is the end of the turn rather than a
  -- screen of the next one.
  local reach = delta > 0 and math.max(start, stop - height + 1) or start
  if delta > 0 and stop > bot then
    local want = math.min(top + step, reach)
    if want > top then
      place(want, want)
      return true, rows
    end
  elseif delta < 0 and start < top then
    local want = math.max(top - step, reach)
    if want < top then
      place(want, want)
      return true, rows
    end
  end

  local target = rows[idx + delta]
  if not target then
    -- At the far end with nothing left to scroll to. Saying so lets the caller
    -- fall through to an ordinary `j`, rather than this scrolling backwards to
    -- show a tail that is already on the page.
    return false, rows
  end

  local _, _, target_stop = turn_at(rows, target, last)
  local fits = target >= top and target_stop <= bot
  place(target, fits and top or target)
  return true, rows
end

-- What each marked row would run, keyed by the extmark that marks it. The text
-- is decided once, at scan time, rather than re-derived from the line on every
-- keypress: an inline command is a span inside a sentence, and the sentence is
-- not the command.
local commands = setmetatable({}, { __mode = "k" })

---Strip a command down to what is safe to put on the command line.
---
---Control bytes go first. The whole claim of this feature is that it loads a
---command rather than running one, and a carriage return anywhere in the text
---would end the command line for us — which is the one way a line of somebody
---else's help text could turn this key into one that executes.
---@param text string
---@return string?
local function clean(text)
  local cmd = vim.trim((text:gsub("%c", ""))):gsub("^:", "")
  return cmd ~= "" and cmd or nil
end

-- Where `scan` left off: the line count it last saw and the fence it was
-- inside of at that point. Streaming calls `scan` at 4Hz on a transcript that
-- only ever grows, so re-walking lines already scanned is wasted work — kept
-- here rather than derived from extmarks because the fence state (which
-- language, if any, the last line was inside of) is not itself markable.
local scanned = setmetatable({}, { __mode = "k" })

---Find the Ex commands the agent wrote, and put a marker on each.
---
---Two shapes, because models write both and only accepting one would mean the
---key almost never fires: a line inside a fence whose language says Ex
---commands, and a code span that begins with a colon. The colon is what makes
---the second one safe to guess at — `:Telescope live_grep` is unambiguous where
---a bare span like `<Space><Space>` is a key, a path or a plugin name.
---@param buf integer
---@param force boolean? rescan from the top, e.g. after a rewrite that is not
---  a pure append (`begin_block` replacing the last line, a fold collapsing)
function M.scan(buf, force)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local function mark(row, cmd)
    local id = vim.api.nvim_buf_set_extmark(buf, NS_RUN, row, 0, {
      virt_text = { { "  ▶", "FieldguideRun" } },
      virt_text_pos = "eol",
      -- Left gravity, same reasoning as `mark_turn`: the sink can still
      -- rewrite this line (replace, not append) before the mark's row is
      -- revisited, and the default gravity would carry the mark past the end
      -- of the rewrite instead of leaving it where the incremental rescan
      -- above expects to find and clear it.
      right_gravity = false,
    })
    commands[buf][id] = cmd
  end

  local count = vim.api.nvim_buf_line_count(buf)
  local prev = scanned[buf]
  local from, lang
  -- Only a plain append can be picked up incrementally: anything that shrank
  -- the buffer (a clear, a replaced tail) needs the marks it may have
  -- invalidated redone from scratch, which a partial walk cannot tell apart
  -- from a genuine append.
  if not force and prev and prev.count > 0 and prev.count <= count then
    -- The last line seen before may have grown in place since (the sink
    -- rewrites the current line rather than always ending it), so it is
    -- re-walked rather than skipped — any mark it earned last time is dropped
    -- first so re-evaluating it cannot leave a stale duplicate behind.
    from, lang = prev.count, prev.lang
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, NS_RUN, { from - 1, 0 }, { from - 1, -1 }, {})) do
      vim.api.nvim_buf_del_extmark(buf, NS_RUN, m[1])
      commands[buf][m[1]] = nil
    end
  else
    vim.api.nvim_buf_clear_namespace(buf, NS_RUN, 0, -1)
    commands[buf] = {}
    from, lang = 1, nil
  end

  local lang_before_last = lang
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, from - 1, count, false)) do
    row = row + from - 1
    if row == count then
      lang_before_last = lang
    end
    -- Four spaces of indent is an indented code block, which is what tool
    -- lines and their expanded bodies are — a fence inside one is text, not
    -- a fence.
    local indent, info = line:match("^(%s*)```+%s*([%w_%-]*)")
    if info and #indent < 4 then
      lang = lang == nil and info:lower() or nil
    elseif lang and RUN_LANGS[lang] then
      local cmd = clean(line)
      if cmd then
        mark(row - 1, cmd)
      end
    elseif lang == nil then
      -- The first span on the line. More than one command in a sentence is
      -- rare enough that offering the first beats offering a choice nobody
      -- asked for.
      local span = line:match("`:([^`]+)`")
      local cmd = span and clean(span)
      if cmd then
        mark(row - 1, cmd)
      end
    end
  end

  -- Stored as the state *before* the last line, not after: that line may
  -- still be growing in place, so next time it is re-walked rather than
  -- trusted.
  scanned[buf] = { count = count, lang = lang_before_last }
end

---The command on a row, if that row carries one.
---@param buf integer
---@param row integer 0-indexed
---@return string?
function M.command_at(buf, row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, NS_RUN, { row, 0 }, { row, -1 }, {})
  for _, m in ipairs(marks) do
    local cmd = (commands[buf] or {})[m[1]]
    if cmd then
      return cmd
    end
  end
  return nil
end

-- Which turn is already drawn as the current one, so that moving the cursor
-- around inside a turn costs nothing.
local drawn = setmetatable({}, { __mode = "k" })

---Bracket the turn the cursor is in.
---
---A bar down the sign column rather than a background across the message: a
---turn can be a hundred lines long, and tinting all of them would make the
---thing you are reading the loudest thing on the screen instead of the clearest.
---@param buf integer
---@param win integer
---@param rows integer[]? turn starts already computed by the caller (e.g.
---  `step_turn`). Omit it and `mark_current` finds the containing turn on its
---  own, with two bounded extmark queries rather than fetching and sorting
---  every turn mark in the buffer on every `CursorMoved`.
function M.mark_current(buf, win, rows)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local last = math.max(0, vim.api.nvim_buf_line_count(buf) - 1)
  local cursor = vim.api.nvim_win_get_cursor(win)[1] - 1

  local start, stop
  if rows then
    local idx
    idx, start, stop = turn_at(rows, cursor, last)
    if idx == 0 then
      start = nil
    end
  else
    -- The nearest turn mark at or before the cursor: querying backward from
    -- the cursor with limit=1 finds it directly, rather than walking every
    -- mark in the buffer to throw away all but one.
    local before = vim.api.nvim_buf_get_extmarks(buf, NS_TURN, { cursor, 0 }, { 0, 0 }, { limit = 1 })
    if #before > 0 then
      start = before[1][2]
      local after = vim.api.nvim_buf_get_extmarks(buf, NS_TURN, { start + 1, 0 }, { -1, -1 }, { limit = 1 })
      stop = #after > 0 and after[1][2] - 1 or last
    end
  end

  if not start then
    -- Above the first turn there is nothing to be inside of.
    if drawn[buf] then
      vim.api.nvim_buf_clear_namespace(buf, NS_CUR, 0, -1)
      drawn[buf] = nil
    end
    return
  end

  local key = ("%d:%d"):format(start, stop)
  if drawn[buf] == key then
    return
  end
  drawn[buf] = key

  vim.api.nvim_buf_clear_namespace(buf, NS_CUR, 0, -1)
  for row = start, math.min(stop, last) do
    vim.api.nvim_buf_set_extmark(buf, NS_CUR, row, 0, {
      sign_text = "▎",
      sign_hl_group = "FieldguideCurrent",
    })
  end
end

---Forget everything known about a buffer, for a transcript being replaced.
---@param buf integer
function M.clear(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, ns in ipairs({ NS_TURN, NS_RUN, NS_CUR }) do
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  commands[buf] = nil
  drawn[buf] = nil
  scanned[buf] = nil
end

---@param buf integer
---@return integer[] where the turns start, for tests
function M.turns(buf)
  return turn_rows(buf)
end

---@param buf integer
---@return integer count of turn marks, for tests
function M.turn_count(buf)
  return #turn_rows(buf)
end

---@param buf integer
---@return integer count of runnable lines, for tests
function M.runnable_count(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, NS_RUN, 0, -1, {})
end

return M
