-- The second protocol: ACP, the Agent Client Protocol.
--
-- One adapter for every harness that speaks it — opencode natively, Claude Code
-- and Codex through their ACP bridges — so nothing here may assume which one is
-- on the other end. The renderer sees `fieldguide.Event`s exactly as it does
-- from pi; the differences stay in this file.
--
-- ACP is not pi's protocol with other names. Three things shape this module:
--
--   * It is bidirectional JSON-RPC. The agent sends *requests* too (permission
--     prompts, file reads), and an unanswered request stalls it forever.
--   * There is no start event and no end event. A run is the lifetime of one
--     `session/prompt` request: it starts when we send it and ends when its
--     response arrives carrying a `stopReason`.
--   * It is stateful where pi is not. A tool call is announced with a title and
--     no arguments, and the arguments arrive in a later update; a result may
--     carry a different title again. The normaliser remembers each call by id.
--
-- The process, framing and threading are the pi adapter's, reused as they are:
-- `rpc.start` hands back every decoded line, and this module reads the JSON-RPC
-- message out of it.

local M = {}

M.PROTOCOL_VERSION = 1

-- ---------------------------------------------------------------------------
-- Encoders. Pure: each returns the message as a table, for `framing.encode`.
-- ---------------------------------------------------------------------------

---@param id integer
---@param method string
---@param params table?
---@return table
function M.request(id, method, params)
  return { jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() }
end

---@param method string
---@param params table?
---@return table
function M.notification(method, params)
  return { jsonrpc = "2.0", method = method, params = params or vim.empty_dict() }
end

---@param id integer|string
---@param result any
---@return table
function M.result(id, result)
  -- `vim.NIL`, not nil: a missing `result` is not a response at all.
  return { jsonrpc = "2.0", id = id, result = result == nil and vim.NIL or result }
end

---@param id integer|string
---@param code integer
---@param message string
---@return table
function M.error_reply(id, code, message)
  return { jsonrpc = "2.0", id = id, error = { code = code, message = message } }
end

M.METHOD_NOT_FOUND = -32601

---No capabilities advertised, on purpose. Offering `fs` would make the client
---the agent's file system, and every read and write would then need a gate
---here as well as the one inside the harness. Offering `terminal` would hand
---the agent a shell, which fieldguide does not grant on any harness.
---@param id integer
---@return table
function M.initialize(id)
  return M.request(id, "initialize", {
    protocolVersion = M.PROTOCOL_VERSION,
    clientCapabilities = vim.empty_dict(),
    clientInfo = { name = "fieldguide.nvim", version = "0" },
  })
end

---The contract's `{ command, args, env }` as ACP's stdio server entry. ACP wants
---the environment as a list of pairs, not a map, and it is sorted so the same
---options always encode to the same bytes.
---@param mcp { command: string, args: string[]?, env: table<string,string>? }?
---@return table[]
function M.mcp_servers(mcp)
  if not mcp then
    return {}
  end
  local env = {}
  for name, value in pairs(mcp.env or {}) do
    table.insert(env, { name = name, value = tostring(value) })
  end
  table.sort(env, function(a, b)
    return a.name < b.name
  end)
  return { { name = mcp.name or "fieldguide", command = mcp.command, args = mcp.args or {}, env = env } }
end

---@param id integer
---@param cwd string
---@param mcp table?
---@return table
function M.session_new(id, cwd, mcp)
  return M.request(id, "session/new", { cwd = cwd, mcpServers = M.mcp_servers(mcp) })
end

---@param id integer
---@param session_id string
---@param cwd string
---@param mcp table?
---@return table
function M.session_load(id, session_id, cwd, mcp)
  return M.request(id, "session/load", { sessionId = session_id, cwd = cwd, mcpServers = M.mcp_servers(mcp) })
end

---@param id integer
---@param session_id string
---@param text string
---@return table
function M.session_prompt(id, session_id, text)
  return M.request(id, "session/prompt", { sessionId = session_id, prompt = { { type = "text", text = text } } })
end

