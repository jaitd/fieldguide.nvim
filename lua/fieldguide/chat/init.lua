-- The chat panel: two normal buffers, no terminal.
--
-- Output is a markdown buffer written by the sink; input is a separate,
-- editable buffer. Keeping them separate is what makes normal-mode keymaps work
-- everywhere: no key belongs to a child process, so there is no terminal mode
-- to escape from.
--
-- Everything the agent says arrives as fieldguide events, never as escape
-- sequences, so there is no emulator in this path at all.

local cfg = require("fieldguide.config")
local events = require("fieldguide.rpc.events")
local rpc = require("fieldguide.rpc")
local history = require("fieldguide.chat.history")
local reading = require("fieldguide.chat.reading")
local sink = require("fieldguide.chat.sink")

local M = {}

local state = {
  out_buf = nil,
  in_buf = nil,
  out_win = nil,
  in_win = nil,
  session = nil,
  sink = nil,
  timer = nil,
  unsub = nil,
  status = "idle",
  -- Which content block we are inside, so a switch between prose, thinking and
  -- a tool call can insert a separator without guessing.
  block = nil,
  -- tool_call_id -> arguments, carried from the start event to the end one.
  tool_args = {},
  -- Set when you send, cleared when the agent first answers, so the reply gets
  -- a turn mark of its own without every block inside it getting one too.
  awaiting_reply = false,
  -- The last badly-ended message we announced, so the pair of events that
  -- carries it does not announce it twice.
  last_outcome = nil,
  -- When the transcript was last searched for runnable commands.
  scanned_at = nil,
  -- The size the panel should be: the configured one until you resize it, and
  -- the one you chose after that.
  width = nil,
  prompt_height = nil,
  -- Wall clock for the elapsed counter, and the frame the spinner is on.
  busy_since = nil,
  spun_at = nil,
  spin = 1,
  -- Prompts already sent, oldest first, with the in-progress draft parked at
  -- the end while you page back through them.
  history = {},
  history_idx = nil,
  history_draft = nil,
}

-- Two namespaces, because they answer different questions. NS tracks *which*
-- lines are foldable tool summaries and is queried by position; NS_HL only
-- paints. Sharing one would make a colour extmark indistinguishable from a fold
-- anchor in a positional lookup.
local NS = vim.api.nvim_create_namespace("fieldguide.chat")
local NS_HL = vim.api.nvim_create_namespace("fieldguide.chat.hl")
local NS_PROMPT = vim.api.nvim_create_namespace("fieldguide.chat.prompt")

local NAME = "fieldguide"

-- Shown over the prompt while it is empty. Both bindings are worth naming: Enter
-- sending is the surprising half of a text box that is also a Vim buffer, and
-- Shift+Enter is undiscoverable otherwise.
local PLACEHOLDER = "Ask about this Neovim · Enter sends · Shift+Enter for a new line"

---Write to one of our buffers regardless of what else has been done to it.
---
---A real config is full of plugins that reach for `vim.bo[buf].modifiable =
---false` on buffers they did not create — `buftype=nofile` attracts this. The
---panel cannot assume the buffers it made are still as it left them, and the
---failure is nasty when it happens: submitting silently throws inside a timer
---callback and the prompt just stops working.
---@param buf integer
---@param fn fun()
local function with_modifiable(buf, fn)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = was
  if not ok then
    error(err, 0)
  end
end

---@return table
local function opts()
  return cfg.options.chat or {}
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

---The transcript's winbar is the panel's nameplate: which tool this is, and
---which model is answering. It never changes, which is what makes the prompt's
---winbar readable as activity rather than as decoration.
local function set_title()
  if not (state.out_win and vim.api.nvim_win_is_valid(state.out_win)) then
    return
  end
  local model = cfg.options.model
  local right = model and (" " .. (tostring(model):gsub("%%", "%%%%")) .. " ") or ""
  vim.wo[state.out_win].winbar = "%#FieldguideTitle# " .. NAME .. "%*%=%#FieldguideSession#" .. right
end

-- One frame per tick of the spinner. Braille cells, which every font that can
-- draw a Neovim UI already has.
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPIN_MS = 100

---@param text string
---@return boolean
local function quiet_status(text)
  return text == "idle" or text == "" or text == "stopped"
end

---The prompt's winbar carries what the agent is doing, and nothing when it is
---doing nothing. A permanent "idle" is a label, not information.
---
---Nothing means a blank row, not an absent one. A winbar set to the empty
---string is not drawn at all, so a status that came and went took a line of the
---prompt with it each time and shunted everything you were typing up and down.
---The row is always there; only what is written on it changes.
---
---While it is doing something it carries how long for. "thinking" and "thinking,
---still, ninety seconds in" are different situations and the word alone cannot
---tell them apart.
local function draw_status()
  if not (state.in_win and vim.api.nvim_win_is_valid(state.in_win)) then
    return
  end
  if quiet_status(state.status) then
    vim.wo[state.in_win].winbar = " "
    return
  end
  local secs = state.busy_since and math.floor((vim.uv.now() - state.busy_since) / 1000) or 0
  vim.wo[state.in_win].winbar = ("%%#Comment#%s %s %ds"):format(
    SPINNER[state.spin],
    (state.status:gsub("%%", "%%%%")),
    secs
  )
end

local function set_status(text)
  local was_quiet = quiet_status(state.status)
  state.status = text
  -- The clock runs for as long as the agent is busy, not per status change: a
  -- turn that goes thinking → running grep → thinking is one wait, and resetting
  -- to zero at each step would hide exactly the case worth seeing.
  if quiet_status(text) then
    state.busy_since = nil
  elseif was_quiet or not state.busy_since then
    state.busy_since = vim.uv.now()
    state.spin = 1
  end
  draw_status()
