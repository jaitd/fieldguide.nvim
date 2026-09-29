-- Claude Code's stream-json, normalised into fieldguide's own event type.
--
-- The sibling of `events.lua`, for `claude -p --input-format stream-json
-- --output-format stream-json --verbose --include-partial-messages
-- --include-hook-events`. The renderer never learns which of the two it is
-- reading: tool names and arguments are translated into the ones the pi
-- extension uses (`Read{file_path}` becomes `read{path}`,
-- `mcp__fieldguide__nvim_state` becomes `nvim_state`), so every renderer in
-- chat/tools.lua works unchanged.
--
-- Unlike pi's wire, one Claude line can mean several of ours (a `result` is the
-- turn's outcome, the run's end and the settle at once) and some mean none (the
-- thinking-token counter). So this is a stateful normaliser returning a list,
-- where `events.normalize` returns one event:
--
--   local n = require("fieldguide.rpc.claude").new()
--   for _, event in ipairs(n:normalize(decoded)) do ... end
--
-- It is stateful for a second reason. A Claude tool_result names only the call
-- it answers, not the tool or its arguments, and the PostToolUse hook that ran
-- `verify` names neither; both are joined back to the call here, by id.

local events = require("fieldguide.rpc.events")

local M = {}

-- The prefix Claude puts on a tool_result when a PreToolUse hook denied the
-- call, and the one our hook puts on its own reason. Both are stripped for
-- display: "blocked by fieldguide: outside fieldguide's zones: …" is the part a
-- person needs to read.
local HOOK_DENIED = "^PreToolUse:[%w_]+ hook error: "
local OURS = "blocked by fieldguide: "

local MCP_PREFIX = "mcp__fieldguide__"

-- Anthropic's stop reasons, spelled the way pi spells them, because that is
-- what the panel's outcome reporting was written against.
local STOP = {
  end_turn = "stop",
  stop_sequence = "stop",
  tool_use = "toolUse",
  max_tokens = "length",
  model_context_window_exceeded = "length",
  pause_turn = "stop",
  refusal = "error",
}

-- Claude's tools, as the pi extension's tools. Arguments are renamed rather than
-- copied wholesale so a renderer reading `args.path` finds the path.
local TOOLS = {
  Read = function(i)
    return "read", { path = i.file_path, offset = i.offset, limit = i.limit }
  end,
  Write = function(i)
    return "write", { path = i.file_path, content = i.content }
  end,
  Edit = function(i)
    return "edit", { path = i.file_path, edits = { { oldText = i.old_string, newText = i.new_string } } }
  end,
  MultiEdit = function(i)
    local edits = {}
    for _, e in ipairs(i.edits or {}) do
      table.insert(edits, { oldText = e.old_string, newText = e.new_string })
    end
    return "edit", { path = i.file_path, edits = edits }
  end,
  Grep = function(i)
    return "grep", { pattern = i.pattern, path = i.path, glob = i.glob }
  end,
  Glob = function(i)
    return "find", { pattern = i.pattern, path = i.path }
  end,
}

