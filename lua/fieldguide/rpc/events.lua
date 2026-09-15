-- Normalise one agent's wire events into fieldguide's own event type.
--
-- The renderer must never see a vendor's event names. That is the whole point:
-- ACP or a future in-house harness becomes a second module here rather than a
-- rewrite of everything downstream. The harness is an adapter, not the
-- architecture.
--
-- Anything unrecognised comes through as `unknown` carrying its payload rather
-- than being dropped. A protocol that gained an event should show up in the log
-- as a question, not as silence.

local M = {}

---@alias fieldguide.EventKind
---| "run_start" | "run_end" | "settled"
---| "turn_start" | "turn_end"
---| "message_start" | "message_end"
---| "text_start" | "text_delta" | "text_end"
---| "thinking_start" | "thinking_delta" | "thinking_end"
---| "tool_call_start" | "tool_call_delta" | "tool_call_end"
---| "tool_start" | "tool_update" | "tool_end"
---| "bash_output"
---| "status" | "ui_request" | "response" | "error" | "unknown"

---@class fieldguide.Event
---@field kind fieldguide.EventKind
---@field raw table the untouched wire event, for the log and for debugging

--- pi's streaming deltas arrive under `assistantMessageEvent`, keyed by
--- `contentIndex`. There is deliberately no cumulative snapshot — a client that
--- needs the partial message assembles it itself, and treats `message_end` as
--- authoritative.
---@param ev table
---@param raw table
---@return fieldguide.Event?
local function from_assistant_event(ev, raw)
  local index = ev.contentIndex

  if ev.type == "text_start" then
    return { kind = "text_start", index = index, raw = raw }
  elseif ev.type == "text_delta" then
    return { kind = "text_delta", index = index, text = ev.delta or "", raw = raw }
  elseif ev.type == "text_end" then
    return { kind = "text_end", index = index, text = ev.content, raw = raw }
  elseif ev.type == "thinking_start" then
    return { kind = "thinking_start", index = index, raw = raw }
  elseif ev.type == "thinking_delta" then
    return { kind = "thinking_delta", index = index, text = ev.delta or "", raw = raw }
  elseif ev.type == "thinking_end" then
    return { kind = "thinking_end", index = index, text = ev.content, raw = raw }
  elseif ev.type == "toolcall_start" then
    return { kind = "tool_call_start", index = index, raw = raw }
  elseif ev.type == "toolcall_delta" then
    return { kind = "tool_call_delta", index = index, text = ev.delta or "", raw = raw }
  elseif ev.type == "toolcall_end" then
    local call = ev.toolCall or {}
    return {
      kind = "tool_call_end",
      index = index,
      tool_call_id = call.id,
      tool = call.name,
      args = call.arguments,
      raw = raw,
    }
  end

  return { kind = "unknown", note = "assistantMessageEvent." .. tostring(ev.type), raw = raw }
end

--- Events that are progress rather than content. The renderer wants these as a
--- single status line, not as five separate concepts.
local STATUS = {
  compaction_start = "compacting context",
  compaction_end = "compaction done",
  auto_retry_start = "retrying after a transient error",
  auto_retry_end = "retry finished",
  summarization_retry_scheduled = "summarization retry scheduled",
  summarization_retry_attempt_start = "retrying summarization",
  summarization_retry_finished = "summarization retry finished",
  queue_update = "queue changed",
}

