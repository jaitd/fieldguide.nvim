-- The panel, driven from the scripted agent. Asserts on what lands in the
-- buffer, which is the only thing the user actually sees.
--
--   nvim -l tests/chat.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local cfg = require("fieldguide.config")
local chat = require("fieldguide.chat")

cfg.setup({ chat = { flush_hz = 60, show_thinking = false } })

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

local FAKE = root .. "/tests/fixtures/fake-agent.sh"
local FAILING = root .. "/tests/fixtures/failing-agent.sh"
local DELTAS = 300

-- Headless nvim has no UI, so vim.ui.select falls back to a blocking
-- inputlist(). Stub both, which is also what dressing.nvim and friends do in a
-- real setup — the panel must go through vim.ui.*, not around it.
local dialogs = {}
vim.ui.select = function(items, select_opts, on_choice)
  table.insert(dialogs, { kind = "select", prompt = (select_opts or {}).prompt, items = items })
  on_choice(items[1], 1)
end
vim.ui.input = function(input_opts, on_confirm)
  table.insert(dialogs, { kind = "input", prompt = (input_opts or {}).prompt })
  on_confirm("stub")
end

io.write("panel\n")

chat.start({ argv = { FAKE, tostring(DELTAS) }, cwd = root })
local state = chat._state()

check("two buffers, not one", state.out_buf ~= state.in_buf and state.out_buf ~= nil and state.in_buf ~= nil)
check("output is not directly editable", vim.bo[state.out_buf].modifiable == false)
check(
  "output is markdown, so renderers pick it up",
  vim.bo[state.out_buf].filetype == "markdown",
  vim.bo[state.out_buf].filetype
)
check(
  "output records no undo history",
  vim.bo[state.out_buf].undolevels == -1,
  tostring(vim.bo[state.out_buf].undolevels)
)
check("the prompt buffer is editable", vim.bo[state.in_buf].modifiable == true)
check(
  "no terminal anywhere in the panel",
  vim.bo[state.out_buf].buftype ~= "terminal" and vim.bo[state.in_buf].buftype ~= "terminal"
)

-- Wait on an observable end state, not on `status`: the panel is already "idle"
-- the moment it starts, so polling that would pass before a single event
-- arrived.
local finished = vim.wait(20000, function()
  if state.sink then
    state.sink:flush()
  end
  local so_far = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false), "\n")
  return so_far:find("agent exited", 1, true) ~= nil
end, 25)
check("the run reaches its end", finished, "status=" .. tostring(state.status))

if state.sink then
  state.sink:flush()
end

local lines = vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false)
local text = table.concat(lines, "\n")

io.write("what landed in the buffer\n")
do
  -- 300 tokens streamed as `tok1 tok2 ...`. If the sink were appending per
  -- delta this would be 300 lines instead of a paragraph.
  check(
    "the streamed tokens are present",
    text:find("tok1 ", 1, true) ~= nil and text:find(("tok%d "):format(DELTAS), 1, true) ~= nil
  )

  local token_lines = 0
  for _, line in ipairs(lines) do
    if line:find("tok1 ", 1, true) then
      token_lines = token_lines + 1
    end
  end
  check("prose is not one line per token", token_lines == 1, ("%d lines contained the first token"):format(token_lines))

  check("the 20KB delta is not truncated", text:find(string.rep("x", 5000), 1, true) ~= nil)
  check(
    "U+2028 content survives to the buffer",
    text:find("mid", 1, true) ~= nil and text:find("after", 1, true) ~= nil
  )

  check("tool calls are rendered", text:find("    ▪ state — ", 1, true) ~= nil, "no tool line")
  check("the malformed line is surfaced, not hidden", text:lower():find("error", 1, true) ~= nil)
  check("thinking is hidden by default", text:find("thinking", 1, true) == nil)
end

