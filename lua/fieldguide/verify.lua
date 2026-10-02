-- Verb: `verify` — a sandboxed headless boot of the working tree as it
-- is on disk. The feedback loop.
--
-- NOT a security control. It boots and quits, so autocmd callbacks, keymap
-- RHS, `on_attach`, `defer_fn` and plugin `config` functions never run. A
-- payload in any of those returns "boot ok". `verify` answers "does this boot",
-- and nothing else.

local cfg = require("fieldguide.config")
local sandbox = require("fieldguide.sandbox")

local M = {}

---Result of the previous run, for the structured diff.
M.last = nil

-- Signals that code inside the sandbox tried to leave it. An alarm, not a gate
--: it only observes code that ran, so it catches accidents and naive
-- payloads and nothing sophisticated. It must never discard the agent's work.
local ESCAPE_PATTERNS = {
  { pattern = "Network is unreachable", kind = "network" },
  { pattern = "Temporary failure in name resolution", kind = "network" },
  { pattern = "Could not resolve host", kind = "network" },
  { pattern = "Failed to connect", kind = "network" },
  { pattern = "[Rr]ead%-only file system", kind = "write" },
  { pattern = "EROFS", kind = "write" },
  { pattern = "E886", kind = "write" }, -- ShaDa on a read-only state dir
  -- seatbelt has no read-only mounts, so a denied write comes back as EPERM
  -- rather than EROFS. Both halves of that message appear.
  { pattern = "Operation not permitted", kind = "denied" },
  { pattern = "EPERM", kind = "denied" },
}

-- `verify.sandbox` pins one; "auto" picks by OS.
---@return string? backend, string? err
local function backend()
  return sandbox.backend(cfg.options.verify.sandbox, "verify.sandbox", "verify runs the boot sandboxed")
end

---@param text string
---@return table?, string
local function extract_payload(text)
  local body = text:match("<<<FIELDGUIDE%s*(.-)%s*FIELDGUIDE>>>")
  local rest = text:gsub("\n?<<<FIELDGUIDE.-FIELDGUIDE>>>\n?", "")
  if not body then
    return nil, rest
  end
  local ok, decoded = pcall(vim.json.decode, body)
  return ok and decoded or nil, rest
end

---@param stderr string
---@param stdout string
---@return table[]
local function escape_alarms(stderr, stdout)
  local alarms = {}
  local haystack = stderr .. "\n" .. stdout
  for _, e in ipairs(ESCAPE_PATTERNS) do
    for line in haystack:gmatch("[^\n]+") do
      if line:find(e.pattern) then
        table.insert(alarms, { kind = e.kind, line = vim.trim(line) })
        break
      end
    end
  end
  return alarms
end

---@param a table?
---@param b table
---@return table?
local function diff(a, b)
  if not a then
    return nil
  end
  local d = {}
  if a.ok ~= b.ok then
    d.ok = { from = a.ok, to = b.ok }
  end
  local before = {}
  for _, e in ipairs(a.errors or {}) do
    before[e] = true
  end
  local new_errors = {}
  for _, e in ipairs(b.errors or {}) do
    if not before[e] then
      table.insert(new_errors, e)
    end
  end
  local after = {}
  for _, e in ipairs(b.errors or {}) do
    after[e] = true
  end
  local fixed = {}
  for _, e in ipairs(a.errors or {}) do
    if not after[e] then
      table.insert(fixed, e)
    end
  end
  if #new_errors > 0 then
    d.new_errors = new_errors
  end
  if #fixed > 0 then
    d.fixed_errors = fixed
  end
  -- Timing always moves a little; it is context, not a change. `unchanged` has
  -- to mean "nothing you did shows up here", or the diff stops being readable.
  d.unchanged = next(d) == nil or nil
  if a.duration_ms and b.duration_ms then
    d.duration_delta_ms = math.floor((b.duration_ms - a.duration_ms) * 10) / 10
  end
  return d
end

---Everything up to and including building the full argv (sandbox launcher +
---`nvim --headless … qa!`), but does not spawn anything. Split out of M.run so
---the spawn + wait can happen in a process other than the live editor (the
---CLI, for `verify`, is its own `nvim -l` and can block freely — see
---bin/fieldguide) while the plan itself is still built from *this* editor's
---config.
---@param args table { timeout_ms?: integer }
---@return table plan { ok: boolean, error?: string, argv?: string[], cwd?: string, env?: table, timeout_ms?: integer, sandbox?: string, temp?: string[] }
function M.plan(args)
  args = args or {}
  local which, err = backend()
  if not which then
    return { ok = false, error = err }
  end

  local p = cfg.paths()
  -- Deliberately not an argument: the verb surface stays closed, and a test
  -- points it at a fixture with cfg.setup({ cwd = … }) instead.
  local ok_plan, plan = pcall(sandbox.verify_plan, which, p.config_dir)
  if not ok_plan then
    return { ok = false, error = ("failed to prepare the %s sandbox: %s"):format(which, tostring(plan)) }
  end

  local argv = vim.deepcopy(plan.argv)
  vim.list_extend(argv, {
    p.nvim_bin or "nvim",
    "--headless",
    "--cmd",
    "lua vim.g.__fieldguide_t0 = vim.uv.hrtime()",
    "-c",
    "luafile " .. plan.probe,
    "-c",
    "qa!",
  })

  return {
    ok = true,
    sandbox = which,
    argv = argv,
    cwd = p.config_dir,
    env = plan.env,
    timeout_ms = args.timeout_ms or cfg.options.verify.timeout_ms,
    -- Paths a run of this plan must remove once it is done with them — the
    -- caller who spawns the process is the one who cleans up, not `plan`
    -- itself (the CLI runs the child, so the CLI does this).
    temp = plan.temp or {},
  }
