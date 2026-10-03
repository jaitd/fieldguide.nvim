-- Claude Code: the stream-json normaliser, and the harness profile that
-- launches it.
--
--   nvim -l tests/claude.lua
--
-- No Claude, no network. `fixtures/claude-stream.jsonl` is a real session,
-- recorded through this normaliser from a headless Neovim and scrubbed of paths:
-- nvim_state, a read, a read the gate refused, a doc-zone read, an edit with the
-- PostToolUse verify behind it, a write the gate refused; then a long answer
-- interrupted mid-stream, and a third turn in the same process.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

-- Before anything reads stdpath(): the harness writes its settings under
-- state, and a test has no business writing into the real one.
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
vim.env.XDG_STATE_HOME = scratch .. "/state"
assert(vim.startswith(vim.fn.stdpath("state"), scratch), "stdpath('state') did not follow XDG_STATE_HOME")

local cfg = require("fieldguide.config")
cfg.setup({ cwd = "/lab/cfg" })
local claude = require("fieldguide.rpc.claude")
local framing = require("fieldguide.rpc.framing")
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

---@param lines table[] decoded wire lines
---@return fieldguide.Event[], fieldguide.ClaudeNormaliser
local function run(lines)
  local n = claude.new()
  local out = {}
  for _, raw in ipairs(lines) do
    vim.list_extend(out, n:normalize(raw))
  end
  return out, n
end

local function of_kind(list, kind)
  return vim.tbl_filter(function(e)
    return e.kind == kind
  end, list)
end

-- ---------------------------------------------------------------------------
io.write("recorded session\n")

local recorded = {}
for line in io.lines(root .. "/tests/fixtures/claude-stream.jsonl") do
  table.insert(recorded, (assert(framing.decode(line))))
end
local evs, n = run(recorded)