---A notification, not a request: the answer is the pending prompt's response
---arriving with `stopReason = "cancelled"`.
---@param session_id string
---@return table
function M.session_cancel(session_id)
  return M.notification("session/cancel", { sessionId = session_id })
end

-- ---------------------------------------------------------------------------
-- Permission policy.
-- ---------------------------------------------------------------------------

---Tool kinds a permission request may be granted for.
---
---Granted without asking, because the prompt is not where fieldguide's
---enforcement lives. Every file tool has already been through the harness's
---gate (and, where there is one, the OS sandbox) by the time it can touch
---anything, and pi — the reference harness — never asks at all. Putting a
---dialog in front of each edit would be a second, weaker gate the user learns
---to click through.
---
---Not granted: `execute` and `fetch`. fieldguide gives no harness a shell or
---the network, so a request for either means a harness's configuration has
---drifted from its profile, and the answer is no rather than a question.
M.GRANTED_KINDS = { read = true, edit = true, delete = true, move = true, search = true, think = true, other = true }

---@param params table the `session/request_permission` params
---@return table outcome, boolean granted
function M.permission_outcome(params)
  local call = type(params) == "table" and params.toolCall or {}
  local options = type(params) == "table" and params.options or {}
  local granted = M.GRANTED_KINDS[call.kind or "other"] == true

  -- Once, never always: an "always" answer can outlive this session inside the
  -- harness's own settings, where fieldguide can no longer see it. An agent
  -- that offers only "always" is cancelled below rather than granted for
  -- good. A lasting refusal is kept as a fallback: it can only narrow what
  -- the harness does.
  local wanted = granted and { "allow_once" } or { "reject_once", "reject_always" }
  for _, kind in ipairs(wanted) do
    for _, option in ipairs(type(options) == "table" and options or {}) do
      if option.kind == kind then
        return { outcome = "selected", optionId = option.optionId }, granted
      end
    end
  end
  -- No option of the right kind offered. Cancelling is the one answer every
  -- agent must accept, and it never grants anything.
  return { outcome = "cancelled" }, false
end

-- ---------------------------------------------------------------------------
-- Normalisation.
-- ---------------------------------------------------------------------------

---A harness's name for one of fieldguide's own tools, back to the name the
---renderer knows. Each harness namespaces MCP tools its own way.
local MCP_PREFIXES = { "^mcp__fieldguide__", "^fieldguide_" }

---Harness file tools with a pi equivalent, so they render as pi's do.
local ALIASES = { glob = "find", list = "ls" }

---What a call is when its title has stopped being its name. A replayed call
---arrives with the *result's* title (a path, a sentence), and only its kind
---and input say what it was.
---@param kind string?
---@param input table
---@return string
local function name_from_shape(kind, input)
  if type(input.patchText) == "string" then
    return "apply_patch"
  end
  return kind or "tool"
end

---Names a title can be trusted to be even in a replay, where a bare word is as
---likely to be a file the call read (`Makefile`) as the tool that read it.
local KNOWN_TOOLS = {
  read = true,
  write = true,
  edit = true,
  multiedit = true,
  apply_patch = true,
  patch = true,
  grep = true,
  glob = true,
  list = true,
  find = true,
  ls = true,
  todowrite = true,
  todoread = true,
}

---@param name string
---@return boolean
local function is_mcp(name)
  for _, prefix in ipairs(MCP_PREFIXES) do
    if name:find(prefix) then
      return true
    end
  end
  return false
end

---@param update table a `tool_call` or `tool_call_update`
---@param replaying boolean? titles in a replay describe results, not tools
---@return string?
function M.tool_name(update, replaying)
  local meta = type(update._meta) == "table" and update._meta or {}
  -- claude-agent-acp puts the real name here and a sentence in `title`.
  local name = type(meta.claudeCode) == "table" and meta.claudeCode.toolName or nil
  if type(name) ~= "string" then
    local title = update.title
    if type(title) == "string" and title:match("^[%w_%-]+$") then
      if not replaying or KNOWN_TOOLS[title] or is_mcp(title) then
        name = title
      end
    end
  end
  if type(name) ~= "string" then
    return nil
  end
  for _, prefix in ipairs(MCP_PREFIXES) do
    local stripped = name:gsub(prefix, "", 1)
    if stripped ~= name then
      return stripped
    end
  end
  return ALIASES[name] or name