io.write("tool blocks\n")
do
  -- The verb renderers drop the nvim_ prefix: "state — …" reads better than
  -- "nvim_state — …" in a transcript that is entirely about this editor.
  check("a completed tool is one summary line", text:find("    ▪ state — ", 1, true) ~= nil, text)
  check("...and its JSON is never shown", text:find('"version"', 1, true) == nil, text)
  -- tool_start writes nothing, so the tool appears exactly once.
  check(
    "a running tool adds nothing to the transcript",
    select(2, text:gsub("    ▪ state — ", "")) == 1,
    "the tool appears more than once"
  )
  -- A markdown list marker would collide with the agent's own bullet lists,
  -- which is the whole thing the glyph exists to avoid.
  check("a tool line is not a markdown list item", text:find("\n%- state") == nil, text)

  -- Tool calls are a block of their own, so prose on either side is held off
  -- them rather than running straight into the summary line.
  local tool_row
  for i, line in ipairs(lines) do
    if line:find("    ▪ state — ", 1, true) then
      tool_row = i
    end
  end
  check(
    "prose above a tool is held off it",
    tool_row and lines[tool_row - 1] == "",
    vim.inspect(lines[(tool_row or 2) - 1])
  )
  check("...and prose below it too", tool_row and lines[tool_row + 1] == "", vim.inspect(lines[(tool_row or 0) + 1]))
  check("the agent goes on talking after the tool", text:find("afterthetool", 1, true) ~= nil, text)
  -- Models lead with a space or a newline when they resume after a tool call,
  -- which lands as an indented sentence or a line holding nothing but a space.
  check("...without the whitespace it led with", text:find("\nafterthetool", 1, true) ~= nil, text)
  local blank_but_not = 0
  for _, line in ipairs(lines) do
    if line ~= "" and line:match("^%s*$") then
      blank_but_not = blank_but_not + 1
    end
  end
  check("no line holds nothing but whitespace", blank_but_not == 0, tostring(blank_but_not))

  local before = vim.api.nvim_buf_line_count(state.out_buf)
  chat.append_tool({
    kind = "tool_end",
    tool = "some_unknown_tool",
    text = "alpha\nbeta\ngamma",
    is_error = false,
  })
  state.sink:flush()
  -- A blank line and the summary: the blank is load-bearing, because an
  -- indented code block cannot interrupt a paragraph and a tool line written
  -- straight under prose would be parsed as more of that paragraph.
  check(
    "a tool lands under a blank line, whatever the caller did",
    vim.api.nvim_buf_line_count(state.out_buf) == before + 2,
    ("%d -> %d"):format(before, vim.api.nvim_buf_line_count(state.out_buf))
  )

  -- writeln leaves a trailing empty line, so the summary is the line *before*
  -- the last one.
  local total = vim.api.nvim_buf_line_count(state.out_buf)
  local summary_row = total - 1
  local win = vim.fn.win_findbuf(state.out_buf)[1]
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { summary_row, 0 })
  check(
    "the cursor is on the summary line",
    vim.api.nvim_get_current_line():find("some_unknown_tool", 1, true) ~= nil,
    vim.api.nvim_get_current_line()
  )

  local hl_ns = vim.api.nvim_get_namespaces()["fieldguide.chat.hl"]
  ---@param row integer 0-indexed
  local function groups_on(row)
    local out = {}
    for _, mark in
      ipairs(vim.api.nvim_buf_get_extmarks(state.out_buf, hl_ns, { row, 0 }, { row, -1 }, { details = true }))
    do
      table.insert(out, mark[4].hl_group)
    end
    return out
  end

  local summary_groups = groups_on(summary_row - 1)
  check(
    "the glyph and the summary are highlighted apart",
    vim.tbl_contains(summary_groups, "FieldguideToolIcon") and vim.tbl_contains(summary_groups, "FieldguideTool"),
    vim.inspect(summary_groups)
  )

  chat.toggle_fold()
  local expanded = vim.api.nvim_buf_line_count(state.out_buf)
  check("expanding reveals the body", expanded == total + 3, ("%d -> %d"):format(total, expanded))
  local revealed = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, summary_row, -1, false), "\n")
  check("...which is the tool's output", revealed:find("beta", 1, true) ~= nil, revealed)
  check(
    "...dimmed like the summary it came from",
    vim.tbl_contains(groups_on(summary_row), "FieldguideToolDetail"),
    vim.inspect(groups_on(summary_row))
  )

  chat.toggle_fold()
  check(
    "collapsing puts it back",
    vim.api.nvim_buf_line_count(state.out_buf) == total,
    tostring(vim.api.nvim_buf_line_count(state.out_buf))
  )
  check("...and takes its highlights with it", #groups_on(summary_row) == 0, vim.inspect(groups_on(summary_row)))
  check(
    "toggling on a non-tool line is harmless",
    (function()
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      return pcall(chat.toggle_fold)
    end)()
  )
end

io.write("tool lines are not markdown\n")
do
  -- The failure this guards against is cross-line: consecutive tool calls are
  -- one markdown paragraph, so the `~` in one path pairs with the `~` in the
  -- next and the parser strikes through everything between them. Two filenames
  -- with an underscore do the same in italics. Assert on the parse tree rather
  -- than on the rendering, because the rendering is a plugin we do not ship.
  chat.append_tool({ kind = "tool_end", tool = "read", args = { path = "~/notes/a_file.md" } })
  chat.append_tool({ kind = "tool_end", tool = "read", args = { path = "~/notes/b_file.md" } })
  chat.append_tool({ kind = "tool_end", tool = "grep", args = { pattern = "*.lua" }, text = "hit" })
  state.sink:flush()

  local tool_rows, guilty = {}, {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false)) do
    if line:find("^    [▪✓✗] ") then
      tool_rows[i - 1] = line
    end
    if line:find("^    ▪ read ~/notes/") then
      table.insert(guilty, line)
    end
  end
  check("the offending pair of lines is present", #guilty == 2, vim.inspect(guilty))

  local parser = vim.treesitter.get_parser(state.out_buf, "markdown")
  parser:parse(true)
  local spans = {}
  parser:for_each_tree(function(tree)
    local function walk(node)
      local kind = node:type()
      if kind:find("strike") or kind == "emphasis" or kind == "strong_emphasis" then
        local sr, _, er, _ = node:range()
        for row = sr, er do
          if tool_rows[row] then
            table.insert(spans, ("%s over %q"):format(kind, tool_rows[row]))
          end
        end
      end
      for child in node:iter_children() do
        walk(child)
      end
    end
    walk(tree:root())
  end)
  -- The agent's own prose keeps its markdown; only the machinery opts out.
  check("no emphasis span reaches a tool line", #spans == 0, table.concat(spans, ", "))
end

io.write("the session marker\n")
do
  local first = vim.api.nvim_buf_get_lines(state.out_buf, 0, 1, false)[1] or ""
  check("the transcript opens with a session marker", first:find("^session started ") ~= nil, first)
  -- `_like this_` is emphasis to a parser that gets to see it and two stray
  -- underscores to one that does not.
  check("...without leaning on markdown to render it", first:find("_", 1, true) == nil, first)
  -- The winbar directly above it already carries the name.
  check("...and without repeating the name the winbar shows", first:find("fieldguide", 1, true) == nil, first)

  local hl_ns = vim.api.nvim_get_namespaces()["fieldguide.chat.hl"]
  local groups = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.out_buf, hl_ns, { 0, 0 }, { 0, -1 }, { details = true })) do
    table.insert(groups, mark[4].hl_group)
  end
  check(
    "...and it is painted, not left to a parser",
    vim.tbl_contains(groups, "FieldguideSession"),
    vim.inspect(groups)
  )

  check(
    "the transcript window carries the name in its winbar",
    (vim.wo[state.out_win or 0].winbar or ""):find("fieldguide", 1, true) ~= nil,
    tostring(state.out_win and vim.wo[state.out_win].winbar)
  )
