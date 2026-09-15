-- The protocol adapter: one agent subprocess, spoken to over JSONL.
--
-- Owns the process, the framing and the normalisation, and hands
-- `fieldguide.Event`s to whoever subscribed. No rendering: the panel is built
-- on top of this, and a second agent protocol is built beside it.
--
-- The threading rule is the important one: stdout arrives in a libuv callback,
-- where almost the entire nvim API is off limits. Everything crosses into
-- scheduled context before a subscriber sees it.

local cfg = require("fieldguide.config")
local events = require("fieldguide.rpc.events")
local framing = require("fieldguide.rpc.framing")

local M = {}

---@class fieldguide.RpcSession
---@field private _proc table
---@field private _framer fieldguide.Framer
---@field private _subs table<integer, fun(event: fieldguide.Event)>
---@field private _next_sub integer
---@field private _next_id integer
---@field private _pending table<string, string> id -> command, awaiting a response
---@field private _stopped boolean
---@field stats table
local Session = {}
Session.__index = Session

---@param opts table? { session?: string } an existing session id to carry on
---@return string[]
function M.argv(opts)
  opts = opts or {}
  local o = cfg.options
  local api = require("fieldguide.api")
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")

  local tools = { "read", "edit", "write", "grep", "find", "ls" }
  for _, verb in ipairs(api.verbs()) do
    table.insert(tools, "nvim_" .. verb)
  end
  -- Named unconditionally: --tools is an allowlist, and the extension only
  -- registers these when an index file is actually present. Listing a tool that
  -- was never registered costs nothing; omitting one that was hides it.
  vim.list_extend(tools, { "nvim_plugins", "nvim_plugin" })

  local argv = { o.cmd, "--mode", "rpc" }
  -- Without this the agent is a general coding assistant that happens to have
  -- our tools, and answers questions about this editor from training data.
  vim.list_extend(argv, { "--append-system-prompt", root .. "/prompt/system.md" })
  -- Same hermetic posture as the sidebar (§5.2): our extension and nothing
  -- else, but AGENTS.md discovery left on. Without this the panel would run a
  -- plain agent with no fieldguide verbs at all.
  vim.list_extend(argv, {
    "--no-extensions",
    "--no-skills",
    "--no-prompt-templates",
    "--extension",
    root .. "/extension/nvim.ts",
    "--tools",
    table.concat(tools, ","),
  })
  -- Sessions are persisted where the panel can find them again, and resuming
  -- one hands the agent back its own context rather than a transcript of it.
  local sessions = require("fieldguide.chat.history").dir()
  vim.fn.mkdir(sessions, "p")
  vim.list_extend(argv, { "--session-dir", sessions })
  if opts.session then
    vim.list_extend(argv, { "--session", opts.session })
  end
  if o.provider then
    vim.list_extend(argv, { "--provider", o.provider })
  end
  if o.model then
    vim.list_extend(argv, { "--model", o.model })
  end
  return argv
end

---@param opts table? { argv?: string[], cwd?: string, env?: table }
---@return fieldguide.RpcSession?, string?
function M.start(opts)
  opts = opts or {}
  local argv = opts.argv or M.argv(opts)

  if vim.fn.executable(argv[1]) == 0 then
    return nil, ("%q is not on PATH"):format(argv[1])
  end

  local self = setmetatable({
    _framer = framing.new(),
    _subs = {},
    _next_sub = 1,
    _next_id = 1,
    _pending = {},
    _stopped = false,
    stats = { lines = 0, events = 0, bytes = 0, decode_errors = 0, unknown = 0 },
  }, Session)

  local ok, proc = pcall(vim.system, argv, {
    cwd = opts.cwd or cfg.paths().config_dir,
    -- Merged with the parent environment, not replacing it: the agent still
    -- needs PATH, HOME and its own credentials.
    env = opts.env or require("fieldguide.env").agent(),
    stdin = true,
    -- Raw chunks, deliberately. `jobstart`'s line splitting hands back a list
    -- whose first element continues the previous chunk's last element, which is
    -- the exact subtlety this adapter should own explicitly rather than inherit.
    stdout = function(err, data)
      if err then
        self:_emit_async({ kind = "error", source = "stdout", message = tostring(err), raw = {} })
        return
      end
      if data == nil then
        self:_finish_stream()
        return
      end
      self:_on_chunk(data)
    end,
    stderr = function(err, data)
      if data and data ~= "" then
        self:_emit_async({ kind = "error", source = "stderr", message = vim.trim(data), raw = {} })
      end
    end,
  }, function(res)
    self:_on_exit(res)
  end)

  if not ok then
    return nil, ("failed to spawn %s: %s"):format(argv[1], tostring(proc))
  end

  self._proc = proc
  return self, nil