check("nothing comes through as unknown", #of_kind(evs, "unknown") == 0, vim.inspect(of_kind(evs, "unknown")[1]))
check("one run_start per turn, carrying the session id", #of_kind(evs, "run_start") == 3)
check("the session id is kept for --resume", n.session_id == recorded[1].session_id, tostring(n.session_id))
check("one settle per turn", #of_kind(evs, "settled") == 3)

local ends = of_kind(evs, "tool_end")
local names = vim.tbl_map(function(e)
  return e.tool
end, ends)
check(
  "tool names are the pi extension's, not Claude's",
  vim.deep_equal(names, { "nvim_state", "read", "read", "read", "edit", "write" }),
  table.concat(names, ",")
)
check(
  "arguments are renamed so renderers find the path",
  ((ends[2].args or {}).path or ""):match("/init%.lua$") ~= nil and ends[2].args.file_path == nil,
  vim.inspect(ends[2].args)
)
check("an ordinary result is not an error", ends[1].is_error == false and ends[2].is_error == false)

local refused = ends[3]
check("a gate refusal is an error", refused.is_error == true)
check("…marked as blocked, not as a tool that failed on its own", refused.blocked == true)
check(
  "…with Claude's hook-error prefix stripped",
  vim.startswith(refused.text or "", "blocked by fieldguide: outside fieldguide's zones"),
  refused.text
)
check(
  "the doc zone is readable",
  ends[4].is_error == false and (ends[4].text or ""):find("DOC-OK-2208", 1, true) ~= nil
)

local edit = ends[5]
check(
  "the edit carries its verify",
  type(edit.verify) == "string" and edit.verify:find("boot OK", 1, true) ~= nil,
  tostring(edit.verify)
)
check("…appended to the edit's own result, as pi does", (edit.text or ""):find(edit.verify or "\0", 1, true) ~= nil)
check("…and to no other call", #vim.tbl_filter(function(e)
  return e.verify ~= nil
end, ends) == 1)
check(
  "the edit's diff is built from Claude's patch",
  edit.details and edit.details.diff and edit.details.diff:find("+1 ", 1, true) ~= nil,
  vim.inspect(edit.details)
)
check("…with the first changed line for gf", edit.details and edit.details.firstChangedLine == 1)
check("a refused write is blocked too", ends[6].blocked == true and ends[6].tool == "write")

local rendered = tools.render(edit, 40)
check("the edit renders as pi's edit does", rendered.summary:find("+1 −1", 1, true) ~= nil, rendered.summary)
check("a refusal renders as failed", tools.render(refused, 40).status == "fail")

local starts = of_kind(evs, "tool_start")
check("every call is announced before its result", #starts == #ends)

local resp = of_kind(evs, "response")
check("the interrupt is acknowledged by id", #resp == 1 and resp[1].id == "fg-int" and resp[1].success == true)
local turn_ends = of_kind(evs, "turn_end")
check(
  "the interrupted turn ends as aborted",
  #turn_ends == 1 and turn_ends[1].stop_reason == "aborted",
  vim.inspect(turn_ends)
)
check("…and not as an error", turn_ends[1] and turn_ends[1].error == nil)

-- The third turn's text, which is everything after the second settle.
local seen, pong = 0, {}
for _, e in ipairs(evs) do
  if e.kind == "settled" then
    seen = seen + 1
  elseif seen == 2 and e.kind == "text_delta" then
    table.insert(pong, e.text)
  end
end
check("the same process answers the next turn", vim.trim(table.concat(pong)) == "PONG", table.concat(pong))

-- Streamed deltas must add up to what Claude later says the message was.
local streamed, whole = {}, {}
local current = nil
local one = claude.new()
for _, raw in ipairs(recorded) do
  if raw.type == "stream_event" and raw.event.type == "message_start" then
    current = raw.event.message.id
    streamed[current] = {}
  elseif raw.type == "assistant" then
    for _, b in ipairs(raw.message.content) do
      if b.type == "text" then
        whole[raw.message.id] = (whole[raw.message.id] or "") .. b.text
      end
    end
  end
  for _, e in ipairs(one:normalize(raw)) do
    if e.kind == "text_delta" and current then
      table.insert(streamed[current], e.text)
    end
  end
end
local mismatched = 0
for id, text in pairs(whole) do
  if table.concat(streamed[id] or {}) ~= text then
    mismatched = mismatched + 1
  end
end
check("streamed text matches each finished message", mismatched == 0, mismatched .. " message(s) differ")
check(
  "assistant lines add no text of their own when it was streamed",
  (function()
    local n2 = claude.new()
    local dup = 0
    for _, raw in ipairs(recorded) do
      for _, e in ipairs(n2:normalize(raw)) do
        if e.kind == "text_delta" and raw.type == "assistant" then
          dup = dup + 1
        end
      end
    end
    return dup == 0
  end)()
)

-- ---------------------------------------------------------------------------
io.write("awkward cases\n")

local function tool_use(id, name, input)
  return {
    type = "assistant",
    message = { id = "m-" .. id, content = { { type = "tool_use", id = id, name = name, input = input } } },
  }
end
local function tool_result(id, text, is_error, extra)
  return vim.tbl_extend("force", {
    type = "user",
    message = {
      role = "user",
      content = { { type = "tool_result", tool_use_id = id, content = text, is_error = is_error } },
    },
  }, extra or {})
end
local function post_hook(id, verify)
  return {
    type = "system",
    subtype = "hook_response",
    hook_event = "PostToolUse",
    hook_name = "PostToolUse:Edit",
    outcome = "success",
    stdout = vim.json.encode({
      fieldguide = { tool_use_id = id, verify = verify },
      hookSpecificOutput = { hookEventName = "PostToolUse", additionalContext = verify },
    }),
  }
end

do
  -- Two edits whose hooks both finish before either result is written: the
  -- verify goes to the call its hook named, not to whichever result is next.
  local out = run({
    tool_use("a", "Edit", { file_path = "a.lua", old_string = "1", new_string = "2" }),
    tool_use("b", "Edit", { file_path = "b.lua", old_string = "1", new_string = "2" }),
    post_hook("a", "VERIFY-A"),
    post_hook("b", "VERIFY-B"),
    tool_result("b", "ok b"),
    tool_result("a", "ok a"),
  })
  local e = of_kind(out, "tool_end")
  check(
    "verify follows the tool_use_id its hook named",
    e[1].verify == "VERIFY-B" and e[2].verify == "VERIFY-A",
    vim.inspect(e)
  )
end

do
  local out = run({
    {
      type = "system",
      subtype = "hook_response",
      hook_event = "PreToolUse",
      hook_name = "PreToolUse:Read",
      outcome = "error",
      exit_code = 127,
      stderr = "node: not found",
    },
  })
  check(
    "a hook that crashed is an error, not silence",
    #out == 1 and out[1].kind == "error" and out[1].message:find("node: not found", 1, true) ~= nil,
    vim.inspect(out)
  )
end

do
  local out = run({
    { type = "result", subtype = "success", is_error = true, result = "API Error: 529 overloaded", session_id = "s" },
  })
  local te = of_kind(out, "turn_end")[1]
  check(
    "a failed result is reported as an error with its reason",
    te and te.stop_reason == "error" and te.error == "API Error: 529 overloaded",
    vim.inspect(te)
  )
  check("…and still settles", #of_kind(out, "settled") == 1)
end

do
  local out =
    run({ { type = "result", subtype = "error_max_turns", is_error = true, result = "", errors = { "max turns" } } })
  check("an empty error result falls back to its errors", of_kind(out, "turn_end")[1].error == "max turns")
end

do
  local out = run({ { type = "result", subtype = "success", is_error = false, stop_reason = "max_tokens" } })
  check("an answer cut off at the limit says so", of_kind(out, "turn_end")[1].stop_reason == "length")
end

do
  -- Cut off at the limit, reported by the message and again by the result.
  local out = run({
    { type = "stream_event", event = { type = "message_start", message = { id = "m1" } } },
    { type = "stream_event", event = { type = "message_delta", delta = { stop_reason = "max_tokens" } } },
    { type = "stream_event", event = { type = "message_stop" } },
    { type = "result", subtype = "success", is_error = false, stop_reason = "max_tokens", uuid = "r1" },
  })
  local me, te = of_kind(out, "message_end")[1], of_kind(out, "turn_end")[1]
  check(
    "a stop both report carries one timestamp, so it is said once",
    me and te and me.message.timestamp == "m1" and te.message.timestamp == "m1",
    vim.inspect({ me and me.message, te and te.message })
  )
end

do
  local out = run({
    { type = "stream_event", event = { type = "message_start", message = { id = "m1" } } },
    { type = "stream_event", event = { type = "message_delta", delta = { stop_reason = "refusal" } } },
    { type = "stream_event", event = { type = "message_stop" } },
  })
  local me = of_kind(out, "message_end")[1]
  check("a refusal is an error the panel will show", me.stop_reason == "error" and me.error ~= nil)
end

do
  local out =
    run({ { type = "assistant", message = { id = "whole", content = { { type = "text", text = "all at once" } } } } })
  check(
    "an unstreamed message still shows its text",
    #out == 1 and out[1].kind == "text_delta" and out[1].text == "all at once"
  )
end

do
  local out = run({ { type = "rate_limit_event", rate_limit_info = { status = "rejected" } } })
  check("a rate limit is a status", out[1] and out[1].kind == "status")
  check(
    "…but an allowed one is nothing",
    #run({ { type = "rate_limit_event", rate_limit_info = { status = "allowed" } } }) == 0
  )
end

do
  local out = run({
    tool_use("m", "mcp__fieldguide__nvim_docs", { query = "x" }),
    tool_result("m", { { type = "text", text = "{}" } }),
  })
  local e = of_kind(out, "tool_end")[1]
  check("our MCP verbs lose their prefix", e.tool == "nvim_docs" and e.args.query == "x")
  check("block-list results flatten to text", e.text == "{}")
end

do
  local out = run({
    tool_use("r", "Read", { file_path = "x" }),
    tool_result("r", "PreToolUse:Read hook error: something else", true),
  })
  local e = of_kind(out, "tool_end")[1]
  check("another hook's refusal is not claimed as the gate's", e.blocked == false and e.text == "something else")
end

check("an unknown line is kept, not dropped", run({ { type = "brand_new" } })[1].kind == "unknown")

-- ---------------------------------------------------------------------------
io.write("diff\n")

do
  local diff, first = claude.diff({
    { oldStart = 9, oldLines = 2, newStart = 9, newLines = 2, lines = { " keep", "-old", "+new" } },
    { oldStart = 20, oldLines = 1, newStart = 20, newLines = 2, lines = { " ctx", "+added" } },
  })
  local expected = table.concat({
    "  9 keep",
    "-10 old",
    "+10 new",
    "    ...",
    " 20 ctx",
    "+21 added",
  }, "\n")
  check("hunks render as pi's diff does, padded to one width", diff == expected, "\n" .. tostring(diff))
  check("first changed line is on the new side", first == 10, tostring(first))
  check("no patch, no diff", claude.diff(nil) == nil and claude.diff({}) == nil)
end

-- ---------------------------------------------------------------------------
io.write("outbound\n")

check(
  "a prompt is a user message",
  vim.deep_equal(claude.encode_prompt("hi"), { type = "user", message = { role = "user", content = "hi" } })
)
local int = claude.encode_interrupt("x-1")
check(
  "an interrupt is a control request",
  int.type == "control_request" and int.request_id == "x-1" and int.request.subtype == "interrupt"
)

-- ---------------------------------------------------------------------------
io.write("harness profile\n")

local h = require("fieldguide.harness.claude")
local o = {
  root = root,
  config_dir = "/lab/cfg",
  doc_roots = { "/lab/lazy", "/opt/nvim/runtime" },
  session_dir = scratch .. "/sessions",
  model = "haiku",
  system_prompt = root .. "/prompt/system.md",
  mcp = { command = "/usr/bin/node", args = { root .. "/extension/mcp.ts" }, env = { FIELDGUIDE_ADDR = "/sock" } },
}

local saved = {}
for _, k in ipairs({ "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CONFIG_DIR" }) do
  saved[k] = vim.env[k]
  vim.env[k] = nil
end

local argv = h.argv(o)
local joined = table.concat(argv, " ")
local function flag(name)
  for i, a in ipairs(argv) do
    if a == name then
      return argv[i + 1] or true
    end
  end
  return nil
end

check("stream-json in and out", flag("--input-format") == "stream-json" and flag("--output-format") == "stream-json")
check("the built-ins are cut to the file tools", flag("--tools") == "Read,Edit,Write,Grep,Glob")
check("only our MCP server", flag("--strict-mcp-config") ~= nil)
check("none of the user's settings", flag("--setting-sources") == "")
check("no skills", flag("--disable-slash-commands") ~= nil)
check("never --bare, which would drop the hooks", not joined:find("--bare", 1, true))
check("the system prompt is appended from our file", flag("--append-system-prompt-file") == o.system_prompt)
check("hook events are in the stream", flag("--include-hook-events") ~= nil)
check("no --resume for a new session", flag("--resume") == nil)
check("--resume for a carried-on one", vim.tbl_contains(h.argv(vim.tbl_extend("force", o, { session = "abc" })), "abc"))

local settings = vim.json.decode(table.concat(vim.fn.readfile(flag("--settings")), "\n"))
check("the settings file is ours, under state", vim.startswith(flag("--settings"), scratch))
local pre = settings.hooks.PreToolUse[1]
check(
  "the gate runs before every tool",
  pre.matcher == "*" and pre.hooks[1].command:find("claude-hook.ts' pre", 1, true) ~= nil,
  pre.hooks[1].command
)
check("…on an absolute node", vim.startswith(pre.hooks[1].command, "'/"), pre.hooks[1].command)
do
  -- The gate's command as Claude runs it, with a node that cannot start: a
  -- non-blocking error would let the tool run ungated; exit 2 refuses it.
  local broken = h.settings(vim.tbl_extend("force", o, { node = scratch .. "/gone/node" }))
  local r = vim.system({ "sh", "-c", broken.hooks.PreToolUse[1].hooks[1].command }, { stdin = "{}" }):wait(10000)
  check("a gate that cannot start blocks the tool (exit 2)", r.code == 2, vim.inspect(r))
end
check("verify runs after writes", settings.hooks.PostToolUse[1].hooks[1].command:find("' post", 1, true) ~= nil)
check(
  "the doc zone is readable without a prompt nobody would see",
  vim.tbl_contains(settings.permissions.allow, "Read(//lab/lazy/**)")
    and vim.tbl_contains(settings.permissions.allow, "Grep(//opt/nvim/runtime/**)")
)
check("…but not writable", not vim.iter(settings.permissions.allow):any(function(r)
  return r:match("^Edit") or r:match("^Write")
end))

local mcp = vim.json.decode(table.concat(vim.fn.readfile(flag("--mcp-config")), "\n"))
check("the MCP server gets the editor's environment", mcp.mcpServers.fieldguide.env.FIELDGUIDE_ADDR == "/sock")

do
  -- Sandboxed: the server runs outside on a socket, and Claude gets the relay.
  local so = vim.tbl_extend("force", o, { mcp_socket = "/run/fg/mcp.sock" })
  local relay = h.mcp_config(so).mcpServers.fieldguide
  check(
    "with a socket, Claude's MCP server is the relay to it",
    relay.args[2] == "--relay" and relay.args[3] == "/run/fg/mcp.sock" and relay.args[1]:find("mcp.ts$") ~= nil,
    vim.inspect(relay)
  )
  check("…which is handed none of the editor's variables", vim.tbl_isempty(relay.env), vim.inspect(relay.env))
  local senv = h.env(so)
  check("the write hooks are pointed at the socket", senv.FIELDGUIDE_MCP_SOCKET == "/run/fg/mcp.sock")
  check("and nothing in Claude's tree gets the editor's address", senv.FIELDGUIDE_ADDR == "")
  check("without a socket, neither is set", h.env(o).FIELDGUIDE_MCP_SOCKET == nil and h.env(o).FIELDGUIDE_ADDR == nil)
end

-- Claude reads a hook that times out as a non-blocking error, so its limits
-- are the outermost of the chain: past mcp.ts's 75s and 135s waits on the
-- server, and past claude-hook.ts's 80s and 140s waits on mcp.ts.
check("Claude waits out the pre-write chain", pre.hooks[1].timeout >= 90, tostring(pre.hooks[1].timeout))
check(
  "…and the post-write one",
  settings.hooks.PostToolUse[1].hooks[1].timeout >= 150,
  tostring(settings.hooks.PostToolUse[1].hooks[1].timeout)
)

do
  -- A stand-in `claude` on PATH, so each refusal below is about node and not
  -- about a machine without Claude installed.
  local bin = scratch .. "/bin"
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({ "#!/bin/sh" }, bin .. "/claude")
  vim.uv.fs_chmod(bin .. "/claude", tonumber("755", 8))
  local path = vim.env.PATH
  vim.env.PATH = bin .. ":" .. path
  local function refused(node, pattern)
    local err = h.preflight(vim.tbl_extend("force", o, { node = node }))
    return err ~= nil and (pattern == nil or err:find(pattern, 1, true) ~= nil), err
  end

  check("preflight refuses to launch without node for the hooks", refused("", "not on PATH"))
  -- Any non-empty string used to pass, and Claude treats a hook that cannot
  -- start as a non-blocking error: the tool then runs with no gate at all.
  check("…or with a node that does not exist", refused(scratch .. "/no-such-node", "cannot run"))
  vim.fn.writefile({ "#!/bin/sh", "exit 0" }, bin .. "/not-node")
  vim.uv.fs_chmod(bin .. "/not-node", tonumber("755", 8))
  check("…or with one that starts but cannot run the hook", refused(bin .. "/not-node", "cannot run"))
  local node = vim.fn.exepath("node")
  if node ~= "" then
    local err = h.preflight(vim.tbl_extend("force", o, { node = node }))
    check("a node that runs the hook is accepted", err == nil, err)
  end
  vim.env.PATH = path
end

vim.env.CLAUDECODE = "1"
local env = h.env(o)
check("a parent Claude session's variables are emptied", env.CLAUDECODE == "" and env.CLAUDE_CODE_SESSION_ID == "")
check(
  "the user's own Claude configuration is not",
  env.CLAUDE_CODE_OAUTH_TOKEN == nil and env.CLAUDE_CODE_USE_BEDROCK == nil
)
check("with a login, Claude keeps its own home", env.CLAUDE_CONFIG_DIR == nil and h.auth() == "login")
check(
  "…and the sandbox binds that home, never the credentials file alone",
  (function()
    for _, p in ipairs(h.needs().rw) do
      if p:match("%.credentials%.json$") then
        return false
      end
    end
    return true
  end)()
)

vim.env.CLAUDE_CODE_OAUTH_TOKEN = "sk-ant-oat01-test"
env = h.env(o)
check(
  "with a token, a home of our own, so sessions stay out of the user's",
  env.CLAUDE_CONFIG_DIR ~= nil and vim.startswith(env.CLAUDE_CONFIG_DIR, scratch),
  tostring(env.CLAUDE_CONFIG_DIR)
)
check("…and it is what the sandbox binds", vim.tbl_contains(h.needs().rw, env.CLAUDE_CONFIG_DIR))

do
  -- A node other than PATH's: the gate hook and the MCP relay both run on it,
  -- so it is the install the sandbox has to bind, or neither can start.
  local custom = scratch .. "/custom-node"
  vim.fn.mkdir(custom .. "/bin", "p")
  vim.fn.writefile({ "#!/bin/sh" }, custom .. "/bin/node")
  vim.uv.fs_chmod(custom .. "/bin/node", tonumber("755", 8))
  local ro = h.needs(vim.tbl_extend("force", o, { node = custom .. "/bin/node" })).ro
  check(
    "a node set in the options is the install the sandbox binds",
    vim.tbl_contains(ro, vim.uv.fs_realpath(custom)),
    vim.inspect(ro)
  )
end
-- Not /tmp/claude-<uid>, which every other Claude session of the user's uses.
check(
  "Claude's temp dir is our own, and bound writable",
  vim.startswith(env.CLAUDE_CODE_TMPDIR or "", h.dir()) and vim.tbl_contains(h.needs().rw, env.CLAUDE_CODE_TMPDIR),
  tostring(env.CLAUDE_CODE_TMPDIR)
)
check(
  "the launch is by the binary's real path, not a PATH link",
  h.argv(o)[1] == vim.uv.fs_realpath(vim.fn.exepath("claude")) or vim.fn.executable("claude") == 0
)

for k, v in pairs(saved) do
  vim.env[k] = v
end
vim.env.CLAUDECODE = nil
vim.fn.delete(scratch, "rf")

io.write(("\n%d passed, %d failed\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