end

io.write("the empty prompt says what it is for\n")
do
  local ns = vim.api.nvim_get_namespaces()["fieldguide.chat.prompt"]
  local function hints()
    return vim.api.nvim_buf_get_extmarks(state.in_buf, ns, 0, -1, { details = true })
  end
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = state.in_buf })
  local shown = hints()
  check("an empty prompt shows a hint", #shown == 1, tostring(#shown))
  check(
    "...naming both of the bindings that are not obvious",
    #shown == 1 and shown[1][4].virt_text[1][1]:find("Shift+Enter", 1, true) ~= nil,
    #shown == 1 and shown[1][4].virt_text[1][1] or ""
  )

  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "typing" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = state.in_buf })
  check("...and drops it the moment anything is typed", #hints() == 0, tostring(#hints()))
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = state.in_buf })
end

io.write("tool arguments\n")
do
  -- The end event does not always repeat the arguments, so they are carried
  -- from the start event. Without this a `read` renders as its own file path
  -- being unknown.
  chat._state().tool_args["tc-args"] = { path = "lua/config/options.lua" }
  local before = vim.api.nvim_buf_line_count(state.out_buf)
  chat.append_tool({ kind = "tool_end", tool = "read", tool_call_id = "tc-args", text = "x" })
  state.sink:flush()
  local line = vim.api.nvim_buf_get_lines(state.out_buf, before - 1, before, false)[1] or ""
  check("arguments survive from start to end", line:find("options.lua", 1, true) ~= nil, line)
end

