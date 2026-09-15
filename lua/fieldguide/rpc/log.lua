-- A scratch buffer that dumps normalised events. Step 1's whole user interface.
--
-- Not the renderer, and deliberately ugly: its job is to make the stream
-- legible enough to answer "is anything being lost, reordered, or silently
-- swallowed" before any rendering decisions are made on top of it.

local events = require("fieldguide.rpc.events")
local rpc = require("fieldguide.rpc")

local M = {}

local state = { buf = nil, win = nil, session = nil, unsub = nil, started = nil }

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "fieldguidelog"
  vim.api.nvim_buf_set_name(state.buf, "fieldguide://rpc-log")
  return state.buf
end

---Append without making each write an undo state, and without stealing the view
---from someone who has scrolled up to read.
---@param lines string[]
local function append(lines)
  local buf = ensure_buf()
  local win = state.win
  local follow = false
  if win and vim.api.nvim_win_is_valid(win) then
    local cursor = vim.api.nvim_win_get_cursor(win)
    follow = cursor[1] >= vim.api.nvim_buf_line_count(buf)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modifiable = false

  if follow and win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

---@param event fieldguide.Event
local function on_event(event)
  local elapsed = state.started and ((vim.uv.hrtime() - state.started) / 1e6) or 0
  append({ ("%8.1fms  %s"):format(elapsed, events.describe(event)) })

  -- Dialogs block the agent until answered. Answering them here is the one
  -- piece of real behaviour in the log, because otherwise a session that hits a
  -- confirm() just stops and looks like a hang.
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
      vim.ui.input({ prompt = event.title or "agent asks: " }, function(value)
        session:answer_ui(event.id, value, value == nil)
      end)
    else
      session:answer_ui(event.id, nil, true)
    end
  end
end

function M.open()
  local buf = ensure_buf()
  vim.cmd("botright vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, buf)
  vim.api.nvim_win_set_width(state.win, 100)
  vim.wo[state.win].wrap = false
  vim.wo[state.win].number = false
  vim.wo[state.win].winfixwidth = true
end

---@param opts table? { argv?: string[] }
function M.start(opts)
  if state.session and state.session:is_running() then
    vim.notify("fieldguide: an RPC session is already running (:FieldguideRpcStop)", vim.log.levels.WARN)
    return
  end

  local session, err = rpc.start(opts or {})
  if not session then
    vim.notify("fieldguide: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  state.session = session
  state.started = vim.uv.hrtime()
  state.unsub = session:on_event(on_event)

  M.open()
  append({ ("── rpc session started at %s"):format(os.date("%H:%M:%S")), "" })
end

---@param message string
function M.prompt(message)
  if not state.session or not state.session:is_running() then
    vim.notify("fieldguide: no RPC session (:FieldguideRpc)", vim.log.levels.ERROR)
    return
  end
  append({ ("%8s  >> %s"):format("", message) })
  -- Mid-stream prompts are rejected outright unless a behaviour is named.
  local _, err = state.session:prompt(message, { streaming_behavior = "steer" })
  if err then
    vim.notify("fieldguide: " .. err, vim.log.levels.ERROR)
  end
end

function M.stop()
  if state.unsub then
    state.unsub()
    state.unsub = nil
  end
  if state.session then
    state.session:stop()
    local s = state.session.stats
    append({
      "",
      ("── stopped. %d lines, %d events, %d bytes, %d decode errors, %d unknown"):format(
        s.lines,
        s.events,
        s.bytes,
        s.decode_errors,
        s.unknown
      ),
    })
    state.session = nil
  end
end

---@return table?
function M.session()
  return state.session
end

return M