end

---Advance the spinner and the clock. Called from the flush timer, so it costs
---nothing when there is no session.
local function tick_status()
  if quiet_status(state.status) then
    return
  end
  local now = vim.uv.now()
  if state.spun_at and now - state.spun_at < SPIN_MS then
    return
  end
  state.spun_at = now
  state.spin = (state.spin % #SPINNER) + 1
  draw_status()
end

---An empty prompt says what it is for. Cleared the moment anything is typed,
---so it can never be mistaken for text that will be sent.
local function set_placeholder()
  local buf = state.in_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS_PROMPT, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines > 1 or (lines[1] or "") ~= "" then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, NS_PROMPT, 0, 0, {
    virt_text = { { PLACEHOLDER, "FieldguidePlaceholder" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
end

-- ---------------------------------------------------------------------------
-- Buffers
-- ---------------------------------------------------------------------------

local function make_output_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "markdown" -- render-markdown.nvim et al. pick this up
  vim.bo[buf].modifiable = false
  -- Every flush would otherwise be an undo state, and a long session would grow
  -- an undo tree nobody will ever use.
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_name(buf, "fieldguide://chat")
  return buf
end

local function make_input_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  -- Markdown for highlighting while composing, but in-buffer *rendering* is
  -- turned off here if it is installed: an input that conceals characters and
  -- reflows as you leave insert mode is disorienting to type into. The
  -- transcript, which is read rather than written, keeps it.
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "fieldguide://prompt")

  local ok, render_markdown = pcall(require, "render-markdown")
  if ok and type(render_markdown.set_buf) == "function" then
    vim.api.nvim_buf_call(buf, function()
      pcall(render_markdown.set_buf, false)
    end)
  end
  return buf
end

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------

-- What each tool line is: the detail collapsed behind it, and the file it was
-- about. Keyed by the extmark that tracks the summary line — an extmark rather
-- than a line number because the buffer keeps growing underneath them.
---@type table<integer, { body: string[]?, expanded: boolean, target: fieldguide.ToolTarget? }>
local blocks = {}

-- Four spaces makes a run of tool lines an indented code block, and markdown
-- does no inline parsing inside one.
--
-- This is not cosmetic. Consecutive tool lines are otherwise a single markdown
-- paragraph, so a `~` in one path pairs with the `~` in the next and everything
-- between them is struck through; `_` in two filenames italicises three lines of
-- transcript. The characters that do this — `*_~`` `[]` — are exactly the ones
-- that turn up in paths and grep patterns, so escaping them would put a visible
-- backslash in front of half the output. Making the block unparseable costs four
-- columns and nothing else. render-markdown only styles *fenced* blocks, so it
-- leaves these alone too.
local TOOL_INDENT = "    "

---Paint a range of a line. Above treesitter (100) and above render-markdown, so
---a tool line stays dim whatever else has an opinion about it.
---@param row integer 0-indexed
---@param col integer
---@param end_col integer
---@param hl string
local function paint(row, col, end_col, hl)
  if end_col <= col then
    return
  end
  vim.api.nvim_buf_set_extmark(state.out_buf, NS_HL, row, col, {
    end_row = row,
    end_col = end_col,
    hl_group = hl,
    priority = 300,
  })
end

---Render a completed tool call: one summary line, detail collapsed behind it.
---
---The line is deliberately not a markdown list item. The agent writes bullet
---lists of its own, and a tool call that renders as one more bullet is a tool
---call the eye has to read to classify.
---@param event fieldguide.Event
function M.append_tool(event)
  local tools = require("fieldguide.chat.tools")
  if not event.args and event.tool_call_id then
    event.args = state.tool_args[event.tool_call_id]
  end
  local rendered = tools.render(event, opts().max_tool_lines or 40)
  local icon, icon_hl = tools.icon(rendered.status)

  -- The blank line above a tool run is load-bearing, not spacing: an indented
  -- code block cannot interrupt a paragraph, so a tool line written directly
  -- under prose is parsed as more of that paragraph and the markdown protection
  -- silently stops applying. Guaranteed here rather than left to the caller.
  state.sink:ensure_newline()
  state.sink:flush()
  local above = state.sink:last_written_line()
  if above ~= "" and not vim.startswith(above, TOOL_INDENT) then
    state.sink:write("\n")
  end

  state.sink:writeln(TOOL_INDENT .. icon .. " " .. rendered.summary)
  state.sink:flush() -- the extmark needs the line to exist

  -- writeln leaves a trailing empty line behind, so the summary is the line
  -- before the last one.
  local row = math.max(0, vim.api.nvim_buf_line_count(state.out_buf) - 2)
  local col = #TOOL_INDENT
  paint(row, col, col + #icon, icon_hl)
  paint(row, col + #icon, col + #icon + 1 + #rendered.summary, "FieldguideTool")

  local body = rendered.body
  if body and #body == 0 then
    body = nil
  end

  -- Every tool line gets an extmark, not only the foldable ones: it is also
  -- what anchors the file this call was about, so `gf` works on a line with
  -- nothing collapsed behind it.
  local mark = vim.api.nvim_buf_set_extmark(state.out_buf, NS, row, 0, {
    virt_text = body and { { "  ▸ " .. #body .. " lines", "FieldguideTool" } } or nil,
    virt_text_pos = body and "eol" or nil,
  })
  blocks[mark] = { body = body, expanded = false, target = rendered.target }
end

---The block whose summary line the cursor is on, if any.
---@return integer? id, integer? row, table? block
local function block_at_cursor()
  if not state.out_buf or not vim.api.nvim_buf_is_valid(state.out_buf) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.out_buf, NS, { row, 0 }, { row, -1 }, {})) do
    if blocks[mark[1]] then
      return mark[1], mark[2], blocks[mark[1]]
    end
  end
  return nil
end

---A window that is not part of the panel, because opening a file into the
---sidebar is never what anyone meant.
---@return integer?
local function editor_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf ~= state.out_buf and buf ~= state.in_buf and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  return nil
end

-- Rescanning the whole transcript for commands is cheap, but not at the flush
-- rate on a buffer that is still growing. Four times a second keeps the markers
-- honest while an answer streams in.
local SCAN_MS = 250

---@param force boolean?
local function rescan(force)
  if not (state.out_buf and vim.api.nvim_buf_is_valid(state.out_buf)) then
    return
  end
  local now = vim.uv.now()
  if not force and state.scanned_at and now - state.scanned_at < SCAN_MS then
    return
  end
  state.scanned_at = now
  reading.scan(state.out_buf)
end

---Put the command under the cursor on the command line, ready to run.
---
---Loaded, not run. The agent reads tens of thousands of lines of third-party
---help text on its own and with nobody watching, and a key that executed
---whatever came back would leave nothing between that and this editor. What is
---worth automating here is the retyping, not the deciding: you read the line,
---you press Enter.
function M.run_command()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cmd = reading.command_at(state.out_buf, row)
  if not cmd then
    vim.notify("fieldguide: no command on this line", vim.log.levels.INFO)
    return
  end
  -- Commands the agent writes are about your editor, not about the panel:
  -- `:Telescope live_grep` run from in here would open into the sidebar.
  local win = editor_win()
  if win then
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_feedkeys(":" .. cmd, "n", false)
end

---Open the file a tool call was about. The transcript names paths it is worth
---being able to act on — an `edit` line is a claim about a file, and checking
---it should not mean retyping the path.
function M.open_target()
  local _, _, block = block_at_cursor()
  local target = block and block.target
  if not target then
    return
  end
  local win = editor_win()
  if not win then
    vim.notify("fieldguide: no window to open " .. target.path .. " into", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(target.path))
  if target.line then
    pcall(vim.api.nvim_win_set_cursor, win, { target.line, 0 })
    vim.cmd("normal! zz")
  end
end

---Mark where one session ends and the next begins. Just the time: the winbar
---above it already says which panel this is, and saying it twice on the first
---two lines of the transcript reads as a stutter.
---
---Written as plain text rather than as markdown emphasis: `_like this_` is
---emphasis to a parser that gets to see it and a pair of stray underscores to
---one that does not, and whether the transcript is rendered is not something
---this plugin gets to decide.
function M.append_session_marker()
  local line = ("session started %s"):format(os.date("%H:%M:%S"))
  state.sink:ensure_newline()
  state.sink:writeln(line)
  state.sink:write("\n")
  state.sink:flush()

  local row = math.max(0, vim.api.nvim_buf_line_count(state.out_buf) - 3)
  paint(row, 0, #line, "FieldguideSession")
  reading.mark_turn(state.out_buf, row)
end

---Toggle the tool block under the cursor.
function M.toggle_fold()
  if not state.out_buf or not vim.api.nvim_buf_is_valid(state.out_buf) then
    return
  end
  local id, mark_row, fold = block_at_cursor()
  if not fold or not fold.body then
    return
  end

  local first, last = mark_row + 1, mark_row + 1 + #fold.body
  vim.bo[state.out_buf].modifiable = true
  if fold.expanded then
    vim.api.nvim_buf_clear_namespace(state.out_buf, NS_HL, first, last)
    vim.api.nvim_buf_set_lines(state.out_buf, first, last, false, {})
  else
    local body = vim.tbl_map(function(line)
      return TOOL_INDENT .. line
    end, fold.body)
    vim.api.nvim_buf_set_lines(state.out_buf, first, first, false, body)
    -- Detail stays as quiet as the summary it came from: expanding a tool block
    -- should not make it the loudest thing on the screen. An edit's diff is the
    -- exception — added and removed lines are the reason you opened it.
    for i, line in ipairs(body) do
      local sign = line:match("^%s*([+-])%d")
      local hl = (sign == "+" and "FieldguideDiffAdd")
        or (sign == "-" and "FieldguideDiffDelete")
        or "FieldguideToolDetail"
      paint(mark_row + i, 0, #line, hl)
    end
  end
  vim.bo[state.out_buf].modifiable = false

  fold.expanded = not fold.expanded
  -- Expanding moved every row below this one, and a marker sitting on the wrong
  -- row would offer to run the wrong line. That is an insert in the middle of
  -- the buffer, not the append `scan`'s incremental path assumes, so this one
  -- has to walk everything again.
  reading.scan(state.out_buf, true)
  vim.api.nvim_buf_set_extmark(state.out_buf, NS, mark_row, 0, {
    id = id,
    virt_text = { { ("  %s %d lines"):format(fold.expanded and "▾" or "▸", #fold.body), "FieldguideTool" } },
    virt_text_pos = "eol",
  })
end

---Move to a new content block, separating it from the previous one.
---
---Tool calls are a block kind like any other, which is what puts a blank line
---between a run of them and the prose on either side while leaving consecutive
---calls tight against each other.
---@param kind string?
local function begin_block(kind)
  if state.block == kind then
    return
  end
  if state.block ~= nil then
    state.sink:ensure_newline()
    state.sink:write("\n")
  end
  state.block = kind

  -- The reply to what you just sent is one turn, however many blocks of prose
  -- and tool calls it turns out to be made of. Flushing here is what makes the
  -- mark land on the row the content is about to start on.
  if kind ~= nil and state.awaiting_reply then
    state.awaiting_reply = false
    state.sink:flush()
    reading.mark_turn(state.out_buf, math.max(0, vim.api.nvim_buf_line_count(state.out_buf) - 1))
  end
end

---Start a prose block, dropping the whitespace models like to lead with.
---
---A turn that resumes after a tool call almost always opens with a space or a
---newline, which lands as an indented first sentence or as a line containing
---nothing but a space. Stripping it only at the start of a block leaves the
---agent's own formatting alone everywhere else, and a delta that was *only*
---whitespace opens no block at all — otherwise the separator would go in ahead
---of content that never arrives.
---@param kind string
---@param text string?
---@return string
local function open_prose(kind, text)
  text = text or ""
  if state.block ~= kind then
    text = text:gsub("^%s+", "")
    if text == "" then
      return ""
    end
  end
  begin_block(kind)
  return text
end

---A reply that ended badly, said out loud.
---
---An agent that cannot answer — a model the account may not use, a
---subscription that has run out, a context that overflowed — still ends its
---message normally, carrying the reason as a field rather than as an error
---event. Left unsaid, the panel goes quiet and back to idle, which reads as the
---question having been swallowed. The reason arrives on both `message_end` and
---`turn_end`, so it is announced once.
---@param event fieldguide.Event
local function report_outcome(event)
  local reason = event.stop_reason
  local text = nil
  if reason == "error" then
    text = ("agent error: %s"):format(event.error or "the model stopped without saying why")
  elseif reason == "length" then
    text = "the reply was cut off at the model's output limit"
  end
  if text == nil then
    return
  end
  -- The same message arrives twice, as its own end and as the turn's. Both
  -- carry the timestamp it was stamped with, which is what tells a repeat of
  -- one message from a second message that failed the same way.
  local key = ("%s/%s"):format(tostring((event.message or {}).timestamp), reason)
  if key == state.last_outcome then
    return
  end
  state.last_outcome = key
  begin_block(nil)
  local s = state.sink
  s:ensure_newline()
  s:writeln(("> **%s**"):format(text))
  set_status("idle")
end

-- Forward-declared: defined alongside the timer it stops, further down, but
-- `on_event`'s exit branch needs to call it too.
local release_timer_and_sub

---@param event fieldguide.Event
local function on_event(event)
  local s = state.sink
  local k = event.kind

  if k == "text_delta" then
    s:write(open_prose("text", event.text))
  elseif k == "thinking_delta" then
    if opts().show_thinking then
      s:write(open_prose("thinking", event.text))
    end
  elseif k == "tool_start" then
    -- Arguments are reliable on the start event; the end event does not always
    -- repeat them, and a renderer with no path to show is worse than useless.
    if event.tool_call_id then
      state.tool_args[event.tool_call_id] = event.args
    end
    -- Nothing in the transcript yet. A tool that is still running has nothing
    -- worth saying, and a placeholder line would have to be rewritten later —
    -- which parallel tool calls make genuinely hard to get right. The status
    -- line carries the "it is working" signal instead.
    set_status("running " .. (event.tool or "tool"))
  elseif k == "tool_end" then
    begin_block("tool")
    M.append_tool(event)
    state.tool_args[event.tool_call_id or ""] = nil
    set_status("thinking")
  elseif k == "run_start" then
    state.last_outcome = nil
    set_status("thinking")
  elseif k == "settled" then
    -- One blank line closes the turn. The next one opens with the prompt echo,
    -- which is its own blockquote and marker enough.
    begin_block(nil)
    set_status("idle")
    rescan(true)
    if opts().mark_current ~= false and state.out_win and vim.api.nvim_win_is_valid(state.out_win) then
      reading.mark_current(state.out_buf, state.out_win)
    end
  elseif k == "message_end" or k == "turn_end" then
    report_outcome(event)
  elseif k == "status" then
    set_status(event.text or "working")
  elseif k == "error" then
    begin_block(nil)
    s:ensure_newline()
    s:writeln(("> **%s error:** %s"):format(event.source or "agent", tostring(event.message)))
  elseif k == "exit" then
    begin_block(nil)
    s:ensure_newline()
    s:writeln(("> _agent exited (code %s)_"):format(tostring(event.code)))
    set_status("stopped")
    -- The process is gone on its own, not through `M.stop()`, so nothing else
    -- is going to stop the flush timer or drop this subscription. Safe to do
    -- here even though this callback *is* that subscription firing: the sub
    -- table is keyed and `_emit` iterates it with `pairs`, which tolerates
    -- clearing the current key mid-iteration.
    release_timer_and_sub()
  end

  -- Dialogs block the agent until answered, so they surface as native pickers
  -- rather than as a prompt buried inside a child process.
  if events.needs_reply(event) and state.session then
    local session = state.session
    if event.method == "confirm" then
      vim.ui.select({ "Yes", "No" }, { prompt = event.title or "agent asks:" }, function(choice)
        session:answer_ui(event.id, choice == "Yes", choice == nil)
      end)
    elseif event.method == "select" then
      vim.ui.select(event.options or {}, { prompt = event.title or "agent asks:" }, function(choice)
        session:answer_ui(event.id, choice, choice == nil)
      end)
    elseif event.method == "input" then
      vim.ui.input({ prompt = (event.title or "agent asks") .. ": " }, function(value)
        session:answer_ui(event.id, value, value == nil)
      end)
    else
      session:answer_ui(event.id, nil, true)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Flush timer
-- ---------------------------------------------------------------------------

local function start_timer()
  local hz = math.max(1, math.min(60, opts().flush_hz or 20))
  local interval = math.floor(1000 / hz)
  state.timer = vim.uv.new_timer()
  state.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if state.sink and state.sink:dirty() then
        state.sink:flush()
        rescan()
      end
      tick_status()
    end)
  )
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

---Stop the flush timer and drop the event subscription, without touching the
---session itself.
---
---Shared by `M.stop()`, which also tells the session to exit, and `M.start()`,
---which needs the same cleanup done first: without it, starting over an old
---session that crashed rather than being stopped through here leaves its timer
---running and its subscriber in place, both now pointed at nothing, the
---subscriber free to interleave a dead session's late events into the new
---transcript.
function release_timer_and_sub()
  stop_timer()
  if state.unsub then
    state.unsub()
    state.unsub = nil
  end
end

---Who your turns are attributed to.
---
---`os_get_passwd` is `whoami` without a subprocess. The environment is the
---fallback rather than the source: $USER is inherited and can be stale, the
---passwd entry is what the kernel thinks you are.
---@return string
local function user_name()
  local configured = opts().user_name
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  local ok, pw = pcall(vim.uv.os_get_passwd)
  local name = ok and pw and pw.username or nil
  if name == nil or name == "" then
    name = vim.env.USER or vim.env.LOGNAME
  end
  return (name ~= nil and name ~= "") and name or "you"
end

-- ---------------------------------------------------------------------------
-- Prompt history
-- ---------------------------------------------------------------------------

local HISTORY_MAX = 100

---@return string
local function prompt_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n")
end

---@param text string
local function set_prompt(text)
  local lines = vim.split(text, "\n", { plain = true })
  with_modifiable(state.in_buf, function()
    vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, lines)
  end)
  if state.in_win and vim.api.nvim_win_is_valid(state.in_win) then
    pcall(vim.api.nvim_win_set_cursor, state.in_win, { #lines, #(lines[#lines] or "") })
  end
end

---Page back and forth through prompts already sent.
---
---The draft in progress is parked at the end of the list rather than thrown
---away, so paging up and back down again returns what you were typing.
---@param delta integer
local function recall(delta)
  if #state.history == 0 then
    return
  end
  if state.history_idx == nil then
    state.history_draft = prompt_text()
    state.history_idx = #state.history + 1
  end
  local idx = math.max(1, math.min(#state.history + 1, state.history_idx + delta))
  if idx == state.history_idx then
    return
  end
  state.history_idx = idx
  set_prompt(idx > #state.history and (state.history_draft or "") or state.history[idx])
  set_placeholder()
end

---@param text string
local function remember(text)
  -- Asking the same thing twice in a row is a retry, not two entries.
  if state.history[#state.history] ~= text then
    table.insert(state.history, text)
  end
  while #state.history > HISTORY_MAX do
    table.remove(state.history, 1)
  end
  state.history_idx = nil
  state.history_draft = nil
end

-- ---------------------------------------------------------------------------
-- Submitting
-- ---------------------------------------------------------------------------

---Write one of your turns into the transcript.
---
---Your name, then what you said. A blockquote can interrupt a paragraph in
---markdown, so the name line is a paragraph of exactly one line and cannot pair
---its way into the next — which matters for anyone whose login name has an
---underscore in it.
---
---Shared with replay: a session read back off disk has no prompt buffer to
---write your turns from, and they should look the same either way.
---@param text string
local function echo_prompt(text)
  state.block = nil
  state.sink:ensure_newline()

  local name = user_name()
  state.sink:writeln(name)
  state.sink:flush()
  local name_row = math.max(0, vim.api.nvim_buf_line_count(state.out_buf) - 2)
  paint(name_row, 0, #name, "FieldguideUser")
  reading.mark_turn(state.out_buf, name_row)
  state.awaiting_reply = true

  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    state.sink:writeln("> " .. line)
  end
  state.sink:write("\n")
  state.sink:flush()
end

function M.submit()
  if not state.in_buf or not vim.api.nvim_buf_is_valid(state.in_buf) then
    return
  end
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n"))
  if text == "" then
    return
  end
  if not state.session or not state.session:is_running() then
    vim.notify("fieldguide: the agent is not running", vim.log.levels.ERROR)
    return
  end

  -- Sent before anything about the input buffer changes: `prompt` is a
  -- pcall-guarded write to the agent's stdin, and it can fail (a dead pipe, a
  -- session that exited between the running check above and here). Clearing
  -- the buffer and echoing the turn ahead of that would lose what you typed
  -- and leave `awaiting_reply` set for a reply that is never coming.
  --
  -- Prompting mid-stream is rejected outright unless a behaviour is named, so
  -- steering is the default: it lands after the current tool calls rather
  -- than waiting for the whole run.
  local _, err = state.session:prompt(text, { streaming_behavior = "steer" })
  if err then
    vim.notify("fieldguide: " .. err, vim.log.levels.ERROR)
    return
  end

  remember(text)
  with_modifiable(state.in_buf, function()
    vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "" })
  end)

  echo_prompt(text)
  set_placeholder()
  set_status("thinking")

  -- Sending is a commitment to the answer, so the view goes back to the tail
  -- even if you had scrolled up to re-read something while composing.
  if state.out_win and vim.api.nvim_win_is_valid(state.out_win) then
    pcall(vim.api.nvim_win_set_cursor, state.out_win, { vim.api.nvim_buf_line_count(state.out_buf), 0 })
  end
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local function apply_win_opts(win, wrap)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixwidth = true
  vim.wo[win].wrap = wrap
  vim.wo[win].linebreak = wrap
  -- Wrapped continuations keep the indent of the line they came from, so a tool
  -- line that runs past the panel edge stays inside its own column.
  vim.wo[win].breakindent = wrap
  -- The panel decides where the page sits, so nothing else may. `scrolloff` is
  -- enforced at redraw and overrides a topline set from Lua, which is how a
  -- reply that was already whole on the page still slid two lines under `j`.
  -- These are reading surfaces, not files being edited through a keyhole.
  vim.wo[win].scrolloff = 0
end

---Build the panel's two windows at the edge of the tabpage.
---
---The width is set once both exist. A `:split` re-equalises the row it happens
---in, so a width set before the prompt is created is a width set against a
---layout that is about to change.
local function place_panel()
  local w = cfg.options.window
  vim.cmd(w.side == "left" and "topleft vsplit" or "botright vsplit")
  state.out_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.out_win, state.out_buf)
  apply_win_opts(state.out_win, true)
  -- Always reserved, never "auto": the transcript would jump sideways the
  -- moment the bar appeared, which is the jitter the status row used to have.
  vim.wo[state.out_win].signcolumn = opts().mark_current == false and "no" or "yes:1"

  vim.cmd("belowright split")
  state.in_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.in_win, state.in_buf)
  apply_win_opts(state.in_win, true)
  vim.wo[state.in_win].winfixheight = true

  -- Whatever size the panel was last at, not whatever the config said: a
  -- sidebar you dragged wider should still be that wide after it has been put
  -- back.
  state.width = state.width or w.width
  state.prompt_height = state.prompt_height or opts().prompt_height or 5
  vim.api.nvim_win_set_height(state.in_win, state.prompt_height)
  vim.api.nvim_win_set_width(state.out_win, state.width)
end

-- Below this a window shows nothing at all, so a panel this small was squashed
-- rather than resized.
local MIN_WIDTH = 10
local MIN_PROMPT_HEIGHT = 2

---Is the panel still the two-window column it was put at the edge as?
---
---Nothing in Vim's window model marks a window as belonging to an edge, and a
---sidebar is a window like any other: `:vsplit` with the cursor in the
---transcript splits the transcript, which leaves the prompt stranded in the
---middle of the screen and the editor sharing a column with the panel. This is
---the invariant that notices.
---@return boolean
local function panel_intact()
  if not (M.is_open() and state.in_win and vim.api.nvim_win_is_valid(state.in_win)) then
    return true
  end
  local layout = vim.fn.winlayout()
  if layout[1] ~= "row" then
    return false
  end
  local kids = layout[2]
  local edge = cfg.options.window.side == "left" and kids[1] or kids[#kids]
  if edge[1] ~= "col" or #edge[2] ~= 2 then
    return false
  end
  return edge[2][1][2] == state.out_win and edge[2][2][2] == state.in_win
end

local relaying_out = false

---Put the panel back at its edge, keeping the buffers and where you were in
---them.
---
---Rebuilding is easier to be sure of than moving windows around one `wincmd` at
---a time: the two buffers are what hold the conversation, and a window is only
---ever a view onto one. The split that displaced the panel is left where it is,
---which is the editor area once the panel is out of it — so the split still
---happens, it just happens where it was meant to.
function M.relayout()
  if relaying_out or not M.is_open() then
    return
  end
  -- Nothing for the panel to be at the edge *of*. Hiding both windows here
  -- would close the last one in the tabpage.
  local host = editor_win()
  if not host then
    return
  end

  relaying_out = true
  local focused = vim.api.nvim_get_current_win()
  local ours = (focused == state.in_win and "in") or (focused == state.out_win and "out") or nil
  local view = vim.api.nvim_win_call(state.out_win, vim.fn.winsaveview)

  vim.api.nvim_win_hide(state.in_win)
  vim.api.nvim_win_hide(state.out_win)
  vim.api.nvim_set_current_win(host)
  place_panel()

  vim.api.nvim_win_call(state.out_win, function()
    vim.fn.winrestview(view)
  end)
  -- Winbars are window-local, so they went with the old windows.
  set_title()
  set_status(state.status)
  set_placeholder()

  local back = (ours == "in" and state.in_win) or (ours == "out" and state.out_win) or focused
  if vim.api.nvim_win_is_valid(back) then
    vim.api.nvim_set_current_win(back)
  end
  relaying_out = false
end

---Take back a width `<C-w>|` took away, and learn one you chose yourself.
---
---`<C-w>|` maximises a window by squeezing every other one down to
---`winminwidth`, `winfixwidth` and all. And then `winfixwidth` — the option
---that keeps the panel its own size the rest of the time — is exactly what
---stops `<C-w>=` handing the width back, because an equalise leaves
---fixed-width windows alone. The panel is left one column wide with nothing
---able to widen it, so it has to notice and do it itself.
local function restore_size()
  if relaying_out or not M.is_open() then
    return
  end

  local width = vim.api.nvim_win_get_width(state.out_win)
  if width >= MIN_WIDTH then
    -- Anything this side of legible is a size you asked for. Keep it.
    state.width = width
  elseif vim.o.columns >= MIN_WIDTH * 2 then
    relaying_out = true
    pcall(vim.api.nvim_win_set_width, state.out_win, math.min(state.width, vim.o.columns - MIN_WIDTH))
    relaying_out = false
  end

  local height = vim.api.nvim_win_get_height(state.in_win)
  if height >= MIN_PROMPT_HEIGHT then
    state.prompt_height = height
  elseif vim.o.lines >= MIN_PROMPT_HEIGHT * 2 then
    relaying_out = true
    pcall(vim.api.nvim_win_set_height, state.in_win, math.min(state.prompt_height, vim.o.lines - MIN_PROMPT_HEIGHT))
    relaying_out = false
  end
end

---Everything that has to hold about the panel's windows, in one place. Driven
---from the window autocmds, and safe to call by hand.
function M.enforce()
  if not M.is_open() then
    return
  end
  if panel_intact() then
    restore_size()
  else
    M.relayout()
  end
end

local function keymaps()
  local panel = cfg.options.panel_keys or {}
  -- Both halves, because the panel opens into the prompt: a key bound only in
  -- the transcript is a key you have to leave the prompt to reach.
  for _, buf in ipairs({ state.out_buf, state.in_buf }) do
    if panel.hide and panel.hide ~= "" then
      vim.keymap.set("n", panel.hide, M.close, { buffer = buf, desc = "fieldguide: hide the panel" })
    end
    if panel.history and panel.history ~= "" then
      vim.keymap.set("n", panel.history, M.history, { buffer = buf, desc = "fieldguide: past sessions" })
    end
    vim.keymap.set("n", "<C-c>", M.interrupt, { buffer = buf, desc = "fieldguide: interrupt the agent" })
  end

  -- The prompt behaves like an ordinary message box: Enter sends, Shift+Enter
  -- breaks the line. Sending leaves you in insert mode, ready for the next one.
  --
  -- Shift+Enter only reaches Neovim on terminals that implement the Kitty
  -- keyboard protocol — Ghostty, kitty, WezTerm, foot. Everywhere else it is
  -- indistinguishable from Enter and would send instead, so Alt+Enter is bound
  -- alongside it: that survives terminals which encode Meta as an ESC prefix.
  vim.keymap.set({ "n", "i" }, "<CR>", M.submit, { buffer = state.in_buf, desc = "fieldguide: send" })
  vim.keymap.set({ "n", "i" }, "<C-s>", M.submit, { buffer = state.in_buf, desc = "fieldguide: send" })

  for _, lhs in ipairs({ "<S-CR>", "<M-CR>" }) do
    vim.keymap.set("i", lhs, "<CR>", { buffer = state.in_buf, desc = "fieldguide: new line" })
    vim.keymap.set("n", lhs, "o", { buffer = state.in_buf, desc = "fieldguide: new line" })
  end

  -- Up and Down are the shell's, not Vim's, but only from the first and last
  -- line: a multi-line prompt still moves the cursor through itself.
  vim.keymap.set({ "n", "i" }, "<Up>", function()
    if vim.api.nvim_win_get_cursor(0)[1] > 1 then
      vim.api.nvim_feedkeys(vim.keycode("<Up>"), "n", false)
      return
    end
    recall(-1)
  end, { buffer = state.in_buf, desc = "fieldguide: previous prompt" })

  vim.keymap.set({ "n", "i" }, "<Down>", function()
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    if state.history_idx == nil or cursor < vim.api.nvim_buf_line_count(state.in_buf) then
      vim.api.nvim_feedkeys(vim.keycode("<Down>"), "n", false)
      return
    end
    recall(1)
  end, { buffer = state.in_buf, desc = "fieldguide: next prompt" })

  vim.keymap.set("n", "i", M.focus_prompt, { buffer = state.out_buf, desc = "fieldguide: write a prompt" })

  -- The transcript is read, not edited, so `j` and `k` advance through an
  -- answer rather than through a line: they scroll while there is more of the
  -- one you are on, then land on the top of the next. The arrows, `gj`/`gk` and
  -- `<C-e>`/`<C-y>` are left alone, so line-precise motion is still there when
  -- you want to yank something out.
  for lhs, delta in pairs({ j = 1, k = -1 }) do
    vim.keymap.set("n", lhs, function()
      local win = vim.api.nvim_get_current_win()
      local moved, rows = reading.step_turn(state.out_buf, win, delta)
      if not moved then
        vim.api.nvim_feedkeys(vim.keycode(delta > 0 and "<Down>" or "<Up>"), "n", false)
      end
      if opts().mark_current ~= false then
        reading.mark_current(state.out_buf, win, rows)
      end
    end, { buffer = state.out_buf, desc = "fieldguide: on through the transcript" })
  end

  -- A command the agent wrote is one keystroke from the command line, and no
  -- keystrokes at all from running: see `M.run_command`.
  vim.keymap.set("n", "<F5>", M.run_command, { buffer = state.out_buf, desc = "fieldguide: load this command" })

  -- The transcript names paths worth acting on. `gf` is where every Vim user
  -- already looks for this.
  for _, lhs in ipairs({ "gf", "<C-]>" }) do
    vim.keymap.set(
      "n",
      lhs,
      M.open_target,
      { buffer = state.out_buf, desc = "fieldguide: open the file this call was about" }
    )
  end

  -- Tool output is most of the bulk and almost none of the signal, so it is
  -- collapsed until asked for. <Tab> and <CR> both expand, because both are
  -- what people try.
  for _, lhs in ipairs({ "<Tab>", "<CR>" }) do
    vim.keymap.set("n", lhs, M.toggle_fold, { buffer = state.out_buf, desc = "fieldguide: expand tool output" })
  end
end

---@return boolean
function M.is_open()
  return state.out_win ~= nil and vim.api.nvim_win_is_valid(state.out_win)
end

function M.open()
  if M.is_open() then
    M.focus_prompt()
    return
  end

  require("fieldguide.chat.highlight").setup()

  state.out_buf = state.out_buf and vim.api.nvim_buf_is_valid(state.out_buf) and state.out_buf or make_output_buf()
  state.in_buf = state.in_buf and vim.api.nvim_buf_is_valid(state.in_buf) and state.in_buf or make_input_buf()

  place_panel()

  state.sink = state.sink or sink.new(state.out_buf)
  keymaps()
  set_title()
  set_status(state.status)
  set_placeholder()

  local group = vim.api.nvim_create_augroup("fieldguide.chat.prompt", { clear = true })

  -- ...and re-assert it whenever the prompt is entered, so a plugin that
  -- flipped it out from under us cannot leave the user unable to type.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    buffer = state.in_buf,
    group = group,
    callback = function()
      if vim.api.nvim_buf_is_valid(state.in_buf) and not vim.bo[state.in_buf].modifiable then
        vim.bo[state.in_buf].modifiable = true
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    buffer = state.in_buf,
    group = group,
    callback = set_placeholder,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    buffer = state.out_buf,
    group = group,
    callback = function()
      if opts().mark_current ~= false then
        reading.mark_current(state.out_buf, vim.api.nvim_get_current_win())
      end
    end,
  })

  -- Splitting is not forbidden, it is undone. Vim gives a window no way to
  -- claim an edge, so the panel claims one back after the fact, once the
  -- command that displaced it has finished running.
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      vim.schedule(M.enforce)
    end,
  })
end

---@param opts table? { insert?: boolean } default true
function M.focus_prompt(opts)
  if not (state.in_win and vim.api.nvim_win_is_valid(state.in_win)) then
    return
  end
  vim.api.nvim_set_current_win(state.in_win)
  -- A message box you have to press `i` in first is not a message box.
  if (opts or {}).insert ~= false then
    vim.cmd("startinsert")
  end
end

function M.close()
  for _, win in ipairs({ state.in_win, state.out_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_hide(win)
    end
  end
  state.in_win, state.out_win = nil, nil
end

function M.toggle()
  if M.is_open() then
    M.close()
    return
  end
  -- Opening the panel for the first time should give you an agent, not an
  -- empty pair of buffers. Reopening after a hide keeps the session it had.
  if state.session and state.session:is_running() then
    M.open()
    M.focus_prompt()
  else
    M.start()
  end
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

---Empty the transcript, marks and all.
local function clear_transcript()
  if not (state.out_buf and vim.api.nvim_buf_is_valid(state.out_buf)) then
    return
  end
  with_modifiable(state.out_buf, function()
    vim.api.nvim_buf_set_lines(state.out_buf, 0, -1, false, {})
  end)
  for _, ns in ipairs({ NS, NS_HL }) do
    vim.api.nvim_buf_clear_namespace(state.out_buf, ns, 0, -1)
  end
  reading.clear(state.out_buf)
  blocks = {}
  state.block = nil
  state.awaiting_reply = false
  state.tool_args = {}
end

---Render a session read back off disk.
---
---Through the same `on_event` the live stream goes through, so there is one
---renderer rather than two — a replayed tool call folds, jumps and paints
---exactly as the original did, because it *is* the original code path.
---@param path string
local function replay(path)
  for _, event in ipairs(history.events(path)) do
    if event.kind == "user" then
      echo_prompt(event.text)
    else
      -- Every assistant message that said anything closes with a `settled`
      -- event (see `history.events`), and `on_event`'s settled branch already
      -- rescans — so by the time the loop ends the transcript has already
      -- been walked at least once for every turn that has text in it. A
      -- final rescan here would just repeat the last one.
      on_event(event)
    end
  end
  state.sink:flush()
end

---Pick a past session and carry it on.
---
---Resuming is pi's own: it is handed the session id and reloads the context
---that produced this transcript, so the next thing you ask lands in the
---conversation you are looking at rather than beside it.
function M.history()
  local entries = history.list()
  if #entries == 0 then
    vim.notify("fieldguide: no past sessions in " .. history.dir(), vim.log.levels.INFO)
    return
  end
  vim.ui.select(entries, {
    prompt = "fieldguide sessions",
    format_item = history.label,
  }, function(entry)
    if entry then
      M.resume(entry)
    end
  end)
end

---@param entry table one of `history.list()`
---@param start_opts table? passed on to `M.start`, for tests
function M.resume(entry, start_opts)
  M.stop()
  M.open()
  clear_transcript()
  replay(entry.path)
  M.start(vim.tbl_extend("force", { session = entry.id }, start_opts or {}))
  M.focus_prompt()
end

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

---@param start_opts table?
function M.start(start_opts)
  if state.session and state.session:is_running() then
    M.open()
    return
  end

  -- A session that is not running here either went through `M.stop()`, which
  -- already did this, or crashed on its own and left its timer and
  -- subscription behind for the exit handler to clean up — but that handler
  -- runs async, and nothing guarantees it beat us here. Either way, starting
  -- fresh means starting fresh: no old timer double-flushing, no stale
  -- subscriber left to interleave a dead session's late events into the new
  -- transcript.
  release_timer_and_sub()

  M.open()

  local session, err = rpc.start(start_opts or {})
  if not session then
    vim.notify("fieldguide: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  state.session = session
  state.block = nil
  state.tool_args = {}
  state.unsub = session:on_event(on_event)
  start_timer()
  set_status("idle")

  M.append_session_marker()
  M.focus_prompt()
end

function M.interrupt()
  if state.session and state.session:is_running() then
    state.session:send({ type = "abort" })
    set_status("interrupting")
  end
end

function M.stop()
  release_timer_and_sub()
  if state.session then
    state.session:stop()
    state.session = nil
  end
  if state.sink then
    state.sink:flush()
  end
  set_status("stopped")
end

---Exposed for tests.
function M._state()
  return state
end

return M