end

---Remove the temp paths a plan (from M.plan or M.run's own use of it) named.
---Safe to call on a plan whose `ok` is false — `temp` is simply absent.
---@param plan table
function M.cleanup(plan)
  for _, path in ipairs((plan or {}).temp or {}) do
    vim.fn.delete(path, "rf")
  end
end

---Turn a finished child process's result into the same shape M.run has
---always returned. `res` is `vim.system`'s wait() result (or the equivalent
---assembled by the CLI from its own vim.system call); `opts` carries what the
---plan knew and the caller measured.
---@param res table { code: integer, signal?: integer, stdout?: string, stderr?: string }
---@param opts table { duration_ms: number, timeout_ms: integer, sandbox?: string }
---@return table result
function M.interpret(res, opts)
  local duration_ms = opts.duration_ms
  local timeout = opts.timeout_ms
  local which = opts.sandbox

  if res.code == 124 or res.signal == 15 and duration_ms >= timeout then
    local result = { ok = false, timed_out = true, duration_ms = duration_ms, errors = { "boot timed out" } }
    M.last = result
    return result
  end

  local stdout = res.stdout or ""
  local stderr = res.stderr or ""
  local payload, clean_stdout = extract_payload(stdout)

  -- A sandbox that never started is not a config that failed to boot, and it
  -- is certainly not an escape alarm — bwrap's own "Operation not permitted"
  -- matches the same pattern a denied write does. Both launchers prefix their
  -- errors with their name, and neither can have produced a probe payload.
  if res.code ~= 0 and payload == nil then
    local line = stderr:match("^%s*(bwrap: [^\n]+)") or stderr:match("^%s*(sandbox%-exec: [^\n]+)")
    if line then
      return {
        ok = false,
        sandbox = which,
        error = ("the %s sandbox failed to start: %s"):format(which, vim.trim(line)),
      }
    end
  end

  -- Startup errors land on stderr with their tracebacks; :messages catches the
  -- rest. Both are the answer to "what broke".
  local errors = {}
  for line in stderr:gmatch("[^\n]+") do
    if line:match("^E%d+:") or line:match("Error") or line:match("^stack traceback") or line:match("^%s+%.%.%.") then
      table.insert(errors, vim.trim(line))
    end
  end
  if payload and payload.errmsg then
    table.insert(errors, payload.errmsg)
  end

  local result = {
    ok = res.code == 0 and #errors == 0,
    sandbox = which,
    exit_code = res.code,
    duration_ms = duration_ms,
    startup_ms = payload and payload.startup_ms or nil,
    errors = errors,
    messages = payload and payload.messages or nil,
    plugins = payload and payload.plugins or nil,
    stderr = stderr ~= "" and vim.trim(stderr) or nil,
    stdout = vim.trim(clean_stdout) ~= "" and vim.trim(clean_stdout) or nil,
    probe_missing = payload == nil or nil,
    escape_alarms = nil,
  }

  local alarms = escape_alarms(stderr, stdout)
  if #alarms > 0 then
    result.escape_alarms = alarms
    result.escape_alarm_note = "Code inside the sandbox attempted network or write access. "
      .. "This is an alarm, not a verdict — review it; nothing was reverted."
  end

  if payload and payload.plugins and #payload.plugins.would_install > 0 then
    result.note = ("would install %s — not verified. verify boots what is on disk, offline."):format(
      table.concat(payload.plugins.would_install, ", ")
    )
  end

  result.diff = diff(M.last, result)
  M.last = result
  return result
end

---@param args table { timeout_ms?: integer }
function M.run(args)
  local plan = M.plan(args)
  if not plan.ok then
    return { ok = false, error = plan.error }
  end

  local t0 = vim.uv.hrtime()
  local ok_spawn, proc = pcall(vim.system, plan.argv, {
    cwd = plan.cwd,
    env = plan.env,
    clear_env = true,
    text = true,
  })
  if not ok_spawn then
    M.cleanup(plan)
    return { ok = false, error = "failed to spawn sandbox: " .. tostring(proc) }
  end

  local res = proc:wait(plan.timeout_ms)
  local duration_ms = math.floor((vim.uv.hrtime() - t0) / 1e4) / 100
  M.cleanup(plan)

  return M.interpret(res, { duration_ms = duration_ms, timeout_ms = plan.timeout_ms, sandbox = plan.sandbox })
end

---Which sandbox this machine would use, and why not, if it would not.
---@return string? backend, string? err
function M.sandbox()
  return backend()
end

---Test-only: build a sandbox plan without spawning anything, so a test can
---inspect the argv list — e.g. that a stow-style config's link targets are
---bound — on a machine that may not even have the backend installed. Not
---part of the verb surface: the verb itself takes no backend argument.
---@param which "bwrap"|"seatbelt"
---@param config_dir string
---@return table plan
function M._plan(which, config_dir)
  return sandbox.verify_plan(which, config_dir)
end

---One line, for the sidebar and for appending to a write tool's own result.
---@param r table
---@return string
function M.summary(r)
  if r.error then
    return "verify unavailable: " .. r.error
  end
  if r.timed_out then
    return ("boot TIMED OUT after %.0fms"):format(r.duration_ms)
  end
  if r.ok then
    local s = ("boot OK, %.0fms"):format(r.duration_ms)
    if r.note then
      s = s .. " (" .. r.note .. ")"
    end
    return s
  end
  return ("boot FAILED: %s"):format(r.errors[1] or ("exit=" .. tostring(r.exit_code)))
end

return M