io.write("jumping to what a tool touched\n")
do
  local file = root .. "/README.md"
  chat.append_tool({ kind = "tool_end", tool = "read", args = { path = file }, text = "x" })
  state.sink:flush()

  local row = vim.api.nvim_buf_line_count(state.out_buf) - 1
  local win = vim.fn.win_findbuf(state.out_buf)[1]
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, 0 })

  chat.open_target()
  local landed = vim.api.nvim_buf_get_name(0)
  check("gf on a tool line opens the file it names", landed == file, landed)
  -- Opening into the sidebar would replace the transcript you were reading.
  check(
    "...in a window that is not the panel",
    vim.api.nvim_get_current_buf() ~= state.out_buf and vim.api.nvim_get_current_buf() ~= state.in_buf
  )

  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  check("a line with nothing to open does nothing", pcall(chat.open_target))
end

io.write("blocking dialogs\n")
do
  -- The agent stalls on a confirm() until answered, so it must surface as a
  -- native picker rather than as a prompt nobody can see.
  local confirms = vim.tbl_filter(function(d)
    return d.kind == "select" and (d.prompt or ""):find("Reload config modules", 1, true) ~= nil
  end, dialogs)
  check("a blocking dialog reaches vim.ui.select", #confirms == 1, vim.inspect(dialogs))
  -- The events after the dialog only arrive if the agent was actually unblocked.
  check(
    "...and the run continued past it",
    text:find("compaction", 1, true) ~= nil or state.status == "stopped",
    state.status
  )
end

io.write("submitting\n")
do
  -- A live session: the previous one has exited by design, and submitting into
  -- a dead agent is a different test (below).
  chat.stop()
  chat.start({ argv = { FAKE, "50", "3" }, cwd = root })
  state = chat._state()
  vim.wait(300)

  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "what is <leader>gs?" })
  chat.submit()
  vim.wait(200)
  state.sink:flush()
  local after = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false), "\n")
  check("the prompt is echoed into the transcript", after:find("> what is <leader>gs?", 1, true) ~= nil)
  check(
    "...and the prompt buffer is cleared",
    table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "") == ""
  )

  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "   ", "" })
  state.sink:flush()
  local before = vim.api.nvim_buf_line_count(state.out_buf)
  chat.submit()
  state.sink:flush()
  check("an empty prompt sends nothing", vim.api.nvim_buf_line_count(state.out_buf) == before)

  -- Steering mid-stream: without a streamingBehavior the agent rejects a
  -- prompt outright, so this would fail if the panel sent a bare prompt.
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "actually, stop" })
  chat.submit()
  vim.wait(200)
  check("a mid-stream prompt is accepted, not rejected", state.session:is_running() == true)

  -- A real config is full of plugins that set `modifiable = false` on buffers
  -- they did not create; buftype=nofile attracts it. This is only reproducible
  -- by doing it deliberately, because the test runner loads no plugins — which
  -- is exactly why it went unnoticed until the panel was run for real.
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "typed while another plugin locked the buffer" })
  vim.bo[state.in_buf].modifiable = false
  local ok = pcall(chat.submit)
  check("submitting survives a buffer another plugin locked", ok, "submit threw")
  state.sink:flush()
  local after = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false), "\n")
  check(
    "...and the prompt still reaches the transcript",
    after:find("another plugin locked", 1, true) ~= nil,
    "prompt lost"
  )
  check("...and the lock is left as it was found", vim.bo[state.in_buf].modifiable == false)
end

io.write("a prompt that fails to send\n")
do
  -- `prompt()` is a pcall-guarded write to the agent's stdin, and it can fail
  -- even while `is_running()` is still true. Stubbed rather than reproduced
  -- for real, because the real failure is a race (the pipe closing between the
  -- running check and the write) that a fixture cannot land on reliably.
  local real_prompt = state.session.prompt
  state.session.prompt = function(_, ...)
    return nil, "the pipe slammed shut"
  end

  vim.bo[state.in_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "does this survive?" })
  state.awaiting_reply = false
  local before = vim.api.nvim_buf_line_count(state.out_buf)
  chat.submit()
  state.sink:flush()

  check(
    "the draft is left in the input buffer",
    table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n") == "does this survive?"
  )
  check("nothing was echoed into the transcript", vim.api.nvim_buf_line_count(state.out_buf) == before)
  check("awaiting_reply was never set for a turn that never sent", state.awaiting_reply == false)

  state.session.prompt = real_prompt
end