end

---The input as the renderer expects it: `path` where pi would have one. The
---original keys stay, so nothing a harness sent is lost.
---@param input table
---@param locations table?
---@return table
local function canonical_args(input, locations)
  local args = vim.deepcopy(input)
  if args.path == nil then
    args.path = args.filePath or args.file_path or args.filepath
  end
  if args.path == nil and type(args.patchText) == "string" then
    args.path = args.patchText:match("%*%*%* %a+ File: ([^\n]+)")
  end
  if args.path == nil and type(locations) == "table" and type(locations[1]) == "table" then
    args.path = locations[1].path
  end
  return args
end

---Flatten ACP tool-call content into plain text. Diffs and terminals are named
---rather than dropped, as `events.result_text` does for pi's non-text blocks.
---@param content table?
---@return string?
function M.content_text(content)
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "table" then
      if item.type == "content" and type(item.content) == "table" then
        local block = item.content
        if block.type == "text" and type(block.text) == "string" then
          table.insert(parts, block.text)
        elseif block.type then
          table.insert(parts, ("<%s>"):format(block.type))
        end
      elseif item.type == "diff" then
        table.insert(parts, ("<diff %s>"):format(tostring(item.path)))
      elseif item.type then
        table.insert(parts, ("<%s>"):format(item.type))
      end
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n")
end

---ACP's stop reasons, in pi's vocabulary: the renderer already knows how to
---announce a reply cut off at the limit or a turn that failed.
local STOP_REASONS = {
  end_turn = { "stop" },
  max_tokens = { "length" },
  max_turn_requests = { "error", "the agent hit its limit on model requests for one turn" },
  refusal = { "error", "the model refused to continue" },
  cancelled = { "aborted" },
}

---@param reason string?
---@return string?, string? stop reason, error message
function M.stop_reason(reason)
  local mapped = STOP_REASONS[reason or ""]
  if not mapped then
    return reason, nil
  end
  return mapped[1], mapped[2]
end

---Updates that are bookkeeping for a harness's own UI and say nothing a reader
---of the transcript needs. Recognised, so they do not surface as `unknown`.
local QUIET = {
  available_commands_update = true,
  current_mode_update = true,
  config_option_update = true,
  session_info_update = true,
  usage_update = true,
}

---@class fieldguide.AcpNormalizer
---@field private _requests table<string, string> id -> method, awaiting a response
---@field private _calls table<string, { tool: string?, kind: string?, args: table, started: boolean, ended: boolean }>
---@field private _user string[] a replayed user message, gathered until it ends
---@field private _said boolean content since the last `settled`
---@field replaying boolean
---@field session_id string?
---@field capabilities table
local Normalizer = {}
Normalizer.__index = Normalizer

---@return fieldguide.AcpNormalizer
function M.normalizer()
  return setmetatable({
    _requests = {},
    _calls = {},
    _user = {},
    _said = false,
    replaying = false,
    session_id = nil,
    capabilities = {},
  }, Normalizer)
end

---Record a request we sent, so its response can be read for what it answers.
---@param id integer|string
---@param method string
function Normalizer:expect(id, method)
  self._requests[tostring(id)] = method
end

---@return string[] methods still awaiting a response
function Normalizer:pending()
  return vim.tbl_values(self._requests)
end

---@param out fieldguide.Event[]
---@param raw table
function Normalizer:_flush_user(out, raw)
  if #self._user > 0 then
    table.insert(out, { kind = "user", text = table.concat(self._user), raw = raw })
    self._user = {}
  end
end

