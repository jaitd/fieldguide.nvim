-- Codex over `codex exec --json`: what it writes, as `fieldguide.Event`s, and
-- a session over a process per prompt.
--
-- `codex exec` answers one prompt and exits. A conversation is a thread: the
-- first prompt starts one (`thread.started` names it), and each later prompt
-- runs `codex exec resume <thread>`. So the session here starts a process per
-- prompt, queues prompts that arrive while one runs, and carries the thread id
-- from each run to the next. Interrupting is stopping the process.
--
-- What Codex writes, one JSON object per line:
--
--   thread.started {thread_id}       the run, and the thread it belongs to
--   turn.started / turn.completed {usage} / turn.failed {error}
--   item.started / item.updated / item.completed {item}
--     agent_message {text}           whole, not streamed token by token
--     reasoning {text}
--     command_execution {command, aggregated_output, exit_code}
--     file_change {changes = [{path, kind}]}
--     mcp_tool_call {server, tool, arguments, result, error}
--     error {message}                a warning, mid-run
--   error {message}                  the run itself failed; turn.failed follows

local M = {}

-- Said on every run that fieldguide launches, because it writes its own hooks
-- and runs them untrusted by design (see harness/codex.lua). Not news.
local EXPECTED_WARNING = "dangerously%-bypass%-hook%-trust"

---The command without the login shell Codex wraps it in:
---`/bin/zsh -lc 'cat init.lua'` is `cat init.lua`.
---@param command string?
---@return string
function M.shell_command(command)
  if type(command) ~= "string" then
    return ""
  end
  local inner = command:match("^%S+ %-l?c '(.*)'$") or command:match('^%S+ %-l?c "(.*)"$')
  return inner or command
end

---@param result table?
---@return string?
-- What Codex logs when a hook refuses a call. The refusal never becomes an
-- item in the JSON stream, so this line is the only sign of it.
local BLOCKED = "(blocked by fieldguide: .-)%.? Command: "

---The refusal in a line of Codex's log, in fieldguide's own words, if any.
---@param line string
---@return string?
function M.blocked(line)
  local reason = line:match(BLOCKED) or line:match("(blocked by fieldguide: .*)$")
  return reason and vim.trim(reason) or nil
end