io.write("the prompt behaves like a message box\n")
do
  local function mapping(mode, lhs)
    local want = vim.keycode(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.in_buf, mode)) do
      if m.lhs == want or vim.keycode(m.lhs) == want then
        return m
      end
    end
  end

  check("Enter sends from insert", (mapping("i", "<CR>") or {}).desc == "fieldguide: send")
  check("Enter sends from normal", (mapping("n", "<CR>") or {}).desc == "fieldguide: send")
  -- Shift+Enter only arrives on terminals speaking the Kitty keyboard protocol;
  -- Alt+Enter is the fallback for the rest.
  check("Shift+Enter breaks the line", (mapping("i", "<S-CR>") or {}).desc == "fieldguide: new line")
  check("Alt+Enter breaks the line too", (mapping("i", "<M-CR>") or {}).desc == "fieldguide: new line")
  check("...and they are distinct keycodes", vim.keycode("<CR>") ~= vim.keycode("<S-CR>"))

  -- A prompt built with Shift+Enter must reach the agent as one message.
  -- (The preceding test deliberately leaves the buffer locked.)
  vim.bo[state.in_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "first line", "second line" })
  chat.submit()
  vim.wait(150)
  state.sink:flush()
  local after = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false), "\n")
  check(
    "a multi-line prompt is sent whole",
    after:find("> first line", 1, true) and after:find("> second line", 1, true) ~= nil,
    after:sub(-200)
  )
end

io.write("your turns are yours\n")
do
  local st = chat._state()
  local buf_lines = vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false)
  local name_row
  for i, line in ipairs(buf_lines) do
    if line:find("^> first line") then
      name_row = i - 1
    end
  end
  check(
    "the prompt echo is preceded by a name",
    name_row ~= nil and buf_lines[name_row] ~= "",
    vim.inspect(name_row and buf_lines[name_row])
  )

  local expected = (vim.uv.os_get_passwd() or {}).username or vim.env.USER
  check(
    "...which is who you are logged in as",
    buf_lines[name_row] == expected,
    ("%q vs %q"):format(tostring(buf_lines[name_row]), tostring(expected))
  )

  local hl_ns = vim.api.nvim_get_namespaces()["fieldguide.chat.hl"]
  local groups = {}
  for _, m in
    ipairs(
      vim.api.nvim_buf_get_extmarks(state.out_buf, hl_ns, { name_row - 1, 0 }, { name_row - 1, -1 }, { details = true })
    )
  do
    table.insert(groups, m[4].hl_group)
  end
  check("...and it is painted, not markdown", vim.tbl_contains(groups, "FieldguideUser"), vim.inspect(groups))

  -- A blockquote can interrupt a paragraph, so the name is a paragraph of
  -- exactly one line. Anything else and an underscore in a login name pairs
  -- with the next one down the transcript.
  local parser = vim.treesitter.get_parser(state.out_buf, "markdown")
  parser:parse(true)
  local reach = {}
  parser:for_each_tree(function(tree)
    local function walk(node)
      local kind = node:type()
      if kind == "emphasis" or kind == "strong_emphasis" or kind:find("strike") then
        local sr, _, er, _ = node:range()
        if sr ~= er then
          table.insert(reach, ("%s %d..%d"):format(kind, sr, er))
        end
      end
      for child in node:iter_children() do
        walk(child)
      end
    end
    walk(tree:root())
  end)
  check("no emphasis spans more than its own line", #reach == 0, table.concat(reach, ", "))

  -- Config wins over the passwd entry.
  cfg.options.chat.user_name = "someone-else"
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "named prompt" })
  chat.submit()
  vim.wait(150)
  st.sink:flush()
  local after = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false), "\n")
  check("a configured name is used instead", after:find("someone%-else\n> named prompt") ~= nil, after:sub(-120))
  cfg.options.chat.user_name = nil
end