---@param update table
---@param raw table
---@return fieldguide.Event[]
function Normalizer:_on_tool(update, raw)
  local out = {}
  local id = update.toolCallId
  local call = self._calls[id or ""]
  if not call then
    call = { args = {}, started = false, ended = false }
    self._calls[id or ""] = call
  end

  -- The first name seen is the one kept: later titles describe the result.
  call.tool = call.tool or M.tool_name(update, self.replaying)
  call.kind = call.kind or update.kind
  if type(update.rawInput) == "table" and next(update.rawInput) ~= nil then
    call.args = canonical_args(update.rawInput, update.locations)
  elseif call.args.path == nil and type(update.locations) == "table" and update.locations[1] then
    call.args = canonical_args(call.args, update.locations)
  end
  local tool = call.tool or name_from_shape(call.kind, call.args)

  if not call.started then
    call.started = true
    table.insert(out, { kind = "tool_start", tool_call_id = id, tool = tool, args = call.args, raw = raw })
  end

  local status = update.status
  if (status == "completed" or status == "failed") and not call.ended then
    call.ended = true
    self._said = true
    local text = M.content_text(update.content)
    if text == nil and type(update.rawOutput) == "table" and type(update.rawOutput.output) == "string" then
      text = update.rawOutput.output
    end
    table.insert(out, {
      kind = "tool_end",
      tool_call_id = id,
      tool = tool,
      args = call.args,
      text = text,
      is_error = status == "failed",
      raw = raw,
    })
  elseif update.content ~= nil and not call.ended then
    table.insert(out, {
      kind = "tool_update",
      tool_call_id = id,
      tool = tool,
      args = call.args,
      text = M.content_text(update.content),
      raw = raw,
    })
  end
  return out
end

---@param update table
---@param raw table
---@return fieldguide.Event[]
function Normalizer:_on_update(update, raw)
  local k = update.sessionUpdate
  local out = {}

  -- A replayed user message is the boundary between two turns: close the one
  -- before it, the way the live stream closes each turn with `settled`.
  if k == "user_message_chunk" then
    if not self.replaying then
      -- Live, the panel has already echoed what was typed.
      return out
    end
    if self._said then
      table.insert(out, { kind = "settled", raw = raw })
      self._said = false
    end
    local content = update.content or {}
    if content.type == "text" and type(content.text) == "string" then
      table.insert(self._user, content.text)
    end
    return out
  end
  self:_flush_user(out, raw)

  if k == "agent_message_chunk" or k == "agent_thought_chunk" then
    local content = update.content or {}
    local kind = k == "agent_message_chunk" and "text_delta" or "thinking_delta"
    if content.type == "text" then
      self._said = true
      table.insert(out, { kind = kind, message_id = update.messageId, text = content.text or "", raw = raw })
    else
      table.insert(out, { kind = "unknown", note = ("%s.%s"):format(k, tostring(content.type)), raw = raw })
    end
  elseif k == "tool_call" or k == "tool_call_update" then
    vim.list_extend(out, self:_on_tool(update, raw))
  elseif k == "plan" then
    table.insert(out, { kind = "status", what = "plan", text = "planning", raw = raw })
  elseif not QUIET[k] then
    table.insert(out, { kind = "unknown", note = "session/update." .. tostring(k), raw = raw })
  end
  return out
end

---@param msg table a decoded response
---@return fieldguide.Event[]
function Normalizer:_on_response(msg)
  local key = tostring(msg.id)
  local method = self._requests[key]
  self._requests[key] = nil
  local out = {}
  local failure = type(msg.error) == "table" and (msg.error.message or vim.json.encode(msg.error)) or nil
  local result = type(msg.result) == "table" and msg.result or {}

  if method == "session/prompt" then
    if failure then
      table.insert(out, { kind = "error", source = "agent", message = failure, raw = msg })
    else
      local stop, err = M.stop_reason(result.stopReason)
      -- The renderer tells repeats of one outcome from a second failure by the
      -- message's timestamp; the request id is unique per turn.
      local message = { timestamp = msg.id }
      table.insert(out, { kind = "turn_end", message = message, stop_reason = stop, error = err, raw = msg })
    end
    table.insert(out, { kind = "run_end", will_retry = false, raw = msg })
    table.insert(out, { kind = "settled", raw = msg })
    self._said = false
    return out
  end

  if method == "initialize" and not failure then
    self.capabilities = type(result.agentCapabilities) == "table" and result.agentCapabilities or {}
  elseif method == "session/new" and not failure then
    self.session_id = result.sessionId
  elseif method == "session/load" then
    self:_flush_user(out, msg)
    self.replaying = false
    if self._said then
      table.insert(out, { kind = "settled", raw = msg })
      self._said = false
    end
  end

  table.insert(out, {
    kind = "response",
    id = msg.id,
    command = method,
    success = failure == nil,
    error = failure,
    raw = msg,
  })
  return out