---@param name string?
---@param input table?
---@return string tool, table args
function M.tool(name, input)
  name = name or "tool"
  input = type(input) == "table" and input or {}
  if TOOLS[name] then
    return TOOLS[name](input)
  end
  if vim.startswith(name, MCP_PREFIX) then
    return name:sub(#MCP_PREFIX + 1), input
  end
  return name, input
end

---A Claude structuredPatch, rendered the way pi renders an edit's diff:
---`+N line`, `-N line`, ` N line`, with numbers padded to one width and `...`
---between hunks. The edit renderer counts and shows exactly this.
---@param hunks table[]?
---@return string?, integer? diff, first changed line
function M.diff(hunks)
  if type(hunks) ~= "table" or #hunks == 0 then
    return nil, nil
  end
  local widest = 1
  for _, h in ipairs(hunks) do
    widest = math.max(widest, #tostring((h.oldStart or 1) + (h.oldLines or 0)))
    widest = math.max(widest, #tostring((h.newStart or 1) + (h.newLines or 0)))
  end
  local function num(n)
    return (" "):rep(widest - #tostring(n)) .. tostring(n)
  end

  local out, first = {}, nil
  for k, h in ipairs(hunks) do
    if k > 1 then
      table.insert(out, " " .. (" "):rep(widest) .. " ...")
    end
    local old, new = h.oldStart or 1, h.newStart or 1
    for _, line in ipairs(h.lines or {}) do
      local sign, text = line:sub(1, 1), line:sub(2)
      if sign == "+" then
        first = first or new
        table.insert(out, "+" .. num(new) .. " " .. text)
        new = new + 1
      elseif sign == "-" then
        first = first or new
        table.insert(out, "-" .. num(old) .. " " .. text)
        old = old + 1
      elseif sign == " " then
        table.insert(out, " " .. num(old) .. " " .. text)
        old, new = old + 1, new + 1
      end
      -- "\ No newline at end of file" and anything else: not a line of the file.
    end
  end
  return table.concat(out, "\n"), first
end

---A tool_result's content is a string, or a list of blocks.
---@param content any
---@return string?
local function content_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    return events.result_text({ content = content })
  end
  return nil
end

---@param raw table
---@return table?
local function decode_hook_stdout(raw)
  local stdout = raw.stdout or raw.output
  if type(stdout) ~= "string" or stdout == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
  return ok and type(value) == "table" and value or nil
end

-- ---------------------------------------------------------------------------
-- Outbound
-- ---------------------------------------------------------------------------

---One user turn. Sent while a turn is still running, Claude queues it and
---answers it next rather than refusing it.
---@param text string
---@return table
function M.encode_prompt(text)
  return { type = "user", message = { role = "user", content = text } }
end

---Stop the current turn. Answered by a `control_response` with the same
---request id, and the turn ends with a `result` whose terminal_reason says it
---was aborted — not an error, and not reported as one.
---@param request_id string
---@return table
function M.encode_interrupt(request_id)
  return { type = "control_request", request_id = request_id, request = { subtype = "interrupt" } }
end

-- ---------------------------------------------------------------------------
-- Inbound
-- ---------------------------------------------------------------------------

---@class fieldguide.ClaudeNormaliser
---@field session_id string? the id to hand `--resume`, once the stream has said it
---@field model string?
---@field private _blocks table<integer, table> the streamed message's content blocks, by index
---@field private _message table? the message being streamed
---@field private _streamed table<string, boolean> message ids whose text arrived as deltas
---@field private _calls table<string, table> tool_use_id -> { tool, args }
---@field private _verify table<string, string> tool_use_id -> verify paragraph
local Normaliser = {}
Normaliser.__index = Normaliser

---@return fieldguide.ClaudeNormaliser
function M.new()
  return setmetatable({
    _blocks = {},
    _message = nil,
    _streamed = {},
    _calls = {},
    _verify = {},
  }, Normaliser)
end

---@param raw table
---@return fieldguide.Event[]
function Normaliser:_stream_event(raw)
  local ev = raw.event or {}
  local t = ev.type

  if t == "message_start" then
    local msg = ev.message or {}
    self._message = { id = msg.id, model = msg.model }
    self._blocks = {}
    if msg.id then
      self._streamed[msg.id] = true
    end
    return { { kind = "message_start", message = msg, raw = raw } }
  elseif t == "content_block_start" then
    local block = ev.content_block or {}
    self._blocks[ev.index or 0] = { type = block.type, id = block.id, name = block.name }
    if block.type == "text" then
      return { { kind = "text_start", index = ev.index, raw = raw } }
    elseif block.type == "thinking" or block.type == "redacted_thinking" then
      return { { kind = "thinking_start", index = ev.index, raw = raw } }
    elseif block.type == "tool_use" then
      return { { kind = "tool_call_start", index = ev.index, tool_call_id = block.id, raw = raw } }
    end
    return {}
  elseif t == "content_block_delta" then
    local d = ev.delta or {}
    if d.type == "text_delta" then
      return { { kind = "text_delta", index = ev.index, text = d.text or "", raw = raw } }
    elseif d.type == "thinking_delta" then
      return { { kind = "thinking_delta", index = ev.index, text = d.thinking or "", raw = raw } }
    elseif d.type == "input_json_delta" then
      return { { kind = "tool_call_delta", index = ev.index, text = d.partial_json or "", raw = raw } }
    end
    -- signature_delta and the like: bookkeeping for the API, nothing to show.
    return {}
  elseif t == "content_block_stop" then
    local block = self._blocks[ev.index or 0] or {}
    if block.type == "text" then
      return { { kind = "text_end", index = ev.index, raw = raw } }
    elseif block.type == "thinking" or block.type == "redacted_thinking" then
      return { { kind = "thinking_end", index = ev.index, raw = raw } }
    end
    -- A tool_use block's end is reported from the `assistant` line, which
    -- carries the parsed input rather than the fragments.
    return {}
  elseif t == "message_delta" then
    if self._message and ev.delta then
      self._message.stop_reason = ev.delta.stop_reason
    end
    return {}
  elseif t == "message_stop" then
    local msg = self._message or {}
    local anthropic = msg.stop_reason
    local event = {
      kind = "message_end",
      stop_reason = STOP[anthropic] or anthropic,
      -- report_outcome dedupes on the timestamp; the message id is the
      -- stable thing that names one message here.
      message = { id = msg.id, timestamp = msg.id, stopReason = STOP[anthropic] or anthropic },
      raw = raw,
    }
    if anthropic == "refusal" then
      event.error = "the model declined to answer"
    end
    self._message = nil
    return { event }
  end
  return { { kind = "unknown", note = "stream_event." .. tostring(t), raw = raw } }
end

---@param raw table
---@return fieldguide.Event[]
function Normaliser:_assistant(raw)
  local msg = raw.message or {}
  local out = {}
  local streamed = msg.id and self._streamed[msg.id]
  for _, block in ipairs(msg.content or {}) do
    if block.type == "tool_use" then
      local tool, args = M.tool(block.name, block.input)
      self._calls[block.id or ""] = { tool = tool, args = args }
      table.insert(out, { kind = "tool_call_end", tool_call_id = block.id, tool = tool, args = args, raw = raw })
      -- Claude reports no separate "execution started". The complete call is
      -- the closest thing, and it is what the status line wants.
      table.insert(out, { kind = "tool_start", tool_call_id = block.id, tool = tool, args = args, raw = raw })
    elseif not streamed and block.type == "text" and block.text then
      -- A message that arrived whole: without --include-partial-messages, or a
      -- synthetic one Claude writes itself. Shown as one delta rather than lost.
      table.insert(out, { kind = "text_delta", text = block.text, raw = raw })
    elseif not streamed and block.type == "thinking" and block.thinking then
      table.insert(out, { kind = "thinking_delta", text = block.thinking, raw = raw })
    end
  end
  return out
end

---@param raw table
---@return fieldguide.Event[]
function Normaliser:_user(raw)
  local msg = raw.message or {}
  if type(msg.content) ~= "table" then
    -- A plain-text user line is our own prompt echoed, or Claude's
    -- "[Request interrupted by user]" marker; the `result` that follows says
    -- the same thing in a form that can be acted on.
    return {}
  end
  local out = {}
  for _, block in ipairs(msg.content) do
    if block.type == "tool_result" then
      local id = block.tool_use_id or ""
      local call = self._calls[id] or {}
      local text = content_text(block.content)
      local is_error = block.is_error == true
      local blocked = false
      if is_error and text and text:match(HOOK_DENIED) then
        text = text:gsub(HOOK_DENIED, "", 1)
        blocked = vim.startswith(text, OURS)
      end

      local details = nil
      local result = raw.tool_use_result
      if type(result) == "table" and result.structuredPatch then
        local diff, first = M.diff(result.structuredPatch)
        details = { diff = diff, firstChangedLine = first }
      end

      -- The same place pi puts it: appended to the write's own result, so the
      -- transcript shows the edit and the boot that checked it together.
      local verify = self._verify[id]
      if verify then
        text = (text and text ~= "") and (text .. "\n" .. verify) or verify
        self._verify[id] = nil
      end

      table.insert(out, {
        kind = "tool_end",
        tool_call_id = block.tool_use_id,
        tool = call.tool or "tool",
        args = call.args,
        text = text,
        details = details,
        is_error = is_error,
        blocked = blocked,
        verify = verify,
        raw = raw,
      })
      self._calls[id] = nil
    end
  end
  return out
end

---@param raw table
---@return fieldguide.Event[]
function Normaliser:_system(raw)
  local sub = raw.subtype
  if sub == "init" then
    self.session_id = raw.session_id or self.session_id
    self.model = raw.model or self.model
    -- One init per user turn, which is exactly where pi says agent_start.
    return { { kind = "run_start", session_id = raw.session_id, model = raw.model, raw = raw } }
  elseif sub == "status" then
    -- "requesting" is every model round trip; the spinner already says that.
    if raw.status == nil or raw.status == "requesting" then
      return {}
    end
    local text = raw.status == "compacting" and "compacting context" or tostring(raw.status)
    return { { kind = "status", what = raw.status, text = text, raw = raw } }
  elseif sub == "compact_boundary" then
    return { { kind = "status", what = "compaction_end", text = "compaction done", raw = raw } }
  elseif sub == "thinking_tokens" then
    return {}
  elseif sub == "hook_started" then
    if raw.hook_event == "PostToolUse" then
      return { { kind = "status", what = "verify", text = "verifying", raw = raw } }
    end
    return {}
  elseif sub == "hook_response" then
    -- A hook that crashed rather than decided. Claude carries on without it,
    -- which for the gate would be the dangerous kind of quiet; say so.
    if raw.outcome and raw.outcome ~= "success" then
      local why = (raw.stderr and raw.stderr ~= "") and raw.stderr or ("exit " .. tostring(raw.exit_code))
      return {
        {
          kind = "error",
          source = "hook",
          message = ("%s failed: %s"):format(tostring(raw.hook_name), vim.trim(why)),
          raw = raw,
        },
      }
    end
    if raw.hook_event == "PostToolUse" then
      local out = decode_hook_stdout(raw)
      local ours = out and out.fieldguide
      if type(ours) == "table" and ours.tool_use_id and type(ours.verify) == "string" then
        -- Held until the tool_result for that call arrives, which Claude
        -- writes after its PostToolUse hooks have finished.
        self._verify[ours.tool_use_id] = ours.verify
      end
    end
    return {}
  end
  return { { kind = "unknown", note = "system." .. tostring(sub), raw = raw } }
end

---@param raw table
---@return fieldguide.Event[]
function Normaliser:_result(raw)
  local out = {}
  local key = raw.uuid or raw.session_id
  if raw.terminal_reason == "aborted_streaming" or raw.terminal_reason == "aborted_tools" then
    -- Asked for. Not an error, and not worth a line saying so.
    table.insert(out, { kind = "turn_end", stop_reason = "aborted", message = { timestamp = key }, raw = raw })
  elseif raw.is_error then
    local why = raw.result
    if type(why) ~= "string" or why == "" then
      why = type(raw.errors) == "table" and table.concat(raw.errors, "; ") or nil
    end
    if (not why or why == "") and raw.api_error_status then
      why = "API error " .. tostring(raw.api_error_status)
    end
    table.insert(out, {
      kind = "turn_end",
      stop_reason = "error",
      error = why or raw.subtype,
      message = { timestamp = key },
      raw = raw,
    })
  elseif STOP[raw.stop_reason or ""] == "length" then
    table.insert(out, { kind = "turn_end", stop_reason = "length", message = { timestamp = key }, raw = raw })
  end
  self.session_id = raw.session_id or self.session_id
  table.insert(out, { kind = "run_end", will_retry = false, session_id = raw.session_id, raw = raw })
  -- Claude does not retry behind a result, so the end of the run is also the
  -- point at which it is not coming back on its own.
  table.insert(out, { kind = "settled", session_id = raw.session_id, raw = raw })
  return out
end

---@param raw table a decoded stream-json line
---@return fieldguide.Event[]
function Normaliser:normalize(raw)
  local t = raw.type
  if t == "stream_event" then
    return self:_stream_event(raw)
  elseif t == "assistant" then
    return self:_assistant(raw)
  elseif t == "user" then
    return self:_user(raw)
  elseif t == "system" then
    return self:_system(raw)
  elseif t == "result" then
    return self:_result(raw)
  elseif t == "control_response" then
    local r = raw.response or {}
    return {
      {
        kind = "response",
        id = r.request_id,
        success = r.subtype == "success",
        error = r.error,
        raw = raw,
      },
    }
  elseif t == "rate_limit_event" then
    local info = raw.rate_limit_info or {}
    if info.status == nil or info.status == "allowed" or info.status == "allowed_warning" then
      return {}
    end
    return { { kind = "status", what = "rate_limit", text = "rate limited: " .. tostring(info.status), raw = raw } }
  end
  return { { kind = "unknown", note = tostring(t), raw = raw } }
end

return M