---Flatten a tool result's content blocks into plain text. Non-text blocks are
---named rather than dropped, so an image result reads as something rather than
---as nothing.
---@param result table?
---@return string?
function M.result_text(result)
  if type(result) ~= "table" or type(result.content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, block in ipairs(result.content) do
    if type(block) == "table" then
      if block.type == "text" and type(block.text) == "string" then
        table.insert(parts, block.text)
      elseif block.type then
        table.insert(parts, ("<%s>"):format(block.type))
      end
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n")
end

---How a message finished, and what went wrong if something did.
---
---A refused model, an expired subscription, a context overflow: all of them
---come back as an ordinary assistant message that happens to carry no content,
---never as an error event. A renderer that only listens for `error` shows
---nothing at all and looks like it is still working.
---@param message table?
---@return string?, string? stop reason, error message
function M.outcome(message)
  if type(message) ~= "table" then
    return nil, nil
  end
  local failure = nil
  if type(message.errorMessage) == "string" and message.errorMessage ~= "" then
    failure = message.errorMessage
  end
  return message.stopReason, failure
end

---@param raw table a decoded pi RPC event or response
---@return fieldguide.Event
function M.normalize(raw)
  local t = raw.type

  -- Command acknowledgements, correlated by the id we sent.
  if t == "response" then
    return {
      kind = "response",
      id = raw.id,
      command = raw.command,
      success = raw.success == true,
      error = raw.error,
      raw = raw,
    }
  end

  if t == "message_update" and type(raw.assistantMessageEvent) == "table" then
    return from_assistant_event(raw.assistantMessageEvent, raw)
  end

  if t == "agent_start" then
    return { kind = "run_start", raw = raw }
  elseif t == "agent_end" then
    -- `willRetry` matters: agent_end is not the end if pi is about to retry.
    return { kind = "run_end", will_retry = raw.willRetry == true, raw = raw }
  elseif t == "agent_settled" then
    -- The only event that means "the agent is done and is not coming back on
    -- its own". Anything waiting on completion waits on this, not agent_end.
    return { kind = "settled", raw = raw }
  elseif t == "turn_start" then
    return { kind = "turn_start", raw = raw }
  elseif t == "turn_end" then
    local stop, failure = M.outcome(raw.message)
    return {
      kind = "turn_end",
      message = raw.message,
      stop_reason = stop,
      error = failure,
      tool_results = raw.toolResults,
      raw = raw,
    }
  elseif t == "message_start" then
    return { kind = "message_start", message = raw.message, raw = raw }
  elseif t == "message_end" then
    -- Authoritative. Reconcile the assembled partial against this.
    local stop, failure = M.outcome(raw.message)
    return { kind = "message_end", message = raw.message, stop_reason = stop, error = failure, raw = raw }
  elseif t == "tool_execution_start" then
    return { kind = "tool_start", tool_call_id = raw.toolCallId, tool = raw.toolName, args = raw.args, raw = raw }
  elseif t == "tool_execution_update" then
    -- `partialResult` is cumulative, not a delta: a display can be replaced
    -- wholesale on each update rather than appended to.
    return {
      kind = "tool_update",
      tool_call_id = raw.toolCallId,
      tool = raw.toolName,
      args = raw.args,
      text = M.result_text(raw.partialResult),
      raw = raw,
    }
  elseif t == "tool_execution_end" then
    return {
      kind = "tool_end",
      tool_call_id = raw.toolCallId,
      tool = raw.toolName,
      args = raw.args,
      text = M.result_text(raw.result),
      details = raw.result and raw.result.details or nil,
      is_error = raw.isError == true,
      raw = raw,
    }
  elseif t == "bash_execution_update" then
    return { kind = "bash_output", id = raw.id, text = raw.delta or "", raw = raw }
  elseif t == "extension_ui_request" then
    -- Dialog methods block the agent until answered; fire-and-forget ones do
    -- not. Everything the renderer needs to tell them apart is in `method`.
    return {
      kind = "ui_request",
      id = raw.id,
      method = raw.method,
      title = raw.title,
      message = raw.message,
      options = raw.options,
      timeout = raw.timeout,
      raw = raw,
    }
  elseif t == "extension_error" then
    return { kind = "error", source = "extension", message = raw.error or raw.message, raw = raw }
  elseif STATUS[t] then
    local text = STATUS[t]
    if t == "auto_retry_start" and raw.attempt then
      -- A silent backoff is indistinguishable from a slow model. Say which
      -- attempt this is and how long the wait is, so a stall reads as a stall.
      text = ("retrying (%s/%s) in %ss"):format(raw.attempt, raw.maxAttempts or "?", (raw.delayMs or 0) / 1000)
    end
    return { kind = "status", what = t, text = text, raw = raw }
  end

  return { kind = "unknown", note = tostring(t), raw = raw }
end

---Dialog UI requests block the agent until answered. The rest are informational
---and must not be replied to.
local DIALOG_METHODS = { select = true, confirm = true, input = true, editor = true }

---@param event fieldguide.Event
---@return boolean
function M.needs_reply(event)
  return event.kind == "ui_request" and DIALOG_METHODS[event.method] == true
end

---A short, log-friendly rendering. Not the real renderer — this is what step 1
---uses to prove the stream is intact.
---@param event fieldguide.Event
---@return string
function M.describe(event)
  local k = event.kind
  if k == "text_delta" or k == "thinking_delta" or k == "tool_call_delta" then
    local text = (event.text or ""):gsub("\n", "\\n")
    return ("%-18s [%s] %q"):format(k, tostring(event.index), text)
  elseif k == "tool_start" or k == "tool_end" or k == "tool_call_end" then
    return ("%-18s %s%s"):format(k, tostring(event.tool), event.is_error and "  (error)" or "")
  elseif k == "ui_request" then
    return ("%-18s %s %q%s"):format(k, event.method, event.title or "", M.needs_reply(event) and "  (blocking)" or "")
  elseif k == "response" then
    return ("%-18s %s success=%s%s"):format(
      k,
      tostring(event.command),
      tostring(event.success),
      event.error and (" " .. event.error) or ""
    )
  elseif k == "status" then
    return ("%-18s %s"):format(k, event.text)
  elseif k == "error" then
    return ("%-18s %s"):format(k, tostring(event.message))
  elseif k == "unknown" then
    return ("%-18s %s"):format(k, tostring(event.note))
  elseif k == "run_end" then
    return ("%-18s will_retry=%s"):format(k, tostring(event.will_retry))
  end
  return k
end

return M