end

---One decoded message in, any number of events out: a prompt's response ends
---the turn, the run and the wait all at once, and a replayed update can close
---one turn as it opens the next.
---
---Requests from the agent come back as a single `acp_request` event. Answering
---them is the client's job, not the normaliser's.
---@param msg table
---@return fieldguide.Event[]
function Normalizer:normalize(msg)
  if type(msg) ~= "table" then
    return { { kind = "unknown", note = "not an object", raw = {} } }
  end
  if msg.method ~= nil and msg.id ~= nil then
    return { { kind = "acp_request", id = msg.id, method = msg.method, params = msg.params, raw = msg } }
  end
  if msg.method == "session/update" then
    local params = type(msg.params) == "table" and msg.params or {}
    if type(params.update) ~= "table" then
      return { { kind = "unknown", note = "session/update without an update", raw = msg } }
    end
    return self:_on_update(params.update, msg)
  end
  if msg.method ~= nil then
    return { { kind = "unknown", note = tostring(msg.method), raw = msg } }
  end
  -- Keyed on the id alone: `"result": null` is a valid response (session/load
  -- answers with one), and it decodes to no `result` field at all.
  if msg.id ~= nil then
    return self:_on_response(msg)
  end
  return { { kind = "unknown", note = "not JSON-RPC", raw = msg } }
end

-- ---------------------------------------------------------------------------
-- The client: a session with the same surface as the pi one, so the panel can
-- hold either.
-- ---------------------------------------------------------------------------

---@class fieldguide.AcpSession
---@field private _rpc fieldguide.RpcSession
---@field private _norm fieldguide.AcpNormalizer
---@field private _subs table<integer, fun(event: fieldguide.Event)>
---@field private _next_sub integer
---@field private _next_id integer
---@field private _queue string[] prompts waiting for a session, or for the turn before them
---@field private _start_error string? why no session could be had, once that is known
---@field private _in_flight integer? the id of the prompt now running
---@field private _ready boolean
---@field private _opts table `ready`, if set, is asked once a session exists, until it returns nil to go on or `ready_timeout_ms` (10s) passes
---@field private _permission fun(params: table): table, boolean
local Session = {}
Session.__index = Session

---@param opts table { argv: string[], cwd: string, env?: table, session?: string, mcp?: table, permission?: fun(params: table): table, boolean }
---@return fieldguide.AcpSession?, string?
function M.start(opts)
  local rpc = require("fieldguide.rpc")
  local inner, err = rpc.start({ argv = opts.argv, cwd = opts.cwd, env = opts.env })
  if not inner then
    return nil, err
  end

  local self = setmetatable({
    _rpc = inner,
    _norm = M.normalizer(),
    _subs = {},
    _next_sub = 1,
    _next_id = 1,
    _queue = {},
    _in_flight = nil,
    _ready = false,
    _opts = opts,
    _permission = opts.permission or M.permission_outcome,
  }, Session)

  inner:on_event(function(event)
    self:_on_inner(event)
  end)
  self:_request(M.initialize, {})
  return self, nil
end

---@param encode fun(id: integer, ...): table
---@param args any[]
---@return integer?, string?
function Session:_request(encode, args)
  local id = self._next_id
  self._next_id = id + 1
  local msg = encode(id, unpack(args))
  self._norm:expect(id, msg.method)
  -- pi-shaped bookkeeping would file this under a `type` it does not have and
  -- wait forever for a pi `response`; the normaliser does the correlating.
  local _, err = self._rpc:send(msg, { expect_response = false })
  if err then
    return nil, err
  end
  return id, nil
