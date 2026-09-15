-- Past sessions: finding them, describing them, reading them back.
--
-- The fixture is a real pi session log, trimmed. What matters is that the log
-- format is *not* the wire format — it stores whole messages where the stream
-- delivers deltas — and that the difference stops at this module.
--
--   nvim -l tests/history.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local cfg = require("fieldguide.config")

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

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
cfg.setup({ chat = { session_dir = dir } })
local history = require("fieldguide.chat.history")

---@param name string
---@param records table[]
local function write_session(name, records)
  local lines = {}
  for _, record in ipairs(records) do
    table.insert(lines, vim.json.encode(record))
  end
  vim.fn.writefile(lines, dir .. "/" .. name)
end

local function msg(role, content, extra)
  return vim.tbl_extend(
    "force",
    { type = "message", message = vim.tbl_extend("force", { role = role, content = content }, extra or {}) },
    {}
  )
end

write_session("2026-08-01T10-00-00-000Z_aaa.jsonl", {
  { type = "session", id = "aaa", timestamp = "2026-08-01T10:00:00.000Z", cwd = "/x" },
  msg("user", { { type = "text", text = "how do i grep the project?\nsecond line" } }),
  msg("assistant", {
    { type = "thinking", thinking = "hmm" },
    { type = "toolCall", id = "c1", name = "read", arguments = { path = "init.lua" } },
  }),
  {
    type = "message",
    message = {
      role = "toolResult",
      toolCallId = "c1",
      toolName = "read",
      content = { { type = "text", text = "…" } },
      details = {},
      isError = false,
    },
  },
  msg("assistant", { { type = "text", text = "Use `:Telescope live_grep`." } }),
})

write_session("2026-08-02T10-00-00-000Z_bbb.jsonl", {
  { type = "session", id = "bbb", timestamp = "2026-08-02T10:00:00.000Z", cwd = "/x" },
  msg("user", { { type = "text", text = "what is my leader key?" } }),
})

-- A session that was opened and never used. It still has to list rather than
-- break the picker for everything after it.
write_session("2026-08-03T10-00-00-000Z_ccc.jsonl", {
  { type = "session", id = "ccc", timestamp = "2026-08-03T10:00:00.000Z", cwd = "/x" },
})

io.write("finding them\n")
do
  local list = history.list()
  check("every session is listed", #list == 3, tostring(#list))
  -- Newest first: the one you want is almost always the last one you had.
  check(
    "newest first",
    list[1].id == "ccc" and list[3].id == "aaa",
    vim.inspect(vim.tbl_map(function(e)
      return e.id
    end, list))
  )
  check("the title is what you asked", list[3].title == "how do i grep the project?", tostring(list[3].title))
  check("...one line of it", list[3].title:find("second line", 1, true) == nil, list[3].title)
  check(
    "a session with nothing in it still lists",
    list[1].title ~= nil and list[1].title ~= "",
    tostring(list[1].title)
  )
  check(
    "the label names the question",
    history.label(list[3]):find("how do i grep", 1, true) ~= nil,
    history.label(list[3])
  )
end

io.write("in your own clock\n")
do
  -- The log stores UTC and the transcript's own session marker is local.
  -- Showing the stored string unchanged puts two clocks in front of the same
  -- person, two hours apart for anyone who is not on UTC. Asserted as a round
  -- trip, so this passes wherever it is run.
  local at = os.time() - 3600
  write_session(
    "2026-08-05T10-00-00-000Z_eee.jsonl",
    { { type = "session", id = "eee", timestamp = os.date("!%Y-%m-%dT%H:%M:%S.000Z", at) } }
  )
  local found
  for _, e in ipairs(history.list()) do
    if e.id == "eee" then
      found = e
    end
  end
  check(
    "a session is dated in local time",
    history.label(found):find(os.date("%Y-%m-%d %H:%M", at), 1, true) ~= nil,
    history.label(found)
  )

  local odd = { started = "not a timestamp", title = "x" }
  check(
    "a timestamp we cannot read is shown as it is",
    history.label(odd):find("not a timestamp", 1, true) ~= nil,
    history.label(odd)
  )
end

io.write("nothing there yet\n")
do
  local empty = vim.fn.tempname()
  cfg.setup({ chat = { session_dir = empty } })
  check("a directory that does not exist is empty, not an error", #history.list() == 0)
  cfg.setup({ chat = { session_dir = dir } })
end

io.write("reading one back\n")
do
  local events = history.events(dir .. "/2026-08-01T10-00-00-000Z_aaa.jsonl")
  local kinds = vim.tbl_map(function(e)
    return e.kind
  end, events)
  check("your turn comes back as your turn", kinds[1] == "user", vim.inspect(kinds))
  check(
    "...with what you said",
    events[1].text == "how do i grep the project?\nsecond line",
    vim.inspect(events[1].text)
  )

  local tool = nil
  for _, e in ipairs(events) do
    if e.kind == "tool_end" then
      tool = e
    end
  end
  check("a tool call comes back whole", tool ~= nil, vim.inspect(kinds))
  -- Arguments are on the assistant's call and the result is a record of its
  -- own, exactly as on the wire. Without carrying them across by id the
  -- renderer has a tool with no path to show.
  check(
    "...including the arguments, which are on the other record",
    (tool or {}).args and tool.args.path == "init.lua",
    vim.inspect((tool or {}).args)
  )
  check("...and whether it failed", (tool or {}).is_error == false, tostring((tool or {}).is_error))

  check(
    "the answer comes back as text",
    kinds[#kinds - 1] == "text_delta" or kinds[#kinds] == "text_delta",
    vim.inspect(kinds)
  )

  -- A message that is nothing but tool calls is the middle of a turn: closing
  -- the block there would put a gap between a call and its own result.
  local settled_before_tool = false
  for _, e in ipairs(events) do
    if e.kind == "settled" then
      settled_before_tool = tool == nil
      break
    end
  end
  check("a message of only tool calls does not close the turn", not settled_before_tool, vim.inspect(kinds))
end

io.write("a file that is not one\n")
do
  vim.fn.writefile({ "not json", "{ still not" }, dir .. "/2026-08-04T10-00-00-000Z_ddd.jsonl")
  check("garbage does not throw", pcall(history.list))
  check("...and does not list", #vim.tbl_filter(function(e)
    return e.id == "ddd"
  end, history.list()) == 0)
  check("reading it back is empty, not an error", #history.events(dir .. "/2026-08-04T10-00-00-000Z_ddd.jsonl") == 0)
  check("a file that is not there at all is empty too", #history.events(dir .. "/nope.jsonl") == 0)
end

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