io.write("prompt history\n")
do
  local function callback(lhs)
    local want = vim.keycode(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.in_buf, "n")) do
      if m.lhs == want or vim.keycode(m.lhs) == want then
        return m.callback
      end
    end
  end

  local st = chat._state()
  check("sent prompts are remembered", #st.history > 0, tostring(#st.history))
  local last = st.history[#st.history]

  vim.api.nvim_set_current_win(state.in_win)
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, { "half-written" })
  vim.api.nvim_win_set_cursor(state.in_win, { 1, 0 })

  local up, down = callback("<Up>"), callback("<Down>")
  check("Up is bound in the prompt", type(up) == "function")

  up()
  check(
    "...and recalls the last prompt sent",
    table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n") == last,
    table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n")
  )

  -- The draft is parked, not thrown away.
  vim.api.nvim_win_set_cursor(state.in_win, { vim.api.nvim_buf_line_count(state.in_buf), 0 })
  down()
  check(
    "Down gives the draft back",
    table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n") == "half-written",
    table.concat(vim.api.nvim_buf_get_lines(state.in_buf, 0, -1, false), "\n")
  )

  -- Asking the same thing twice in a row is a retry, not two entries.
  local before = #st.history
  vim.api.nvim_buf_set_lines(state.in_buf, 0, -1, false, vim.split(last, "\n", { plain = true }))
  chat.submit()
  vim.wait(100)
  check("a repeated prompt is not a second entry", #st.history == before, ("%d -> %d"):format(before, #st.history))
end

io.write("status\n")
do
  -- The winbar carries what the agent is doing, and nothing when it is doing
  -- nothing: a permanent "idle" is a label, not information.
  check("a busy agent is announced", vim.wo[state.in_win].winbar ~= "", vim.inspect(vim.wo[state.in_win].winbar))
  check(
    "...naming what it is doing",
    vim.wo[state.in_win].winbar:find("thinking", 1, true) ~= nil,
    vim.wo[state.in_win].winbar
  )
  -- "thinking" and "thinking, still, ninety seconds in" are different
  -- situations, and the word alone cannot tell them apart.
  check(
    "...and how long it has been doing it",
    vim.wo[state.in_win].winbar:find("%d+s$") ~= nil,
    vim.wo[state.in_win].winbar
  )

  chat.stop()
  check(
    "a quiet agent says nothing",
    vim.trim(vim.wo[state.in_win].winbar) == "",
    vim.inspect(vim.wo[state.in_win].winbar)
  )
  -- ...but still takes the row. An empty winbar is not drawn at all, and a
  -- status appearing and vanishing would move the prompt out from under
  -- whatever you were typing.
  check("...on a row that is still there", vim.wo[state.in_win].winbar ~= "", vim.inspect(vim.wo[state.in_win].winbar))
end

io.write("picking a session back up\n")
do
  local history = require("fieldguide.chat.history")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local was = cfg.options.chat.session_dir
  cfg.options.chat.session_dir = dir

  vim.fn.writefile({
    vim.json.encode({ type = "session", id = "old", timestamp = "2026-08-01T10:00:00.000Z", cwd = "/x" }),
    vim.json.encode({
      type = "message",
      message = { role = "user", content = { { type = "text", text = "what is my leader key?" } } },
    }),
    vim.json.encode({
      type = "message",
      message = {
        role = "assistant",
        content = { { type = "toolCall", id = "c1", name = "nvim_state", arguments = { what = "nvim" } } },
      },
    }),
    vim.json.encode({
      type = "message",
      message = {
        role = "toolResult",
        toolCallId = "c1",
        toolName = "nvim_state",
        content = { { type = "text", text = '{"ok":true,"result":{"nvim":{"version":"0.12.4"}}}' } },
        details = {},
        isError = false,
      },
    }),
    vim.json.encode({
      type = "message",
      message = { role = "assistant", content = { { type = "text", text = "Your leader is `<Space>`." } } },
    }),
  }, dir .. "/2026-08-01T10-00-00-000Z_old.jsonl")

  local entries = history.list()
  check("the session is there to pick", #entries == 1 and entries[1].id == "old", vim.inspect(entries))

  -- The panel opens into the prompt, so a key bound only in the transcript is a
  -- key you have to leave the prompt to reach.
  local lhs = cfg.options.panel_keys.history
  for _, buf in ipairs({ chat._state().out_buf, chat._state().in_buf }) do
    local bound = false
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      bound = bound or m.lhs == vim.fn.keytrans(vim.keycode(lhs))
    end
    check(
      ("%s reaches it from %s"):format(lhs, buf == chat._state().in_buf and "the prompt" or "the transcript"),
      bound
    )
  end

  chat.resume(entries[1], { argv = { FAKE, "5" }, cwd = root })
  vim.wait(2000, function()
    return chat._state().status == "idle"
  end, 20)
  local text = table.concat(vim.api.nvim_buf_get_lines(chat._state().out_buf, 0, -1, false), "\n")

  -- Replayed through the same renderer as the live stream, so all three shapes
  -- have to come back looking like themselves.
  check("your turn comes back attributed to you", text:find("> what is my leader key?", 1, true) ~= nil, text)
  check("...the tool call as a tool line", text:find("▪ state", 1, true) ~= nil, text)
  check("...and the answer as prose", text:find("Your leader is", 1, true) ~= nil, text)
  -- The transcript is replaced, not appended to: what came before belonged to a
  -- different conversation.
  check("the transcript before it is gone", text:find("afterthetool", 1, true) == nil, text)
  -- Where you picked it back up.
  check("and the new session is marked", text:find("session started", 1, true) ~= nil, text)

  chat.stop()
  cfg.options.chat.session_dir = was
  state = chat._state()
end

io.write("moving through what was said\n")
do
  local reading = require("fieldguide.chat.reading")
  local st = chat._state()

  -- Turn marks come from the render path, not from the test: what is asserted
  -- is that a real exchange produces something to move between at all.
  local before = reading.turn_count(st.out_buf)
  chat.append_session_marker()
  check("the session marker is somewhere to land", reading.turn_count(st.out_buf) > before)

  -- `j` on a transcript with turns in it moves the view rather than the line.
  local win = st.out_win
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
  local moved = reading.step_turn(st.out_buf, win, 1)
  check("...and j goes to it", moved or vim.api.nvim_buf_line_count(st.out_buf) < 3, tostring(moved))
end

io.write("the sidebar stays at the edge\n")
do
  chat.close()
  vim.cmd("silent! only")
  vim.cmd("enew")
  chat.open()
  local st = chat._state()

  ---The panel is meant to be a two-window column at the right of the tabpage
  ---and nothing else. Asserting on the layout tree rather than on coordinates:
  ---headless nvim has no UI, so widths are not the real ones.
  local function edge_is_panel()
    local layout = vim.fn.winlayout()
    if layout[1] ~= "row" then
      return false
    end
    local kids = layout[2]
    local last = kids[#kids]
    return last[1] == "col" and #last[2] == 2 and last[2][1][2] == st.out_win and last[2][2][2] == st.in_win
  end

  check("the panel opens as a column at the edge", edge_is_panel(), vim.inspect(vim.fn.winlayout()))

  -- Vim has no edge windows: a split with the cursor in the transcript splits
  -- the transcript, and leaves the prompt somewhere in the middle of the
  -- screen. The panel has to notice and put itself back.
  vim.api.nvim_set_current_win(st.out_win)
  vim.cmd("vsplit")
  check("a split from inside it does displace it", not edge_is_panel(), vim.inspect(vim.fn.winlayout()))

  local settled = vim.wait(1000, edge_is_panel, 10)
  check("...and it goes back to the edge on its own", settled, vim.inspect(vim.fn.winlayout()))
  check(
    "...keeping the split that displaced it",
    #vim.api.nvim_tabpage_list_wins(0) == 4,
    tostring(#vim.api.nvim_tabpage_list_wins(0))
  )
  check("...and the transcript it was showing", vim.api.nvim_win_get_buf(st.out_win) == st.out_buf)
  check(
    "...and its winbar, which is window-local and did not survive the move",
    (vim.wo[st.out_win].winbar or ""):find("fieldguide", 1, true) ~= nil,
    vim.wo[st.out_win].winbar
  )

  -- A window opened across the top would leave the panel not reaching it.
  vim.cmd("wincmd t")
  vim.cmd("topleft split")
  check("a full-width split above also displaces it", not edge_is_panel(), vim.inspect(vim.fn.winlayout()))
  check("...and it recovers from that too", vim.wait(1000, edge_is_panel, 10), vim.inspect(vim.fn.winlayout()))

  -- `<C-w>|` squeezes every other window down to `winminwidth`, and then
  -- `winfixwidth` is what stops `<C-w>=` giving the width back: an equalise
  -- skips fixed-width windows. Without a rule of its own the panel is stranded
  -- one column wide.
  -- WinResized is driven from the redraw, and headless nvim never redraws, so
  -- these call the check the autocmd calls rather than waiting on the event.
  -- What is asserted is the rule; the wiring is only exercised by hand.
  vim.cmd("wincmd t")
  vim.cmd("wincmd |")
  check(
    "<C-w>| squashes it to nothing",
    vim.api.nvim_win_get_width(st.out_win) == 1,
    tostring(vim.api.nvim_win_get_width(st.out_win))
  )
  chat.enforce()
  check(
    "...and it takes the width back",
    vim.api.nvim_win_get_width(st.out_win) > 1,
    tostring(vim.api.nvim_win_get_width(st.out_win))
  )

  -- A width you chose is not a width to undo.
  local chosen = math.floor(vim.o.columns / 4)
  vim.api.nvim_win_set_width(st.out_win, chosen)
  chat.enforce()
  vim.cmd("wincmd t")
  vim.cmd("wincmd |")
  chat.enforce()
  check(
    "...the one you chose, not the one configured",
    vim.api.nvim_win_get_width(st.out_win) == chosen,
    ("%d, wanted %d"):format(vim.api.nvim_win_get_width(st.out_win), chosen)
  )

  -- With nothing else on screen there is no edge to be at, and hiding the
  -- panel to rebuild it would close the last window in the tabpage.
  vim.cmd("silent! only")
  chat.close()
  vim.cmd("enew")
  chat.open()
end

io.write("a reply that ended badly\n")
do
  -- The failure mode this exists for: the provider refuses, pi reports it as an
  -- ordinary message that happens to have stopped for a bad reason, and the
  -- panel used to go quiet and back to idle — which reads as the question
  -- having been swallowed rather than answered.
  chat.stop()
  chat.start({ argv = { FAILING }, cwd = root })
  local st = chat._state()
  local function transcript()
    st.sink:flush()
    return table.concat(vim.api.nvim_buf_get_lines(st.out_buf, 0, -1, false), "\n")
  end
  vim.wait(3000, function()
    return transcript():find("agent error:", 1, true) ~= nil
  end, 50)
  local text = transcript()

  check(
    "the reason the model gave is in the transcript",
    text:find("not available on this account", 1, true) ~= nil,
    text
  )
  local _, seen = text:gsub("agent error:", "")
  check("...exactly once, though two events carry it", seen == 1, tostring(seen))
  check("...and the panel is not left thinking", st.status ~= "thinking", st.status)

  chat.stop()
  chat.start({ argv = { FAILING, "length" }, cwd = root })
  st = chat._state()
  vim.wait(3000, function()
    st.sink:flush()
    return table.concat(vim.api.nvim_buf_get_lines(st.out_buf, 0, -1, false), "\n"):find("cut off", 1, true) ~= nil
  end, 50)
  local cut = table.concat(vim.api.nvim_buf_get_lines(st.out_buf, 0, -1, false), "\n")
  check("a truncated reply says it was truncated", cut:find("cut off at the model", 1, true) ~= nil, cut)
end

io.write("a crash does not leak the timer or the subscription\n")
do
  -- The agent exiting on its own, rather than through `chat.stop()`, used to
  -- leave the flush timer running and the old `on_event` subscription live —
  -- both now pointed at a dead session — until `start()` piled a second timer
  -- and a second subscriber on top instead of replacing them.
  chat.stop()
  chat.start({ argv = { FAKE, "1" }, cwd = root })
  local st = chat._state()
  vim.wait(3000, function()
    st.sink:flush()
    return table.concat(vim.api.nvim_buf_get_lines(st.out_buf, 0, -1, false), "\n"):find("agent exited", 1, true) ~= nil
  end, 20)

  check("the exit handler stops the flush timer itself", st.timer == nil)
  check("...and drops its own subscription", st.unsub == nil)

  -- Simulate the leak directly: stand-ins for a timer and a subscription that
  -- `start()` should release rather than orphan, planted after the session is
  -- confirmed dead.
  local leftover_timer = vim.uv.new_timer()
  leftover_timer:start(100000, 0, function() end)
  st.timer = leftover_timer
  local unsub_called = false
  st.unsub = function()
    unsub_called = true
  end

  chat.start({ argv = { FAKE, "1" }, cwd = root })

  check("start() closes a timer left behind by the old session", leftover_timer:is_closing() == true)
  check("...and calls the old unsub", unsub_called == true)
  check("...before wiring up a single new timer", st.timer ~= nil and st.timer ~= leftover_timer)
end

io.write("lifecycle\n")
do
  check("the panel reports open", chat.is_open() == true)
  chat.close()
  check("closing hides the windows", chat.is_open() == false)
  check("...but keeps the transcript buffer", vim.api.nvim_buf_is_valid(state.out_buf) == true)

  local before = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false), "\n")
  chat.open()
  local after = table.concat(vim.api.nvim_buf_get_lines(state.out_buf, 0, -1, false), "\n")
  check("reopening does not lose history", after == before)

  chat.stop()
  check("stopping halts the flush timer", state.timer == nil)
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