end

---Called in a libuv callback. Frame here (cheap, pure string work), then hand
---off — decoding and dispatch happen on the main loop.
---@param chunk string
function Session:_on_chunk(chunk)
  self.stats.bytes = self.stats.bytes + #chunk
  local lines = self._framer:feed(chunk)
  if #lines == 0 then
    return
  end
  vim.schedule(function()
    for _, line in ipairs(lines) do
      self:_on_line(line)
    end
  end)
end

---@param line string
function Session:_on_line(line)
  self.stats.lines = self.stats.lines + 1
  local decoded, err = framing.decode(line)
  if not decoded then
    self.stats.decode_errors = self.stats.decode_errors + 1
    self:_emit({
      kind = "error",
      source = "protocol",
      message = ("undecodable line: %s"):format(err),
      line = line,
      raw = {},
    })
    return
  end

  local event = events.normalize(decoded)
  if event.kind == "unknown" then
    self.stats.unknown = self.stats.unknown + 1
  end
  if event.kind == "response" and event.id then
    self._pending[event.id] = nil
  end
  self:_emit(event)
end

function Session:_finish_stream()
  local rest = self._framer:flush()
  if rest then
    vim.schedule(function()
      self:_on_line(rest)
    end)
  end
end

---@param res table
function Session:_on_exit(res)
  self._stopped = true
  vim.schedule(function()
    self:_emit({
      kind = "exit",
      code = res.code,
      signal = res.signal,
      raw = {},
    })
  end)
end

---Dispatch to subscribers. Already on the main loop.
---@param event fieldguide.Event
function Session:_emit(event)
  self.stats.events = self.stats.events + 1
  for _, fn in pairs(self._subs) do
    -- One bad subscriber must not take down the stream.
    local ok, err = pcall(fn, event)
    if not ok then
      vim.notify("fieldguide rpc subscriber error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

---@param event fieldguide.Event
function Session:_emit_async(event)
  vim.schedule(function()
    self:_emit(event)
  end)
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

---Send a command. Returns the correlation id so a caller can match the
---`response` event.
---@param command table
---@param opts table? { expect_response?: boolean } default true
---@return string?, string?
function Session:send(command, opts)
  if self._stopped then
    return nil, "the agent process has exited"
  end
  local id = command.id
  if not id then
    id = ("fg-%d"):format(self._next_id)
    self._next_id = self._next_id + 1
    command.id = id
  end

  -- Not everything we write is a command. A reply to a dialog carries the
  -- agent's id and is answered by the agent resuming, never by a `response` —
  -- tracking it would leave an entry pending forever.
  local expects = opts == nil or opts.expect_response ~= false
  if expects then
    self._pending[id] = command.type
  end

  local ok, err = pcall(function()
    self._proc:write(framing.encode(command))
  end)
  if not ok then
    self._pending[id] = nil
    return nil, tostring(err)
  end
  return id, nil
end

---@param message string
---@param opts table? { streaming_behavior?: "steer"|"followUp" }
---@return string?, string?
function Session:prompt(message, opts)
  opts = opts or {}
  local command = { type = "prompt", message = message }
  if opts.streaming_behavior then
    -- Without this, prompting mid-stream is rejected rather than queued.
    command.streamingBehavior = opts.streaming_behavior
  end
  return self:send(command)
end

---Answer a blocking `ui_request`. Not replying leaves the agent stalled until
---its own timeout, if it set one.
---@param id string
---@param value any
---@param cancelled boolean?
function Session:answer_ui(id, value, cancelled)
  return self:send({
    type = "extension_ui_response",
    id = id,
    value = value,
    cancelled = cancelled == true or nil,
  }, { expect_response = false })
end

---@return boolean
function Session:is_running()
  return not self._stopped
end

---@return string[] ids of commands still awaiting a response
function Session:pending()
  return vim.tbl_keys(self._pending)
end

function Session:stop()
  if self._proc and not self._stopped then
    self._stopped = true
    pcall(function()
      self._proc:write(nil) -- close stdin; let the agent shut down cleanly
    end)
    pcall(function()
      self._proc:kill("sigterm")
    end)
  end
end

return M