local function mcp_text(result)
  if type(result) ~= "table" or type(result.content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, c in ipairs(result.content) do
    if type(c) == "table" and type(c.text) == "string" then
      table.insert(parts, c.text)
    end
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

---A Codex item as the tool the panel knows how to draw, and its arguments.
---@param item table
---@return string tool, table args
function M.tool(item)
  local t = item.type
  if t == "command_execution" then
    return "bash", { command = M.shell_command(item.command) }
  elseif t == "file_change" then
    local changes = type(item.changes) == "table" and item.changes or {}
    local first = changes[1] or {}
    local paths = {}
    for _, c in ipairs(changes) do
      table.insert(paths, c.path)
    end
    return first.kind == "add" and "write" or "edit", { path = first.path, paths = paths }
  elseif t == "mcp_tool_call" then
    -- Our own verbs by their own names, as every other harness shows them.
    local name = item.server == "fieldguide" and item.tool or ("%s.%s"):format(item.server, item.tool)
    return name, type(item.arguments) == "table" and item.arguments or {}
  end
  return t or "tool", {}
end

local TOOL_ITEMS = { command_execution = true, file_change = true, mcp_tool_call = true, web_search = true }

---@class fieldguide.CodexNormaliser
---@field thread_id string?
---@field private _turn boolean a turn has started and not yet ended
local Normaliser = {}
Normaliser.__index = Normaliser

---@return fieldguide.CodexNormaliser
function M.new()
  return setmetatable({ thread_id = nil, _turn = false }, Normaliser)
end

---@param item table
---@return fieldguide.Event[]
function Normaliser:_completed(item, raw)
  local t = item.type
  if t == "agent_message" then
    local id = item.id
    return {
      { kind = "message_start", message = { id = id, role = "assistant" }, raw = raw },
      { kind = "text_delta", text = item.text or "", raw = raw },
      { kind = "text_end", raw = raw },
      { kind = "message_end", message = { id = id, timestamp = id }, raw = raw },
    }
  elseif t == "reasoning" then
    if type(item.text) ~= "string" or item.text == "" then
      return {}
    end
    return {
      { kind = "thinking_delta", text = item.text, raw = raw },
      { kind = "thinking_end", raw = raw },
    }
  elseif t == "error" then
    if (item.message or ""):match(EXPECTED_WARNING) then
      return {}
    end
    return { { kind = "error", source = "codex", message = item.message, raw = raw } }
  elseif TOOL_ITEMS[t] then
    local tool, args = M.tool(item)
    local text, is_error
    if t == "command_execution" then
      text = item.aggregated_output
      is_error = item.exit_code ~= nil and item.exit_code ~= 0
    elseif t == "file_change" then
      local lines = {}
      for _, c in ipairs(item.changes or {}) do
        table.insert(lines, ("%s %s"):format(c.kind or "update", c.path or "?"))
      end
      text = table.concat(lines, "\n")
      is_error = item.status == "failed"
    elseif t == "mcp_tool_call" then
      text = mcp_text(item.result)
      if item.error ~= nil and item.error ~= vim.NIL then
        is_error = true
        text = type(item.error) == "table" and (item.error.message or vim.json.encode(item.error))
          or tostring(item.error)
      end
    end
    return {
      {
        kind = "tool_end",
        tool_call_id = item.id,
        tool = tool,
        args = args,
        text = text,
        is_error = is_error == true,
        raw = raw,
      },
    }
  end
  return { { kind = "unknown", note = "item." .. tostring(t), raw = raw } }
end

---@param raw table a decoded `codex exec --json` line
---@return fieldguide.Event[]
function Normaliser:normalize(raw)
  if type(raw) ~= "table" then
    return {}
  end
  local t = raw.type
  if t == "thread.started" then
    self.thread_id = raw.thread_id or self.thread_id
    return { { kind = "run_start", session_id = self.thread_id, raw = raw } }
  elseif t == "turn.started" then
    self._turn = true
    return { { kind = "turn_start", raw = raw } }
  elseif t == "turn.completed" then
    self._turn = false
    return { { kind = "turn_end", stop_reason = "stop", usage = raw.usage, message = {}, raw = raw } }
  elseif t == "turn.failed" then
    self._turn = false
    local err = type(raw.error) == "table" and raw.error.message or tostring(raw.error)
    return { { kind = "turn_end", stop_reason = "error", error = err, message = { timestamp = "failed" }, raw = raw } }
  elseif t == "error" then
    -- Inside a turn, turn.failed follows with the same message and says it.
    if self._turn then
      return {}
    end
    return { { kind = "error", source = "codex", message = raw.message, raw = raw } }
  elseif t == "item.started" then
    local item = raw.item or {}
    if TOOL_ITEMS[item.type] then
      local tool, args = M.tool(item)
      return { { kind = "tool_start", tool_call_id = item.id, tool = tool, args = args, raw = raw } }
    end
    return {}
  elseif t == "item.updated" then
    return {}
  elseif t == "item.completed" then
    return self:_completed(raw.item or {}, raw)
  end
  return { { kind = "unknown", note = tostring(t), raw = raw } }
end

-- ---------------------------------------------------------------------------
-- The session.
-- ---------------------------------------------------------------------------

---@class fieldguide.CodexSession
---@field private _opts table
---@field private _run table? the process answering the current prompt
---@field private _norm fieldguide.CodexNormaliser
---@field private _queue string[]
---@field private _subs table<integer, fun(e: fieldguide.Event)>
---@field private _interrupted boolean
---@field private _stopped boolean
---@field private _stderr string[] the run's last lines of log
---@field private _spoke boolean the run has written a line of JSON
local Session = {}
Session.__index = Session

---Start a session. Nothing runs until the first prompt.
---
---  launch(thread_id?) -> argv, env   the command for one prompt; thread_id
---                                    is nil for the first, and the thread to
---                                    resume after that; or nil and why
---  cwd, session                      the config tree; a thread to resume
---@param opts { launch: fun(thread_id: string?): (string[]?, (table<string, string>|string)?), cwd: string?, session: string? }
---@return fieldguide.CodexSession
function M.start(opts)
  local self = setmetatable({
    _opts = opts,
    _run = nil,
    _norm = M.new(),
    _queue = {},
    _subs = {},
    _next_sub = 1,
    _interrupted = false,
    _stopped = false,
    _stderr = {},
    _spoke = false,
  }, Session)
  self._norm.thread_id = opts.session
  return self
end

---@param fn fun(e: fieldguide.Event)
---@return fun() unsubscribe
function Session:on_event(fn)
  local id = self._next_sub
  self._next_sub = id + 1
  self._subs[id] = fn
  return function()
    self._subs[id] = nil
  end
end

---@param event fieldguide.Event
function Session:_emit(event)
  for _, fn in pairs(self._subs) do
    local ok, err = pcall(fn, event)
    if not ok then
      vim.notify("fieldguide codex subscriber error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

---The thread this session continues, once there is one.
---@return string?
function Session:thread_id()
  return self._norm.thread_id
end

---@param text string
function Session:_run_prompt(text)
  -- `launch` answers nil and why when it cannot say how to run Codex, and
  -- that is never a cue to run something else: rpc.start with no argv is pi.
  local argv, env = self._opts.launch(self._norm.thread_id)
  local inner, err
  if argv then
    inner, err = require("fieldguide.rpc").start({ argv = argv, cwd = self._opts.cwd, env = env })
  else
    err = tostring(env or "Codex could not be launched")
  end
  if not inner then
    -- Said, then on to whatever is queued behind it: no process will exit to
    -- move the queue along.
    self:_emit({ kind = "error", source = "codex", message = err, raw = {} })
    self:_settle()
    return
  end
  self._run = inner
  self._interrupted = false
  self._stderr = {}
  self._spoke = false
  inner:on_event(function(event)
    if event.kind == "unknown" then
      self._spoke = true
      for _, e in ipairs(self._norm:normalize(event.raw)) do
        self:_emit(e)
      end
    elseif event.kind == "exit" then
      self:_finish(event)
    elseif event.kind == "error" and event.source == "stderr" then
      -- Codex's own log. Kept, not shown: it says an ERROR for things that
      -- are no error to anyone reading the panel. Two lines matter: a gate
      -- refusal, which nothing else reports, and the last words of a run
      -- that dies without a turn to fail.
      for line in vim.gsplit(event.message or "", "\n", { plain = true }) do
        local reason = M.blocked(line)
        if reason then
          self:_emit({ kind = "error", source = "gate", message = reason, raw = {} })
        elseif line ~= "" then
          table.insert(self._stderr, line)
          if #self._stderr > 20 then
            table.remove(self._stderr, 1)
          end
        end
      end
    else
      -- A line that would not decode, stderr: the adapter's own events.
      self:_emit(event)
    end
  end)
  inner:input(text)
end

---One prompt's process has gone: the run is over, and the next can start.
---@param exit fieldguide.Event
function Session:_finish(exit)
  self._run = nil
  if self._interrupted then
    self:_emit({ kind = "turn_end", stop_reason = "aborted", message = {}, raw = {} })
  elseif exit.code ~= 0 and not self._spoke then
    -- Gone before a line of JSON: a bad flag, no login, a binary that would
    -- not start. Its log is all there is to say why.
    local tail = table.concat(self._stderr, "\n")
    self:_emit({
      kind = "error",
      source = "codex",
      message = ("codex exited with %s before answering%s"):format(
        tostring(exit.code),
        tail ~= "" and (":\n" .. tail) or ""
      ),
      raw = {},
    })
  elseif exit.code ~= 0 and self._norm._turn then
    -- Died mid-turn without saying why in the stream.
    self:_emit({
      kind = "turn_end",
      stop_reason = "error",
      error = ("codex exited with %s"):format(tostring(exit.code)),
      message = { timestamp = "exit" },
      raw = {},
    })
  end
  self._norm._turn = false
  self:_emit({ kind = "run_end", will_retry = false, session_id = self._norm.thread_id, raw = {} })
  self:_settle()
end

-- Holds the place of a run between one prompt settling and the next queued
-- one starting, so a prompt sent from a `settled` subscriber queues behind it
-- rather than starting alongside.
local STARTING = { starting = true }

---The run is over: say so, and start the next queued prompt, if any.
function Session:_settle()
  local next_prompt = not self._stopped and table.remove(self._queue, 1) or nil
  self._run = next_prompt and STARTING or nil
  self:_emit({ kind = "settled", session_id = self._norm.thread_id, raw = {} })
  if next_prompt then
    -- A subscriber may have stopped the session on that `settled`.
    if self._stopped then
      self._run = nil
      return
    end
    self:_run_prompt(next_prompt)
  end
end

---Queue a prompt: it runs now if nothing is running, after the current run if
---something is.
---@param message string
---@return string?, string?
function Session:prompt(message, _opts)
  if self._stopped then
    return nil, "the codex session has been stopped"
  end
  if self._run then
    table.insert(self._queue, message)
    return "queued", nil
  end
  self:_run_prompt(message)
  return "started", nil
end

---Stop the running prompt. Its process is stopped; queued prompts wait.
function Session:interrupt()
  if self._run and self._run ~= STARTING then
    self._interrupted = true
    self._run:stop()
  end
end

---The pi session's generic `send`, for the one command the panel sends raw.
---@param command table
---@return string?, string?
function Session:send(command)
  if command.type == "abort" then
    self:interrupt()
    return "stopped", nil
  end
  return nil, ("codex sessions do not take %s"):format(tostring(command.type))
end

---Codex asks nothing of the user here: approvals are off, and the gate is the
---hooks and the sandbox.
function Session:answer_ui() end

---Whether the session can still take prompts. Between prompts no process
---runs, and the session is no less alive for it.
---@return boolean
function Session:is_running()
  return not self._stopped
end

---@return boolean whether a prompt is running now
function Session:busy()
  return self._run ~= nil
end

---Stop everything: the running prompt, and the queue behind it.
function Session:stop()
  self._stopped = true
  self._queue = {}
  self:interrupt()
end

return M