end

---@param msg table
function Session:_write(msg)
  if msg.id == nil then
    -- The pi session stamps an id on anything that has none, and an id turns
    -- a JSON-RPC notification into a request the agent then has to answer. A
    -- notification is written as it is.
    local ok, err = self._rpc:write(msg)
    return ok and "notification" or nil, err
  end
  return self._rpc:send(msg, { expect_response = false })
end

---@param event fieldguide.Event
function Session:_emit(event)
  for _, fn in pairs(self._subs) do
    local ok, err = pcall(fn, event)
    if not ok then
      vim.notify("fieldguide acp subscriber error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

---Everything the pi adapter hands up. Its own events — the process exiting, a
---line that would not decode, stderr — pass through untouched. Everything else
---is a JSON-RPC message the pi normaliser did not recognise, carried in `raw`.
---@param event fieldguide.Event
function Session:_on_inner(event)
  if event.kind ~= "unknown" then
    self:_emit(event)
    return
  end
  for _, e in ipairs(self._norm:normalize(event.raw)) do
    if e.kind == "acp_request" then
      self:_answer(e)
    else
      -- Emitted before acting on it: a `settled` that sends the next queued
      -- prompt must reach the panel before that prompt's `run_start` does.
      self:_emit(e)
      self:_after(e)
    end
  end
end

---The handshake, and the prompt queue, advance on responses.
---@param e fieldguide.Event
function Session:_after(e)
  if e.kind ~= "response" and e.kind ~= "settled" then
    return
  end
  local opts = self._opts
  if e.kind == "response" and e.command == "initialize" then
    if not e.success then
      return
    end
    local resume = opts.session
    if resume and self._norm.capabilities.loadSession == true then
      self._norm.replaying = true
      self._norm.session_id = resume
      self:_request(M.session_load, { resume, opts.cwd, opts.mcp })
    else
      if resume then
        -- Said, not swallowed: a question asked now lands in a fresh context,
        -- and the reader should know that before asking it.
        vim.schedule(function()
          self:_emit({
            kind = "error",
            source = "acp",
            message = "this agent cannot resume a session; starting a new one",
            raw = {},
          })
        end)
      end
      self:_request(M.session_new, { opts.cwd, opts.mcp })
    end
  elseif e.kind == "response" and e.command == "session/load" and not e.success then
    -- Advertised and then refused: an expired or deleted session, most often.
    -- The questions waiting behind the handshake still deserve an answer, in a
    -- new context, said out loud like the no-load case above.
    self._norm.replaying = false
    self._norm.session_id = nil
    self:_emit({
      kind = "error",
      source = "acp",
      message = ("could not resume the session (%s); starting a new one"):format(tostring(e.error)),
      raw = {},
    })
    self:_request(M.session_new, { opts.cwd, opts.mcp })
  elseif e.kind == "response" and (e.command == "session/new" or e.command == "session/load") then
    if not e.success then
      self:_fail_start(e.error)
      return
    end
    self:_await_ready(vim.uv.now() + (opts.ready_timeout_ms or 10000))
  elseif e.kind == "settled" and self._in_flight then
    self._in_flight = nil
    self:_drain()
  end
end

---@param e fieldguide.Event an `acp_request`
function Session:_answer(e)
  if e.method == "session/request_permission" then
    local outcome, granted = self._permission(e.params or {})
    self:_write(M.result(e.id, { outcome = outcome }))
    if not granted then
      local call = type(e.params) == "table" and e.params.toolCall or {}
      self:_emit({
        kind = "error",
        source = "permission",
        message = ("refused %s: %s"):format(tostring(call.kind), tostring(call.title)),
        raw = e.raw,
      })
    end
    return
  end
  -- fs/* and terminal/* were never advertised; anything else is newer than
  -- this adapter. Either way the agent gets an answer and does not stall.
  self:_write(M.error_reply(e.id, M.METHOD_NOT_FOUND, ("fieldguide does not provide %s"):format(e.method)))
end

---No session can be had. Every prompt waiting for one is told so and settled,
---rather than left queued behind a handshake that is over, and later ones are
---refused at once.
---@param why string?
---@param verbatim boolean? `why` is the whole message, not the agent's reason
function Session:_fail_start(why, verbatim)
  self._start_error = verbatim and tostring(why)
    or ("the agent did not start a session: %s"):format(tostring(why or "no reason given"))
  local waiting = #self._queue
  self._queue = {}
  self:_emit({ kind = "error", source = "acp", message = self._start_error, raw = {} })
  if waiting > 0 then
    self:_emit({ kind = "settled", raw = {} })
  end
end

---The harness's last word before a prompt goes in: whether what it promises
---(a gate, for opencode's plugin) is actually in place. Asked until it says
---yes or the deadline passes, because a harness may finish setting up a moment
---after its session exists; prompts wait in the queue meanwhile. A no at the
---deadline is a session that never started, and the agent behind it is stopped.
---@param deadline integer `vim.uv.now()` milliseconds
function Session:_await_ready(deadline)
  -- Stopped meanwhile: on purpose, or the agent died, which its exit event
  -- already says. Either way not a start that failed, and nothing to add.
  if not self:is_running() then
    return
  end
  local check = self._opts.ready
  local not_ready = check and check() or nil
  if not not_ready then
    self._ready = true
    self:_drain()
  elseif vim.uv.now() >= deadline then
    self:_fail_start(not_ready, true)
    self:stop()
  else
    vim.defer_fn(function()
      self:_await_ready(deadline)
    end, 50)
  end
end

---Send the next queued prompt, if the session is up and nothing is running.
function Session:_drain()
  if not self._ready or self._in_flight or #self._queue == 0 then
    return
  end
  local text = table.remove(self._queue, 1)
  local id, err = self:_request(M.session_prompt, { self._norm.session_id, text })
  if not id then
    self:_emit({ kind = "error", source = "acp", message = err, raw = {} })
    return
  end
  self._in_flight = id
  -- ACP has no start event; the run starts when the prompt is sent.
  self:_emit({ kind = "run_start", raw = {} })
end

---@param fn fun(event: fieldguide.Event)
---@return fun() unsubscribe
function Session:on_event(fn)
  local id = self._next_sub
  self._next_sub = id + 1
  self._subs[id] = fn
  return function()
    self._subs[id] = nil
  end
end

---Queue a prompt. ACP has no steering: a prompt sent mid-run waits for that
---run to end, which is where pi's steer would have landed it anyway once the
---current tool calls finished — later, but never lost.
---@param message string
---@param _opts table? accepted for the pi session's signature; ACP has no streaming behaviours
---@return string?, string?
function Session:prompt(message, _opts)
  -- The reason a session never started outlives the process it stopped.
  if self._start_error then
    return nil, self._start_error
  end
  if not self:is_running() then
    return nil, "the agent process has exited"
  end
  table.insert(self._queue, message)
  vim.schedule(function()
    self:_drain()
  end)
  return "queued", nil
end

---Stop the running turn. The prompt's response still arrives, with
---`stopReason = "cancelled"`, and ends the run the ordinary way.
function Session:interrupt()
  if self._norm.session_id then
    self:_write(M.session_cancel(self._norm.session_id))
  end
end

---The pi session's generic `send`, for the one command the panel sends raw.
---@param command table
---@return string?, string?
function Session:send(command)
  if command.type == "abort" then
    self:interrupt()
    return "cancel", nil
  end
  return nil, ("%s is a pi command; this agent speaks ACP"):format(tostring(command.type))
end

---ACP has no dialogs of pi's kind, so there is never one to answer.
function Session:answer_ui()
  return nil, "ACP sessions raise no dialogs"
end

---@return boolean
function Session:is_running()
  return self._rpc:is_running()
end

---@return string[] methods still awaiting a response
function Session:pending()
  return self._norm:pending()
end

---@return string? the agent's id for this session, to resume it later
function Session:session_id()
  return self._norm.session_id
end

function Session:stop()
  self._rpc:stop()
end

return M
